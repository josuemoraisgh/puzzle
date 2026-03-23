import 'dart:convert';
import 'package:http/http.dart' as http;

/// Interface – S: apenas chamadas à API REST do Moodle.
abstract class IMoodleDatasource {
  Future<Map<String, dynamic>> login(
      String baseUrl, String username, String password);

  /// Lista os cursos em que o usuário está matriculado.
  Future<List<Map<String, dynamic>>> getCourses(
      String baseUrl, String token, int userId);

  /// Lista os questionários de um curso.
  Future<List<Map<String, dynamic>>> getQuizzesByCourse(
      String baseUrl, String token, int courseId);

  /// Inicia (ou retoma) uma tentativa. Retorna o attemptId.
  Future<int> startAttempt(String baseUrl, String token, int quizId);

  /// Lista tentativas do usuário para um quiz. status: 'all'|'finished'|'unfinished'.
  Future<List<Map<String, dynamic>>> getUserAttempts(
      String baseUrl, String token, int quizId,
      {String status = 'all'});

  /// Retorna dados de uma página da tentativa (inclui HTML das questões).
  Future<Map<String, dynamic>> getAttemptData(
      String baseUrl, String token, int attemptId, int page);

  /// Submete as respostas de uma página. Retorna o estado da tentativa.
  Future<Map<String, dynamic>> processAttempt(String baseUrl, String token,
      int attemptId, Map<String, String> answerData);

  /// Finaliza a tentativa.
  Future<void> finishAttempt(String baseUrl, String token, int attemptId);

  /// Obtém a revisão de uma tentativa finalizada (inclui HTML com marcações correct/incorrect).
  Future<Map<String, dynamic>> getAttemptReview(
      String baseUrl, String token, int attemptId, int page);

  Future<void> saveGrade({
    required String baseUrl,
    required String token,
    required int userId,
    required int assignId,
    required double grade,
  });

  /// Retorna os shortnames dos papéis do usuário em um curso específico.
  /// Usa core_enrol_get_enrolled_users filtrado pelo userId.
  Future<List<String>> getUserRolesInCourse(
      String baseUrl, String token, int courseId, int userId);

  /// Lista as atividades Database de um curso.
  Future<List<Map<String, dynamic>>> getDataActivitiesByCourse(
      String baseUrl, String token, int courseId);
}

/// Implementação concreta – D: depende apenas de http.
class MoodleDatasource implements IMoodleDatasource {
  final http.Client _client;

