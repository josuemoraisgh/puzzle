import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../core/utils/debug_logger.dart';
import 'moodle_datasource.dart';

/// Interface – estado compartilhado do quiz via Moodle mod_data.
abstract class IStateDatasource {
  /// Lê o estado atual do quiz (qualquer token válido serve).
  Future<Map<String, dynamic>> getState(
      String baseUrl, String token, int courseId);

  /// Professor define qual quiz está selecionado para o curso.
  ///
  /// Isso mantém `quiz_id` e `quiz_name` sincronizados antes da primeira questão.
  Future<void> setSelectedQuiz({
    required String baseUrl,
    required String token,
    required int courseId,
    required int quizId,
    required String quizName,
  });

  /// Professor libera uma questão (timer + página).
  Future<void> releaseQuestion({
    required String baseUrl,
    required String token,
    required int courseId,
    required int page,
    required int slot,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  });

  /// Professor encerra a questão ativa.
  Future<void> closeQuestion(String baseUrl, String token, int courseId);

  /// Professor marca o quiz como finalizado.
  Future<void> setFinished(String baseUrl, String token, int courseId);

  /// Estudante registra pontuação com bônus de tempo.
  Future<void> submitScore({
    required String baseUrl,
    required String token,
    required int courseId,
    required String studentId,
    required String studentName,
    required int score,
    required bool correct,
    required int page,
  });

  /// Retorna todas as pontuações dos estudantes.
  Future<List<Map<String, dynamic>>> getScores(
      String baseUrl, String token, int courseId);

  /// Professor reseta o quiz (apaga scores, volta a 'waiting').
  Future<void> resetQuiz(String baseUrl, String token, int courseId);
}

/// Implementação via Moodle mod_data (atividade "Database" chamada **mq_state**).
///
/// O banco usa UMA ÚNICA atividade Database com as seguintes entradas:
///
/// **Entrada de estado** (type = "state"):
///   - state_json: JSON com {state, current_page, total_pages, quiz_id, quiz_name, ends_at}
///
/// **Entradas de pontuação** (type = "score"), UMA por aluno:
///   - student_id, student_name, score, correct_count, pages (JSON array)
///
/// O dataid é descoberto automaticamente buscando a Database chamada "mq_state" no curso.
class MoodleStateDatasource implements IStateDatasource {
  final http.Client _client;
  final IMoodleDatasource _moodle;

  // Cache de dataid por curso — reduz chamadas repetidas de discovery
  final Map<int, int> _dataidByCourse = {};
  int? _currentCourseId;
  int? _dataid;

  int? _typeFieldId;
  int? _stateJsonFieldId;
  int? _studentIdFieldId;
  int? _studentNameFieldId;
  int? _scoreFieldId;
  int? _correctCountFieldId;
  int? _pagesFieldId;

  int? _stateEntryId; // ID da entrada type=state

  static const Map<String, dynamic> _emptyState = {
    'state': 'waiting',
    'current_page': -1,
    'total_pages': 0,
    'quiz_id': 0,
    'course_id': 0,
    'quiz_name': '',
    'ends_at': '',
  };

