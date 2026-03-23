import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_auth_repository.dart';
import '../datasources/moodle_datasource.dart';

/// L: Substitui IAuthRepository sem quebrar nenhum contrato.
class AuthRepositoryImpl implements IAuthRepository {
  final IMoodleDatasource _moodle;

  // Papéis do Moodle que devem ser tratados como professor.
  // Qualquer outro papel (student, guest, user, etc.) é considerado estudante.
  static const _teacherRoles = {
    'manager',
    'coursecreator',
    'editingteacher',
    'teacher',
  };

  // Funções exclusivas de professor – fallback quando a detecção por papéis
  // não encontra nenhum curso ou falha.
  static const _teacherFunctions = {
    'mod_assign_save_grade',
    'gradereport_grader_get_items_in_gradebook',
  };

  AuthRepositoryImpl(this._moodle);

  @override
  Future<UserEntity> login(
      String baseUrl, String username, String password) async {
    final data = await _moodle.login(baseUrl, username, password);
    final functions =
        Set<String>.from((data['functions'] as List? ?? []).cast<String>());
    final userId = (data['userId'] as num?)?.toInt() ?? 0;
    final cleanUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

    // ── Detecção de papel via cursos do Moodle ──────────────────────────────
    final isTeacher = await _checkTeacherRole(
      cleanUrl,
      data['token'] as String,
      userId,
      functions,
    );

    return UserEntity(
      id: userId,
      username: username,
      fullname: data['fullname']?.toString() ?? username,
      token: data['token'] as String,
      baseUrl: cleanUrl,
      isTeacher: isTeacher,
      availableFunctions: functions,
    );
  }

  /// Verifica se o usuário é professor consultando seus papéis nos cursos.
  /// Fallback: usa heurística por funções do webservice se não houver cursos
  /// ou se a API de papéis falhar.
  Future<bool> _checkTeacherRole(
    String baseUrl,
    String token,
    int userId,
    Set<String> functions,
  ) async {
    try {
      final courses = await _moodle.getCourses(baseUrl, token, userId);
      if (courses.isNotEmpty) {
        for (final course in courses) {
          final courseId = (course['id'] as num?)?.toInt();
          if (courseId == null) continue;
          final roles = await _moodle.getUserRolesInCourse(
              baseUrl, token, courseId, userId);
          if (roles.any((r) => _teacherRoles.contains(r))) {
            return true;
          }
        }
        // Verificou cursos e não encontrou papel de professor em nenhum.
        return false;
      }
    } catch (_) {
      // API falhou – segue para fallback por funções
    }

    // Fallback: detecta por funções disponíveis no webservice
    return functions.any((f) => _teacherFunctions.contains(f));
  }

  @override
  Future<void> saveSession(UserEntity user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'session',
        jsonEncode({
          'id': user.id,
          'username': user.username,
          'fullname': user.fullname,
          'token': user.token,
          'baseUrl': user.baseUrl,
          'isTeacher': user.isTeacher,
          'functions': user.availableFunctions.toList(),
        }));
  }

  @override
  Future<UserEntity?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('session');
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return UserEntity(
      id: (json['id'] as num).toInt(),
      username: json['username'] as String,
      fullname: json['fullname'] as String,
      token: json['token'] as String,
      baseUrl: json['baseUrl'] as String,
      isTeacher: json['isTeacher'] as bool? ?? false,
      availableFunctions:
          Set<String>.from((json['functions'] as List? ?? []).cast<String>()),
    );
  }

  @override
  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session');
  }
}
