import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/datasources/gsheet_datasource.dart';
import 'data/datasources/moodle_datasource.dart';
import 'data/repositories/auth_repository_impl.dart';
import 'data/repositories/quiz_repository_impl.dart';
import 'domain/usecases/close_question_usecase.dart';
import 'domain/usecases/login_usecase.dart';
import 'domain/usecases/release_question_usecase.dart';
import 'domain/usecases/submit_answer_usecase.dart';
import 'presentation/controllers/auth_controller.dart';
import 'presentation/controllers/professor_controller.dart';
import 'presentation/controllers/student_controller.dart';

/// Ponto de entrada – composição de dependências seguindo princípio D (IoC).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Lê config.json estático (deployado junto com o app no GitHub Pages) ──
  try {
    final raw = await rootBundle.loadString('assets/config.json');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    AppConfig.gsheetScriptUrl = (map['gsheet_script_url'] as String?)?.trim() ?? '';
    AppConfig.studentUrl = (map['student_url'] as String?)?.trim() ?? AppConfig.studentUrl;
  } catch (_) {
    // Arquivo ausente em dev local – segue com valor vazio
  }

  // ── Instancia dependências ────────────────────────────────────────────────
  final moodleDs = MoodleDatasource();
  final gsheetDs = GSheetDatasource();

  // Carrega configurações do GSheets (moodle_url, quiz_title, teacher_token…)
  if (AppConfig.isConfigured) {
    try {
      final cfg = await gsheetDs.getConfig();
      AppConfig.loadFromMap(cfg);
    } catch (_) {
      // GSheets indisponível no boot – usa defaults
    }
  }

  final authRepo = AuthRepositoryImpl(moodleDs);
  final quizRepo = QuizRepositoryImpl(gsheetDs, moodleDs);

  final loginUseCase = LoginUseCase(authRepo);
  final releaseUseCase = ReleaseQuestionUseCase(quizRepo);
  final closeUseCase = CloseQuestionUseCase(quizRepo);
  final submitUseCase = SubmitAnswerUseCase(quizRepo);

  final authCtrl = AuthController(
    loginUseCase: loginUseCase,
    repository: authRepo,
  );

  await authCtrl.loadSavedSession();

  runApp(
    MultiProvider(
      providers: [
        Provider<IGSheetDatasource>.value(value: gsheetDs),
        ChangeNotifierProvider.value(value: authCtrl),
        ChangeNotifierProvider(
          create: (_) => ProfessorController(
            quizRepo: quizRepo,
            releaseQuestion: releaseUseCase,
            closeQuestion: closeUseCase,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => StudentController(
            quizRepo: quizRepo,
            submitAnswer: submitUseCase,
          ),
        ),
      ],
      child: const MoodleQuizApp(),
    ),
  );
}

class MoodleQuizApp extends StatelessWidget {
  const MoodleQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = AppRouter.build(context);

    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
