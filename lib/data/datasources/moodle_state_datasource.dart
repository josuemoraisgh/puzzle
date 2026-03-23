import 'dart:convert';
import 'package:http/http.dart' as http;

import 'moodle_datasource.dart';

/// Interface – estado compartilhado do quiz via Moodle mod_data.
abstract class IStateDatasource {
  /// Lê o estado atual do quiz (qualquer token válido serve).
  Future<Map<String, dynamic>> getState(
      String baseUrl, String token, int courseId);

  /// Professor libera uma questão (timer + página).
  Future<void> releaseQuestion({
    required String baseUrl,
    required String token,
    required int courseId,
    required int page,
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

  /// Buffer de logs para debug - facilita copiar todo o relatório
  final StringBuffer _debugLog = StringBuffer();

  void _log(String msg) {
    final line = '[MoodleState] $msg';
    print(line);
    _debugLog.writeln(line);
  }

  void _logSeparator() {
    const sep =
        '═══════════════════════════════════════════════════════════════════';
    print(sep);
    _debugLog.writeln(sep);
  }

  String getDebugLog() => _debugLog.toString();

  /// Extrai string de forma segura de valores do Moodle que podem ser Map, String, etc.
  String _safeString(dynamic value, [String context = '']) {
    if (value == null) {
      if (context.isNotEmpty) _log('  → $context: NULL');
      return '';
    }

    if (value is String) {
      if (context.isNotEmpty) _log('  → $context: String = "$value"');
      return value;
    }

    if (value is num) {
      if (context.isNotEmpty) _log('  → $context: num = $value');
      return value.toString();
    }

    if (value is Map) {
      if (context.isNotEmpty) {
        _log('  → $context: Map (keys: ${value.keys.join(", ")})');
        _log('     CONTEÚDO COMPLETO DO MAP: $value');
      }
      // Tenta diferentes chaves comuns do Moodle
      final result = _safeString(
          value['value'] ?? value['text'] ?? value['content'] ?? '', '');
      if (context.isNotEmpty) _log('     EXTRAÍDO: "$result"');
      return result;
    }

    if (value is List) {
      if (context.isNotEmpty) {
        _log('  → $context: List com ${value.length} items');
        _log('     CONTEÚDO COMPLETO DA LISTA: $value');
      }
      return '';
    }

    if (context.isNotEmpty) {
      _log('  → $context: TIPO DESCONHECIDO (${value.runtimeType})');
      _log('     VALOR RAW: $value');
    }
    return '';
  }

  // ── Discovery ──────────────────────────────────────────────────────────────

  /// Busca o dataid da Database "mq_state" no curso. Cacheia o resultado.
  Future<void> _ensureDataId(String baseUrl, String token, int courseId) async {
    _logSeparator();
    _log('INÍCIO: Buscando Database "mq_state" no curso $courseId');
    _logSeparator();

    // Se já está em cache para este curso, usa
    if (_dataidByCourse.containsKey(courseId)) {
      _dataid = _dataidByCourse[courseId];
      _currentCourseId = courseId;
      _log('✅ CACHE HIT: Database já conhecida, dataid=$_dataid');
      return;
    }

    // Busca Database activities do curso
    _log('Chamando API: mod_data_get_databases_by_courses...');
    final databases =
        await _moodle.getDataActivitiesByCourse(baseUrl, token, courseId);

    _log('Resposta: ${databases.length} databases encontradas no curso');

    // Procura pela atividade chamada "mq_state"
    for (int i = 0; i < databases.length; i++) {
      final db = databases[i];
      _log('');
      _log('Database #$i:');
      _log('  id: ${db["id"]}');
      _log('  Analisando campo "name"...');

      final name = _safeString(db['name'], 'Database[$i].name');

      _log('  Nome final extraído: "$name"');

      if (name.toLowerCase() == 'mq_state') {
        final id = (db['id'] as num?)?.toInt();
        _logSeparator();
        _log('✅ ENCONTROU mq_state! Database ID = $id');
        _logSeparator();
        if (id != null && id > 0) {
          _dataid = id;
          _dataidByCourse[courseId] = id;
          _currentCourseId = courseId;
          return;
        }
      }
    }

    _logSeparator();
    _log('❌ ERRO: Database "mq_state" NÃO ENCONTRADA');
    _logSeparator();
    throw StateException(
        'Atividade Database "mq_state" não encontrada no curso.\n'
        'Crie uma atividade Database com nome exatamente "mq_state" (minúsculas) '
        'e configure os 7 campos conforme documentação.');
  }

  Future<void> _ensureFields(String baseUrl, String token, int courseId) async {
    _logSeparator();
    _log('INÍCIO: Buscando campos da Database mq_state');
    _logSeparator();

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
      _log('Cache de fields limpo (curso mudou)');
    }

    if (_typeFieldId != null) {
      _log('✅ CACHE HIT: Campos já conhecidos');
      return;
    }

    await _ensureDataId(baseUrl, token, courseId);

    _log('Chamando API: mod_data_get_fields para dataid=$_dataid');
    final result = await _callWs(
      baseUrl,
      token,
      'mod_data_get_fields',
      {'databaseid': _dataid!.toString()},
    );

    final fields = result['fields'] as List? ?? [];
    _log('Resposta: ${fields.length} campos encontrados');
    _log('');

    for (int i = 0; i < fields.length; i++) {
      final f = fields[i];
      _log('Campo #$i:');
      _log('  id: ${f["id"]}');
      _log(
          '  type: ${f["type"]}'); // Mostra o tipo do campo (text, textarea, number, etc)
      _log('  Analisando campo "name"...');

      final name = _safeString(f['name'], 'Field[$i].name');
      _log('  Nome final extraído: "$name"');

      final id = (f['id'] as num).toInt();

      switch (name) {
        case 'type':
          _typeFieldId = id;
          _log('  ✅ Mapeado: type → fieldId $id');
          break;
        case 'state_json':
          _stateJsonFieldId = id;
          _log('  ✅ Mapeado: state_json → fieldId $id (tipo: ${f["type"]})');
          break;
        case 'student_id':
          _studentIdFieldId = id;
          _log('  ✅ Mapeado: student_id → fieldId $id');
          break;
        case 'student_name':
          _studentNameFieldId = id;
          _log('  ✅ Mapeado: student_name → fieldId $id');
          break;
        case 'score':
          _scoreFieldId = id;
          _log('  ✅ Mapeado: score → fieldId $id');
          break;
        case 'correct_count':
          _correctCountFieldId = id;
          _log('  ✅ Mapeado: correct_count → fieldId $id');
          break;
        case 'pages':
          _pagesFieldId = id;
          _log('  ✅ Mapeado: pages → fieldId $id (tipo: ${f["type"]})');
          break;
        default:
          _log('  ⚠️  Campo ignorado (não usado pelo sistema)');
      }
      _log('');
    }

    final missing = <String>[];
    if (_typeFieldId == null) missing.add('type');
    if (_stateJsonFieldId == null) missing.add('state_json');
    if (_studentIdFieldId == null) missing.add('student_id');
    if (_studentNameFieldId == null) missing.add('student_name');
    if (_scoreFieldId == null) missing.add('score');
    if (_correctCountFieldId == null) missing.add('correct_count');
    if (_pagesFieldId == null) missing.add('pages');

    _logSeparator();
    if (missing.isEmpty) {
      _log('✅ SUCESSO: Todos os 7 campos obrigatórios encontrados!');
      _log('  - type: fieldId $_typeFieldId');
      _log('  - state_json: fieldId $_stateJsonFieldId');
      _log('  - student_id: fieldId $_studentIdFieldId');
      _log('  - student_name: fieldId $_studentNameFieldId');
      _log('  - score: fieldId $_scoreFieldId');
      _log('  - correct_count: fieldId $_correctCountFieldId');
      _log('  - pages: fieldId $_pagesFieldId');
    } else {
      _log('❌ ERRO: Campos ausentes: ${missing.join(", ")}');
    }
    _logSeparator();

    if (missing.isNotEmpty) {
      throw StateException(
          'Campos ausentes em mq_state: ${missing.join(', ')}.\n'
          'Consulte as instruções de configuração do Moodle.');
    }
  }

  /// Busca todas as entradas do banco e devolve como lista de mapas internos.
  Future<List<Map<String, dynamic>>> _fetchAllEntries(
      String baseUrl, String token) async {
    _logSeparator();
    _log('INÍCIO: Buscando entries da Database (dataid=$_dataid)');
    _logSeparator();

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
    _log('Resposta: ${entries.length} entries encontradas');
    _log('');

    return entries.map((entry) {
      final entryId = (entry['id'] as num?)?.toInt() ?? 0;
      _log('Entry ID $entryId:');

      final contents = entry['contents'] as List? ?? [];
      _log('  Tem ${contents.length} campos preenchidos');

      final map = <String, dynamic>{
        '_entry_id': entryId,
      };

      for (int i = 0; i < contents.length; i++) {
        final c = contents[i];
        final fid = (c['fieldid'] as num?)?.toInt();

        _log('  Campo fieldId=$fid:');

        // Identifica qual campo é este
        String fieldName = '?';
        if (fid == _typeFieldId) fieldName = 'type';
        if (fid == _stateJsonFieldId) fieldName = 'state_json';
        if (fid == _studentIdFieldId) fieldName = 'student_id';
        if (fid == _studentNameFieldId) fieldName = 'student_name';
        if (fid == _scoreFieldId) fieldName = 'score';
        if (fid == _correctCountFieldId) fieldName = 'correct_count';
        if (fid == _pagesFieldId) fieldName = 'pages';

        _log('    Nome: $fieldName');
        _log('    Analisando conteúdo...');

        final val = _safeString(c['content'], 'Entry[$entryId].$fieldName');

        if (fid == _typeFieldId) {
          map['type'] = val;
        }
        if (fid == _stateJsonFieldId) {
          map['state_json'] = val;
        }
        if (fid == _studentIdFieldId) {
          map['student_id'] = val;
        }
        if (fid == _studentNameFieldId) {
          map['student_name'] = val;
        }
        if (fid == _scoreFieldId) {
          map['score'] = int.tryParse(val) ?? 0;
        }
        if (fid == _correctCountFieldId) {
          map['correct_count'] = int.tryParse(val) ?? 0;
        }
        if (fid == _pagesFieldId) {
          map['pages'] = val;
        }
      }

      _log(
          '  Entry $entryId mapeada: type=${map["type"]}, student_id=${map["student_id"]}');
      _log('');
      return map;
    }).toList();
  }

  // ── Estado ─────────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getState(
      String baseUrl, String token, int courseId) async {
    _debugLog.clear(); // Limpa log anterior

    try {
      await _ensureFields(baseUrl, token, courseId);
      final entries = await _fetchAllEntries(baseUrl, token);

      _logSeparator();
      _log('BUSCANDO entry do tipo "state"...');

      final stateEntry = entries.firstWhere(
        (e) => e['type'] == 'state',
        orElse: () => {},
      );

      if (stateEntry.isEmpty) {
        _log(
            '⚠️  Nenhuma entry tipo "state" encontrada. Retornando estado vazio.');
        _logSeparator();
        _printFullLog();
        return Map.from(_emptyState);
      }

      _log('✅ Entry tipo "state" encontrada: ID ${stateEntry["_entry_id"]}');
      _stateEntryId = stateEntry['_entry_id'] as int?;

      final raw = stateEntry['state_json'] as String? ?? '';
      _log('JSON bruto: ${raw.length} caracteres');

      if (raw.isNotEmpty) {
        try {
          final parsed = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          _log('✅ JSON parseado com sucesso! Keys: ${parsed.keys.join(", ")}');
          _logSeparator();
          _printFullLog();
          return parsed;
        } catch (e) {
          _log('❌ ERRO ao parsear JSON: $e');
          _logSeparator();
          _printFullLog();
        }
      }

      _log('Retornando estado vazio (JSON vazio ou inválido)');
      _logSeparator();
      _printFullLog();
      return Map.from(_emptyState);
    } catch (e, stack) {
      _logSeparator();
      _log('❌ ERRO FATAL: $e');
      _log('Stack trace: $stack');
      _logSeparator();
      _printFullLog();
      rethrow;
    }
  }