  MoodleStateDatasource(this._moodle, [http.Client? client])
      : _client = client ?? http.Client();

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Extrai string de forma segura de valores do Moodle que podem ser Map, String, etc.
  String _safeString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) return value.toString();
    if (value is Map) {
      return _safeString(
          value['value'] ?? value['text'] ?? value['content'] ?? '');
    }
    return '';
  }

  // ── Discovery ──────────────────────────────────────────────────────────────

  /// Busca o dataid da Database "mq_state" no curso. Cacheia o resultado.
  Future<void> _ensureDataId(String baseUrl, String token, int courseId) async {
    if (_dataidByCourse.containsKey(courseId)) {
      _dataid = _dataidByCourse[courseId];
      _currentCourseId = courseId;
      return;
    }

    // Tenta primeiro com courseId específico; se não encontrar, tenta sem filtro
    // (retorna todos os databases acessíveis ao usuário).
    final candidateCourseIds = courseId > 0 ? [courseId, 0] : [0];

    for (final cid in candidateCourseIds) {
      final databases =
          await _moodle.getDataActivitiesByCourse(baseUrl, token, cid);

      for (final db in databases) {
        final name = _safeString(db['name']);
        if (name.toLowerCase() == 'mq_state') {
          final id = (db['id'] as num?)?.toInt();
          if (id != null && id > 0) {
            _dataid = id;
            _dataidByCourse[courseId] = id;
            _currentCourseId = courseId;
            return;
          }
        }
      }
    }

    throw StateException(
        'Atividade Database "mq_state" não encontrada no curso.\n'
        'Crie uma atividade Database com nome exatamente "mq_state" (minúsculas) '
        'e configure os 7 campos conforme documentação.');
  }

  Future<void> _ensureFields(String baseUrl, String token, int courseId) async {
    // Se mudou de curso, limpa cache de fields
    if (_currentCourseId != courseId) {
      _typeFieldId = null;
      _stateJsonFieldId = null;
      _studentIdFieldId = null;
      _studentNameFieldId = null;
      _scoreFieldId = null;
      _correctCountFieldId = null;
      _pagesFieldId = null;
      _stateEntryId = null;
    }

    if (_typeFieldId != null) return;

    await _ensureDataId(baseUrl, token, courseId);

    final result = await _callWs(
      baseUrl,
      token,
      'mod_data_get_fields',
      {'databaseid': _dataid!.toString()},
    );

    final fields = result['fields'] as List? ?? [];

    for (final f in fields) {
      final name = _safeString(f['name']);
      final id = (f['id'] as num).toInt();

      switch (name) {
        case 'type':
          _typeFieldId = id;
          break;
        case 'state_json':
          _stateJsonFieldId = id;
          break;
        case 'student_id':
          _studentIdFieldId = id;
          break;
        case 'student_name':
          _studentNameFieldId = id;
          break;
        case 'score':
          _scoreFieldId = id;
          break;
        case 'correct_count':
          _correctCountFieldId = id;
          break;
        case 'pages':
          _pagesFieldId = id;
          break;
      }
    }

    final missing = <String>[];
    if (_typeFieldId == null) missing.add('type');
    if (_stateJsonFieldId == null) missing.add('state_json');
    if (_studentIdFieldId == null) missing.add('student_id');
    if (_studentNameFieldId == null) missing.add('student_name');
    if (_scoreFieldId == null) missing.add('score');
    if (_correctCountFieldId == null) missing.add('correct_count');
    if (_pagesFieldId == null) missing.add('pages');

    if (missing.isNotEmpty) {
      throw StateException(
          'Campos ausentes em mq_state: ${missing.join(', ')}.\n'
          'Consulte as instruções de configuração do Moodle.');
    }
  }

  /// Busca todas as entradas do banco e devolve como lista de mapas internos.
  Future<List<Map<String, dynamic>>> _fetchAllEntries(
      String baseUrl, String token) async {
    final result = await _callWs(
      baseUrl,
      token,
      'mod_data_get_entries',
      {
        'databaseid': _dataid!.toString(),
        'perpage': '200',
        'page': '0',
        'returncontents': '1',
      },
    );

    final entries = result['entries'] as List? ?? [];

    return entries.map((entry) {
      final entryId = (entry['id'] as num?)?.toInt() ?? 0;
      final contents = entry['contents'] as List? ?? [];

      final map = <String, dynamic>{
        '_entry_id': entryId,
        'type': '',
        'state_json': '',
        'student_id': '',
        'student_name': '',
        'score': 0,
        'correct_count': 0,
        'pages': '',
      };

      for (final c in contents) {
        final fid = (c['fieldid'] as num?)?.toInt();
        final val = _safeString(c['content']);

        if (fid == _typeFieldId) map['type'] = val;
        if (fid == _stateJsonFieldId) map['state_json'] = val;
        if (fid == _studentIdFieldId) map['student_id'] = val;
        if (fid == _studentNameFieldId) map['student_name'] = val;
        if (fid == _scoreFieldId) map['score'] = int.tryParse(val) ?? 0;
        if (fid == _correctCountFieldId)
          map['correct_count'] = int.tryParse(val) ?? 0;
        if (fid == _pagesFieldId) map['pages'] = val;
      }

      return map;
    }).toList();
  }

  // ── Estado ─────────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getState(
      String baseUrl, String token, int courseId) async {
    try {
      await _ensureFields(baseUrl, token, courseId);
      final entries = await _fetchAllEntries(baseUrl, token);

      final stateEntry = entries.firstWhere(
        (e) => e['type'] == 'state',
        orElse: () => {},
      );

      if (stateEntry.isEmpty) {
        // Entry órfã sem type preenchido — será atualizada no próximo save
        final orphan = entries.firstWhere(
          (e) =>
              (e['type'] == '' || e['type'] == null) &&
              (e['student_id'] == '' || e['student_id'] == null),
          orElse: () => {},
        );
        if (orphan.isNotEmpty) {
          _stateEntryId = orphan['_entry_id'] as int?;
        }
        return Map.from(_emptyState);
      }

      _stateEntryId = stateEntry['_entry_id'] as int?;
      final raw = stateEntry['state_json'] as String? ?? '';

      if (raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          return Map<String, dynamic>.from(decoded as Map);
        } catch (_) {}
      }

      return Map.from(_emptyState);
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> setSelectedQuiz({
    required String baseUrl,
    required String token,
    required int courseId,
    required int quizId,
    required String quizName,
  }) async {
    await _ensureFields(baseUrl, token, courseId);
    final current = await getState(baseUrl, token, courseId);

    await _writeState(baseUrl, token, {
      ...current,
      'state': 'waiting',
      'current_page': -1,
      'current_slot': 0,
      'quiz_id': quizId,
      'course_id': courseId,
      'quiz_name': quizName,
      'ends_at': '',
    });
  }

  Future<void> _writeState(
      String baseUrl, String token, Map<String, dynamic> state) async {
    final dlog = DebugLogger.instance;
    final jsonStr = jsonEncode(state);

    // O Moodle mod_data espera que os valores de textarea sejam JSON-encoded:
    // jsonEncode(jsonStr) evita que PHP trate o JSON como objeto stdClass.
    final data = {
      'data[0][fieldid]': _typeFieldId!.toString(),
      'data[0][value]': jsonEncode('state'),
      'data[1][fieldid]': _stateJsonFieldId!.toString(),
      'data[1][value]': jsonEncode(jsonStr),
      'data[2][fieldid]': _studentIdFieldId!.toString(),
      'data[2][value]': jsonEncode(''),
      'data[3][fieldid]': _studentNameFieldId!.toString(),
      'data[3][value]': jsonEncode(''),
      'data[4][fieldid]': _scoreFieldId!.toString(),
      'data[4][value]': '0',
      'data[5][fieldid]': _correctCountFieldId!.toString(),
      'data[5][value]': '0',
      'data[6][fieldid]': _pagesFieldId!.toString(),
      'data[6][value]': jsonEncode('[]'),
    };

    dlog.log('STATE_WRITE', 'gravando estado', data: {
      'entryId': _stateEntryId,
      'state': state,
    });

    if (_stateEntryId == null) {
      final res = await _callWs(baseUrl, token, 'mod_data_add_entry', {
        'databaseid': _dataid!.toString(),
        ...data,
      });
      _stateEntryId = (res['newentryid'] as num?)?.toInt();
      dlog.log('STATE_WRITE', '✓ add_entry ok', data: {
        'newEntryId': _stateEntryId,
      });
    } else {
      final res = await _callWs(baseUrl, token, 'mod_data_update_entry', {
        'entryid': _stateEntryId!.toString(),
        ...data,
      });
      final updated = res['updated'] == true;
      final notifications = res['generalnotifications'];
      final fieldNotifs = res['fieldnotifications'];
      dlog.log('STATE_WRITE', 'update_entry resposta', data: {
        'updated': updated,
        'generalnotifications': notifications,
        'fieldnotifications': fieldNotifs,
      });

      if (!updated) {
        // Update falhou (entryId stale, sem permissão, etc.).
        // Tenta recuperar buscando entryId atual e reescrevendo.
        dlog.log(
            'STATE_WRITE', '⚠ update falhou — invalidando entryId e recriando');
        _stateEntryId = null;
        // Re-descobre entryId real
        try {
          final entries = await _fetchAllEntries(baseUrl, token);
          final stateEntry =
              entries.firstWhere((e) => e['type'] == 'state', orElse: () => {});
          if (stateEntry.isNotEmpty) {
            _stateEntryId = stateEntry['_entry_id'] as int?;
            dlog.log('STATE_WRITE', 'entryId redescoberto',
                data: {'entryId': _stateEntryId});
          }
        } catch (e) {
          dlog.log('STATE_WRITE', 'erro redescobrindo entryId: $e');
        }
        // Tenta novamente: update se achou; senão add
        if (_stateEntryId != null) {
          final res2 = await _callWs(baseUrl, token, 'mod_data_update_entry', {
            'entryid': _stateEntryId!.toString(),
            ...data,
          });
          dlog.log('STATE_WRITE', 'retry update', data: {
            'updated': res2['updated'],
            'fieldnotifications': res2['fieldnotifications'],
          });
          if (res2['updated'] != true) {
            throw StateException(
                'Falha ao atualizar mq_state. Verifique permissões do professor '
                '(mod/data:manageentries) e os campos do Database.');
          }
        } else {
          final res2 = await _callWs(baseUrl, token, 'mod_data_add_entry', {
            'databaseid': _dataid!.toString(),
            ...data,
          });
          _stateEntryId = (res2['newentryid'] as num?)?.toInt();
          dlog.log('STATE_WRITE', 'add após update falho',
              data: {'newEntryId': _stateEntryId});
        }
      }
    }
  }

  @override
  Future<void> releaseQuestion({
    required String baseUrl,
    required String token,
    required int courseId,
    required int page,
    required int slot,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  }) async {
    await _ensureFields(baseUrl, token, courseId);

    // Garante que temos o stateEntryId se já existe
    if (_stateEntryId == null) {
      await getState(baseUrl, token, courseId);
    }

    final endsAt = DateTime.now()
        .add(Duration(seconds: duration))
        .toUtc()
        .toIso8601String();

    await _writeState(baseUrl, token, {
      'state': 'active',
      'current_page': page,
      'current_slot': slot,
      'total_pages': totalPages,
      'quiz_id': quizId,
      'course_id': courseId,
      'quiz_name': quizName,
      'ends_at': endsAt,
    });
  }

  @override
  Future<void> closeQuestion(String baseUrl, String token, int courseId) async {
    await _ensureFields(baseUrl, token, courseId);
    final current = await getState(baseUrl, token, courseId);
    await _writeState(baseUrl, token, {...current, 'state': 'closed'});
  }

  @override
  Future<void> setFinished(String baseUrl, String token, int courseId) async {
    await _ensureFields(baseUrl, token, courseId);
    final current = await getState(baseUrl, token, courseId);
    await _writeState(baseUrl, token, {...current, 'state': 'finished'});
  }

  // ── Pontuação ──────────────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getScores(
      String baseUrl, String token, int courseId) async {
    await _ensureFields(baseUrl, token, courseId);
    final entries = await _fetchAllEntries(baseUrl, token);
    return entries
        .where((e) => e['type'] == 'score')
        .map((e) => {
              'student_id': e['student_id'] ?? '',
              'student_name': e['student_name'] ?? '',
              'score': e['score'] ?? 0,
              'correct_count': e['correct_count'] ?? 0,
              'pages': e['pages'] ?? '[]',
            })
        .toList();
  }

  @override
  Future<void> submitScore({
    required String baseUrl,
    required String token,
    required int courseId,
    required String studentId,
    required String studentName,
    required int score,
    required bool correct,
    required int page,
  }) async {
    await _ensureFields(baseUrl, token, courseId);

    // Busca entrada existente do aluno
    final entries = await _fetchAllEntries(baseUrl, token);
    final existing = entries.firstWhere(
      (e) => e['type'] == 'score' && e['student_id'] == studentId,
      orElse: () => {},
    );

    // Dados por página: {"0": {"s": 1230, "c": 1}, "1": {"s": 0, "c": 0}}
    // Permite re-submissão (ex: após correção de bug) sem perder/duplicar dados.
    Map<String, dynamic> pageData = {};

    if (existing.isNotEmpty) {
      try {
        final raw = existing['pages'] as String? ?? '{}';
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          pageData = Map<String, dynamic>.from(decoded);
        } else if (decoded is List) {
          // Migração de formato antigo [0, 1] → {"0": {"s": 0, "c": 0}, ...}
          for (final p in decoded) {
            pageData[p.toString()] = {'s': 0, 'c': 0};
          }
        }
      } catch (_) {}
    }

    // Atualiza (ou insere) dados desta página
    pageData[page.toString()] = {
      's': score,
      'c': correct ? 1 : 0,
    };

    // Recalcula totais a partir dos dados por página
    int totalScore = 0;
    int totalCorrect = 0;
    for (final v in pageData.values) {
      if (v is Map) {
        totalScore += (v['s'] as num? ?? 0).toInt();
        totalCorrect += (v['c'] as num? ?? 0).toInt();
      }
    }

    final pagesJson = jsonEncode(jsonEncode(pageData));

    final data = {
      'data[0][fieldid]': _typeFieldId!.toString(),
      'data[0][value]': jsonEncode('score'),
      'data[1][fieldid]': _stateJsonFieldId!.toString(),
      'data[1][value]': jsonEncode(''),
      'data[2][fieldid]': _studentIdFieldId!.toString(),
      'data[2][value]': jsonEncode(studentId),
      'data[3][fieldid]': _studentNameFieldId!.toString(),
      'data[3][value]': jsonEncode(studentName),
      'data[4][fieldid]': _scoreFieldId!.toString(),
      'data[4][value]': totalScore.toString(),
      'data[5][fieldid]': _correctCountFieldId!.toString(),
      'data[5][value]': totalCorrect.toString(),
      'data[6][fieldid]': _pagesFieldId!.toString(),
      'data[6][value]': pagesJson,
    };

    if (existing.isEmpty) {
      await _callWs(baseUrl, token, 'mod_data_add_entry', {
        'databaseid': _dataid!.toString(),
        ...data,
      });
    } else {
      final entryId = existing['_entry_id'] as int;
      await _callWs(baseUrl, token, 'mod_data_update_entry', {
        'entryid': entryId.toString(),
        ...data,
      });
    }
  }

  @override
  Future<void> resetQuiz(String baseUrl, String token, int courseId) async {
    await _ensureFields(baseUrl, token, courseId);
    final entries = await _fetchAllEntries(baseUrl, token);

    // Apaga todas as entradas de score
    for (final e in entries.where((e) => e['type'] == 'score')) {
      final entryId = e['_entry_id'] as int? ?? 0;
      if (entryId > 0) {
        try {
          await _callWs(baseUrl, token, 'mod_data_delete_entry',
              {'entryid': entryId.toString()});
        } catch (_) {}
      }
    }

    // Reseta estado para waiting
    await _writeState(baseUrl, token, Map.from(_emptyState));
  }

  // ── HTTP helper ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _callWs(
    String baseUrl,
    String token,
    String function,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse('$baseUrl/webservice/rest/server.php');

    final body = {
      'wstoken': token,
      'wsfunction': function,
      'moodlewsrestformat': 'json',
      ...params,
    };

    final resp = await _client.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw StateException('Erro HTTP ${resp.statusCode}');
    }

    final data = jsonDecode(resp.body);

    if (data is Map && data['exception'] != null) {
      throw StateException(
        data['message']?.toString() ?? 'Erro desconhecido no Moodle',
        code: data['errorcode']?.toString(),
      );
    }

    if (data is Map<String, dynamic>) return data;
    return {'result': data};
  }
}

class StateException implements Exception {
  final String message;
  final String? code;
  StateException(this.message, {this.code});
  @override
  String toString() => message;
}
