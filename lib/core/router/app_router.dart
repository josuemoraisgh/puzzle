import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../presentation/controllers/auth_controller.dart';
import '../../presentation/pages/login_page.dart';
import '../../presentation/pages/setup_page.dart';
import '../../presentation/pages/professor/course_selection_page.dart';
import '../../presentation/pages/professor/quiz_selection_page.dart';
import '../../presentation/pages/professor/professor_home_page.dart';
import '../../presentation/pages/professor/qrcode_page.dart';
import '../../presentation/pages/professor/professor_reveal_page.dart';
import '../../presentation/pages/professor/ranking_page.dart';
import '../../presentation/pages/student/student_lobby_page.dart';

/// S: Responsabilidade única – define e gera as rotas do app.
class AppRouter {
  static const String setup = '/setup';
  static const String login = '/login';
  static const String professorCourses = '/professor/courses';
  static const String professorQuiz = '/professor/quiz';
  static const String professor = '/professor';
  static const String professorRank = '/professor/rank';
  static const String professorQrCode = '/professor/qrcode';
  static const String professorReveal = '/professor/reveal';
  static const String student = '/student';

  static GoRouter build(BuildContext context) {
    return GoRouter(
      initialLocation: login,
      redirect: (context, state) {
        final auth = context.read<AuthController>();
        final isLogged = auth.user != null;
        final loc = state.matchedLocation;

        // Não autenticado → login (exceto setup)
        if (!isLogged && loc != login && loc != setup) return login;

        if (isLogged) {
          final user = auth.user!;

          // Redireciona para home correta se estiver no login
          if (loc == login) {
            return user.isTeacher ? professorCourses : student;
          }

          // Estudante tentando acessar rota de professor → redireciona
          if (!user.isTeacher && loc.startsWith('/professor')) {
            return student;
          }

          // Professor tentando acessar rota de estudante → redireciona
          if (user.isTeacher && loc == student) {
            return professorCourses;
          }
        }

        return null;
      },
      routes: [
        GoRoute(path: setup, builder: (_, __) => const SetupPage()),
        GoRoute(path: login, builder: (_, __) => const LoginPage()),
        GoRoute(
          path: professorCourses,
          builder: (_, __) => const CourseSelectionPage(),
        ),
        GoRoute(
          path: professorQuiz,
          builder: (_, __) => const QuizSelectionPage(),
        ),
        GoRoute(
          path: professor,
          builder: (_, __) => const ProfessorHomePage(),
          routes: [
            GoRoute(
              path: 'rank',
              builder: (_, __) => const RankingPage(),
            ),
          ],
        ),
        GoRoute(path: professorQrCode, builder: (_, __) => const QrCodePage()),
        GoRoute(
            path: professorReveal,
            builder: (_, __) => const ProfessorRevealPage()),
        GoRoute(path: student, builder: (_, __) => const StudentLobbyPage()),
      ],
    );
  }
}