  void _printFullLog() {
    print('\n\n');
    print(
        '╔════════════════════════════════════════════════════════════════════╗');
    print(
        '║         LOG COMPLETO - COPIE E COLE TUDO ABAIXO DAQUI            ║');
    print(
        '╚════════════════════════════════════════════════════════════════════╝');
    print(_debugLog.toString());
    print(
        '╔════════════════════════════════════════════════════════════════════╗');
    print(
        '║                     FIM DO LOG                                    ║');
    print(
        '╚════════════════════════════════════════════════════════════════════╝');
    print('\n\n');
  }

  Future<void> _writeState(
      String baseUrl, String token, Map<String, dynamic> state) async {
    _log('_writeState: preparando dados...');

    final jsonStr = jsonEncode(state);
    _log('  state_json (${jsonStr.length} chars)');

    final data = {
      'data[0][fieldid]': _typeFieldId!.toString(),
      'data[0][value]': 'state',
      'data[1][fieldid]': _stateJsonFieldId!.toString(),
      'data[1][value]': jsonStr,
      // campos de score ficam vazios na entrada de estado — Moodle aceita
      'data[2][fieldid]': _studentIdFieldId!.toString(),
      'data[2][value]': '',
      'data[3][fieldid]': _studentNameFieldId!.toString(),
      'data[3][value]': '',
      'data[4][fieldid]': _scoreFieldId!.toString(),
      'data[4][value]': '0',
      'data[5][fieldid]': _correctCountFieldId!.toString(),
      'data[5][value]': '0',
      'data[6][fieldid]': _pagesFieldId!.toString(),
      'data[6][value]': '[]',
    };

    if (_stateEntryId == null) {
      _log('  stateEntryId é null → chamando mod_data_add_entry');
      _log('  databaseid: $_dataid');

      final params = {
        'databaseid': _dataid!.toString(),
        ...data,
      };

      _log('  Parâmetros completos sendo enviados:');
      params.forEach((key, value) {
        _log('    $key = "$value" (${value.runtimeType})');
      });

      final res = await _callWs(baseUrl, token, 'mod_data_add_entry', params);

      _log('  Resposta de mod_data_add_entry:');
      _log('    Tipo: ${res.runtimeType}');
      _log('    Keys: ${res.keys.join(", ")}');
      _log('    CONTEÚDO COMPLETO: $res');

      if (res.containsKey('newentryid')) {
        _log(
            '    Campo "newentryid": tipo=${res["newentryid"].runtimeType}, valor=${res["newentryid"]}');
      }

      _stateEntryId = (res['newentryid'] as num?)?.toInt();
      _log('  stateEntryId extraído: $_stateEntryId');
    } else {
      _log(
          '  stateEntryId existe: $_stateEntryId → chamando mod_data_update_entry');

      await _callWs(baseUrl, token, 'mod_data_update_entry', {
        'entryid': _stateEntryId!.toString(),
        ...data,
      });

      _log('  mod_data_update_entry concluído');
    }
  }