  MoodleDatasource([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<Map<String, dynamic>> login(
      String baseUrl, String username, String password) async {
    final url = Uri.parse('$baseUrl/login/token.php');
    final resp = await _client.post(url, body: {
      'username': username,
      'password': password,
      'service': 'moodle_mobile_app',
    });
    _assertOk(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['error'] != null) throw MoodleException(data['error'].toString());

    final token = data['token'] as String?;
    if (token == null) {
      throw MoodleException('Token não retornado pelo Moodle.');
    }

    final siteInfo = await _callWs(
      baseUrl,
      token,
      'core_webservice_get_site_info',
      {},
    );

    final functions = <String>{};
    for (final fn in (siteInfo['functions'] as List? ?? [])) {
      final name = (fn as Map)['name']?.toString();
      if (name != null && name.isNotEmpty) functions.add(name);
    }

    return {
      'token': token,
      'userId': siteInfo['userid'],
      'fullname': siteInfo['fullname'],
      'functions': functions.toList(),
      'baseUrl': baseUrl,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getCourses(
      String baseUrl, String token, int userId) async {
    final result = await _callWs(
      baseUrl,
      token,
      'core_enrol_get_users_courses',
      {'userid': userId.toString()},
    );
    final list = result['result'];
    if (list is List) {
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuizzesByCourse(
      String baseUrl, String token, int courseId) async {
    final result = await _callWs(
      baseUrl,
      token,
      'mod_quiz_get_quizzes_by_courses',
      {'courseids[0]': courseId.toString()},
    );
    final quizzes = result['quizzes'];
    if (quizzes is List) {
      return quizzes.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  @override
  Future<int> startAttempt(String baseUrl, String token, int quizId) async {
    final result = await _callWs(
      baseUrl,
      token,
      'mod_quiz_start_attempt',
      {'quizid': quizId.toString()},
    );
    final attempt = result['attempt'];
    if (attempt == null) throw MoodleException('Falha ao iniciar tentativa');
    return (attempt['id'] as num).toInt();
  }

  @override
  Future<Map<String, dynamic>> getAttemptData(
      String baseUrl, String token, int attemptId, int page) async {
    return _callWs(
      baseUrl,
      token,
      'mod_quiz_get_attempt_data',
      {
        'attemptid': attemptId.toString(),
        'page': page.toString(),
      },
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getUserAttempts(
      String baseUrl, String token, int quizId,
      {String status = 'all'}) async {
    final result = await _callWs(baseUrl, token, 'mod_quiz_get_user_attempts', {
      'quizid': quizId.toString(),
      'status': status,
      'includepreviews': '0',
    });
    final attempts = result['attempts'] as List? ?? [];
    return attempts.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  @override
  Future<Map<String, dynamic>> processAttempt(String baseUrl, String token,
      int attemptId, Map<String, String> answerData) async {
    final params = <String, String>{
      'attemptid': attemptId.toString(),
      'finishattempt': '0',
    };
    int i = 0;
    for (final entry in answerData.entries) {
      params['data[$i][name]'] = entry.key;
      params['data[$i][value]'] = entry.value;
      i++;
    }
    return _callWs(baseUrl, token, 'mod_quiz_process_attempt', params);
  }

  @override
  Future<Map<String, dynamic>> getAttemptReview(
      String baseUrl, String token, int attemptId, int page) async {
    return _callWs(
      baseUrl,
      token,
      'mod_quiz_get_attempt_review',
      {
        'attemptid': attemptId.toString(),
        'page': page.toString(),
      },
    );
  }

  @override
  Future<void> finishAttempt(
      String baseUrl, String token, int attemptId) async {
    await _callWs(
      baseUrl,
      token,
      'mod_quiz_process_attempt',
      {
        'attemptid': attemptId.toString(),
        'finishattempt': '1',
      },
    );
  }

  @override
  Future<void> saveGrade({
    required String baseUrl,
    required String token,
    required int userId,
    required int assignId,
    required double grade,
  }) async {
    await _callWs(baseUrl, token, 'mod_assign_save_grade', {
      'assignmentid': assignId.toString(),
      'userid': userId.toString(),
      'grade': grade.toStringAsFixed(2),
      'attemptnumber': '-1',
      'addattempt': '0',
      'workflowstate': 'released',
      'applytoall': '0',
    });
  }

  @override
  Future<List<String>> getUserRolesInCourse(
      String baseUrl, String token, int courseId, int userId) async {
    try {
      final result = await _callWs(
        baseUrl,
        token,
        'core_enrol_get_enrolled_users',
        {
          'courseid': courseId.toString(),
          'options[0][name]': 'userids',
          'options[0][value]': userId.toString(),
        },
      );
      final users = result['result'];
      if (users is List) {
        for (final user in users) {
          if (user is Map && (user['id'] as num?)?.toInt() == userId) {
            final roles = user['roles'] as List? ?? [];
            return roles
                .map((r) => (r as Map)['shortname']?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
          }
        }
      }
    } on MoodleException {
      // Pode falhar se o usuário não tem permissão para ver participantes
    }
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> getDataActivitiesByCourse(
      String baseUrl, String token, int courseId) async {
    final result = await _callWs(
      baseUrl,
      token,
      'mod_data_get_databases_by_courses',
      {'courseids[0]': courseId.toString()},
    );
    final databases = result['databases'];
    if (databases is List) {
      return databases.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  // ── Privado ────────────────────────────────────────────────────────────────

  /// Chama um web service Moodle diretamente via GET.
  /// Se a resposta for uma lista JSON, retorna {'result': [lista]}.
  Future<Map<String, dynamic>> _callWs(
    String baseUrl,
    String token,
    String function,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse('$baseUrl/webservice/rest/server.php').replace(
      queryParameters: {
        'wstoken': token,
        'wsfunction': function,
        'moodlewsrestformat': 'json',
        ...params,
      },
    );
    final resp = await _client.get(uri);
    _assertOk(resp);
    final data = jsonDecode(resp.body);
    if (data is Map && data['exception'] != null) {
      final code = data['errorcode']?.toString() ?? '';
      throw MoodleException(
          _friendlyError(code, data['message']?.toString() ?? ''),
          errorCode: code);
    }
    if (data is Map<String, dynamic>) return data;
    return {'result': data};
  }

  void _assertOk(http.Response resp) {
    if (resp.statusCode != 200) {
      throw MoodleException('Erro HTTP ${resp.statusCode}');
    }
  }

  String _friendlyError(String code, String message) {
    const map = {
      'invalidlogin': 'Usuário ou senha incorretos.',
      'accessdenied': 'Função não autorizada no serviço externo do Moodle.',
      'nopermissions': 'Sem permissão para realizar esta operação.',
      'invalidrecordunknown': 'Registro não encontrado no Moodle.',
      'servicenotavailable': 'Serviço Moodle não encontrado.',
    };
    return map[code] ?? message;
  }
}

class MoodleException implements Exception {
  final String message;
  final String? errorCode;
  MoodleException(this.message, {this.errorCode});
  @override
  String toString() => message;
}
