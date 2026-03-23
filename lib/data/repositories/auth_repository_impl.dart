import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_auth_repository.dart';
import '../datasources/moodle_datasource.dart';

/// L: Substitui IAuthRepository sem quebrar nenhum contrato.
class AuthRepositoryImpl implements IAuthRepository {
  final IMoodleDatasource _moodle;

  // Funções exclusivas de professor (requerem papel de teacher/manager no Moodle).
  // NÃO incluir mod_quiz_get_attempt_review nem core_grades_get_gradebook:
  // essas funções também estão disponíveis para alunos (revisão própria, notas pessoais).
  static const _teacherFunctions = {
    'mod_assign_save_grade',                       // atribuir notas (teacher only)
    'gradereport_grader_get_items_in_gradebook',   // relatório do avaliador (teacher only)
  };

  AuthRepositoryImpl(this._moodle);

  @override
  Future<UserEntity> login(
      String baseUrl, String username, String password) async {
    final data = await _moodle.login(baseUrl, username, password);
    final functions = Set<String>.from(
        (data['functions'] as List? ?? []).cast<String>());
    final isTeacher =
        functions.any((f) => _teacherFunctions.contains(f));

    return UserEntity(
      id: (data['userId'] as num?)?.toInt() ?? 0,
      username: username,
      fullname: data['fullname']?.toString() ?? username,
      token: data['token'] as String,
      baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
      isTeacher: isTeacher,
      availableFunctions: functions,
    );
  }

  @override
  Future<void> saveSession(UserEntity user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session', jsonEncode({
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