  @override
  Future<void> releaseQuestion({
    required String baseUrl,
    required String token,
    required int courseId,
    required int page,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  }) async {
    _debugLog.clear(); // Limpa log anterior

    try {
      _logSeparator();
      _log('INÍCIO: releaseQuestion');
      _log('  courseId: $courseId');
      _log('  page: $page');
      _log('  duration: $duration');
      _log('  totalPages: $totalPages');
      _log('  quizName: $quizName');
      _log('  quizId: $quizId');
      _logSeparator();

      await _ensureFields(baseUrl, token, courseId);

      // Garante que temos o stateEntryId se já existe
      if (_stateEntryId == null) {
        _log('stateEntryId é null, chamando getState...');
        await getState(baseUrl, token, courseId);
      }

      final endsAt = DateTime.now()
          .add(Duration(seconds: duration))
          .toUtc()
          .toIso8601String();

      _log('Gravando novo estado: active, página $page');
      await _writeState(baseUrl, token, {
        'state': 'active',
        'current_page': page,
        'total_pages': totalPages,
        'quiz_id': quizId,
        'course_id': courseId,
        'quiz_name': quizName,
        'ends_at': endsAt,
      });

      _log('✅ releaseQuestion concluído com sucesso!');
      _logSeparator();
      _printFullLog();
    } catch (e, stack) {
      _logSeparator();
      _log('❌ ERRO em releaseQuestion: $e');
      _log('Stack trace: $stack');
      _logSeparator();
      _printFullLog();
      rethrow;
    }
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

    if (existing.isEmpty) {
      // Primeira resposta deste aluno
      await _callWs(baseUrl, token, 'mod_data_add_entry', {
        'databaseid': _dataid!.toString(),
        'data[0][fieldid]': _typeFieldId!.toString(),
        'data[0][value]': 'score',
        'data[1][fieldid]': _stateJsonFieldId!.toString(),
        'data[1][value]': '',
        'data[2][fieldid]': _studentIdFieldId!.toString(),
        'data[2][value]': studentId,
        'data[3][fieldid]': _studentNameFieldId!.toString(),
        'data[3][value]': studentName,
        'data[4][fieldid]': _scoreFieldId!.toString(),
        'data[4][value]': score.toString(),
        'data[5][fieldid]': _correctCountFieldId!.toString(),
        'data[5][value]': correct ? '1' : '0',
        'data[6][fieldid]': _pagesFieldId!.toString(),
        'data[6][value]': jsonEncode([page]),
      });
    } else {
      // Acumula — ignora se a página já foi submetida
      List<int> prevPages = [];
      try {
        prevPages = (jsonDecode(existing['pages'] as String? ?? '[]') as List)
            .map((e) => (e as num).toInt())
            .toList();
      } catch (_) {}
      if (prevPages.contains(page)) return;

      final entryId = existing['_entry_id'] as int;
      final newScore = (existing['score'] as int) + score;
      final newCorrect = (existing['correct_count'] as int) + (correct ? 1 : 0);
      final newPages = [...prevPages, page];

      await _callWs(baseUrl, token, 'mod_data_update_entry', {
        'entryid': entryId.toString(),
        'data[0][fieldid]': _typeFieldId!.toString(),
        'data[0][value]': 'score',
        'data[1][fieldid]': _stateJsonFieldId!.toString(),
        'data[1][value]': '',
        'data[2][fieldid]': _studentIdFieldId!.toString(),
        'data[2][value]': studentId,
        'data[3][fieldid]': _studentNameFieldId!.toString(),
        'data[3][value]': studentName,
        'data[4][fieldid]': _scoreFieldId!.toString(),
        'data[4][value]': newScore.toString(),
        'data[5][fieldid]': _correctCountFieldId!.toString(),
        'data[5][value]': newCorrect.toString(),
        'data[6][fieldid]': _pagesFieldId!.toString(),
        'data[6][value]': jsonEncode(newPages),
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
    _log('_callWs: $function');
    _log('  Parâmetros recebidos (${params.length} items):');
    params.forEach((key, value) {
      if (value.length > 100) {
        _log(
            '    $key = "${value.substring(0, 100)}..." (${value.length} chars)');
      } else {
        _log('    $key = "$value"');
      }
    });

    final uri = Uri.parse('$baseUrl/webservice/rest/server.php');

    final body = {
      'wstoken': token,
      'wsfunction': function,
      'moodlewsrestformat': 'json',
      ...params,
    };

    _log('  Fazendo requisição HTTP (POST)...');
    final resp = await _client.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );

    if (resp.statusCode != 200) {
      _log('  ❌ HTTP ${resp.statusCode}');
      throw StateException('Erro HTTP ${resp.statusCode}');
    }

    _log('  ✅ HTTP 200 OK');
    _log('  Body length: ${resp.body.length} bytes');
    _log('  Body: ${resp.body}');

    final data = jsonDecode(resp.body);
    _log('  Após jsonDecode: tipo=${data.runtimeType}');

    if (data is Map && data['exception'] != null) {
      _log('  ❌ Moodle Exception: ${data["message"]}');
      throw StateException(
        data['message']?.toString() ?? 'Erro desconhecido no Moodle',
        code: data['errorcode']?.toString(),
      );
    }

    if (data is Map<String, dynamic>) {
      _log('  Retornando Map com ${data.length} keys');
      return data;
    }

    _log('  Retornando Map wrapper');
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
