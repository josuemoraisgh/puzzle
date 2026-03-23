import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/config/app_config.dart';

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

    final token = data['token'] as String;

    final siteInfo = await _callWs(
      baseUrl,
      token,
      'core_webservice_get_site_info',
      {},
    );

    final functions = <String>{};
    for (final fn in (siteInfo['functions'] as List? ?? [])) {
      functions.add(fn['name'] as String);
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
    // core_enrol_get_users_courses retorna uma lista JSON diretamente
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
  Future<int> startAttempt(
      String baseUrl, String token, int quizId) async {
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

  // ── Privado ────────────────────────────────────────────────────────────────

  /// Chama um web service Moodle via GET.
  /// Na web usa o proxy GAS para contornar CORS; no desktop chama direto.
  /// Se a resposta for uma lista JSON, retorna {'result': <lista>}.
  Future<Map<String, dynamic>> _callWs(
    String baseUrl,
    String token,
    String function,
    Map<String, String> params,
  ) async {
    final wsParams = {
      'wstoken': token,
      'wsfunction': function,
      'moodlewsrestformat': 'json',
      ...params,
    };

    final Uri uri;
    if (kIsWeb && AppConfig.isConfigured) {
      // Proxy via Google Apps Script — sem restrição de CORS
      uri = Uri.parse(AppConfig.gsheetScriptUrl).replace(
        queryParameters: {
          'action': 'moodleProxy',
          'baseUrl': baseUrl,
          ...wsParams,
        },
      );
    } else {
      uri = Uri.parse('$baseUrl/webservice/rest/server.php')
          .replace(queryParameters: wsParams);
    }

    final resp = await _client.get(uri);
    _assertOk(resp);
    final data = jsonDecode(resp.body);
    if (data is Map && data['exception'] != null) {
      throw MoodleException(
          _friendlyError(data['errorcode']?.toString() ?? '',
              data['message']?.toString() ?? ''));
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
  MoodleException(this.message);
  @override
  String toString() => message;
}
