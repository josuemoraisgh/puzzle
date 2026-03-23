import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/responsive.dart';
import '../../../domain/entities/quiz_state_entity.dart';
import '../../../domain/entities/score_entity.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/student_controller.dart';
import 'student_question_page.dart';

/// Tela do estudante – lobby de espera e questão ativa.
class StudentLobbyPage extends StatefulWidget {
  const StudentLobbyPage({super.key});

  @override
  State<StudentLobbyPage> createState() => _StudentLobbyPageState();
}

class _StudentLobbyPageState extends State<StudentLobbyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = context.read<AuthController>().user!;
      context.read<StudentController>().startPolling(user);
    });
  }

  @override
  void dispose() {
    context.read<StudentController>().stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<StudentController, AuthController>(
      builder: (context, student, auth, _) {
        final state = student.quizState;

        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
            child: SafeArea(
              child: Column(
                children: [
                  _TopBar(
                    title: state.quizTitle,
                    fullname: auth.user!.fullname,
                    onLogout: () async {
                      student.stopPolling();
                      await auth.logout();
                      if (context.mounted) context.go(AppRouter.login);
                    },
                  ),
                  Expanded(
                    child: _buildBody(context, state, student, auth),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    QuizStateEntity state,
    StudentController student,
    AuthController auth,
  ) {
    // Questão ativa → mostra tela de resposta
    if (state.isActive && student.currentQuestion != null) {
      return StudentQuestionPage(
        question: student.currentQuestion!,
        endsAt: state.endsAt,
        selectedChoice: student.selectedChoice,
        hasAnswered: student.hasAnswered,
        isSubmitting: student.isSubmitting,
        onSelect: student.selectChoice,
        onSubmit: () => student.submitAnswer(auth.user!),
      );
    }

    // Carregando questão
    if (state.isActive && student.isLoadingQuestion) {
      return const Center(child: CircularProgressIndicator());
    }

    final myScore = student.myScore(auth.user!.id.toString());

    // Questão fechada → mostra resultado
    if (state.isClosed) {
      return _ClosedQuestionView(
        wasCorrect: student.lastAnswerCorrect,
        answered: student.hasAnswered,
        selectedText: _selectedChoiceText(student),
        myScore: myScore,
        totalPages: state.totalPages,
      );
    }

    // Finalizado → tela de fim
    if (state.isFinished) {
      return _FinalView(myScore: myScore, totalPages: state.totalPages);
    }

    // Aguardando
    return _WaitingView(
      title: state.quizTitle,
      userName: auth.user!.fullname,
      currentPage: state.currentPage,
      totalPages: state.totalPages,
      myScore: myScore,
    );
  }

  String? _selectedChoiceText(StudentController student) {
    final q = student.currentQuestion;
    final v = student.selectedChoice;
    if (q == null || v == null) return null;
    try {
      return q.choices.firstWhere((c) => c.value == v).text;
    } catch (_) {
      return v;
    }
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final String fullname;
  final VoidCallback onLogout;

  const _TopBar({
    required this.title,
    required this.fullname,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                const Icon(Icons.quiz_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            fullname.split(' ').first,
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.logout,
                color: AppTheme.textSecondary, size: 20),
            onPressed: onLogout,
            tooltip: 'Sair',
          ),
        ],
      ),
    );
  }
}

class _WaitingView extends StatelessWidget {
  final String title;
  final String userName;
  final int currentPage;
  final int totalPages;
  final ScoreEntity? myScore;

  const _WaitingView({
    required this.title,
    required this.userName,
    required this.currentPage,
    required this.totalPages,
    required this.myScore,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Responsive.horizontalPadding(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: AppTheme.cardDecoration(
                  gradient: AppTheme.primaryGradient, glowing: true),
              child: const Icon(Icons.hourglass_top_rounded,
                  color: Colors.white, size: 60),
            )
                .animate(onPlay: (c) => c.repeat())
                .shimmer(duration: 2000.ms, color: AppTheme.primaryLight),
            const SizedBox(height: 32),
            Text(
              'Olá, ${userName.split(' ').first}!',
              style: AppTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Aguardando o professor liberar\na próxima questão...',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 16, height: 1.5),
              textAlign: TextAlign.center,
            ),
            if (currentPage >= 0) ...[
              const SizedBox(height: 24),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: AppTheme.cardDecoration(),
                child: Text(
                  'Questão ${currentPage + 1}'
                  '${totalPages > 0 ? ' de $totalPages' : ''} concluída',
                  style: const TextStyle(
                      color: AppTheme.accent,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ),
            ],
            if (myScore != null) ...[
              const SizedBox(height: 16),
              _ScoreSummaryCard(score: myScore!, totalPages: totalPages),
            ],
            const SizedBox(height: 40),
            const _PulseDots(),
          ],
        ),
      ),
    );
  }
}

class _PulseDots extends StatelessWidget {
  const _PulseDots();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
        )
            .animate(
                delay: Duration(milliseconds: i * 200),
                onPlay: (c) => c.repeat(reverse: true))
            .scaleXY(end: 0.5, duration: 600.ms)
            .fadeOut(duration: 600.ms),
      ),
    );
  }
}

class _ScoreSummaryCard extends StatelessWidget {
  final ScoreEntity score;
  final int totalPages;
  const _ScoreSummaryCard({required this.score, required this.totalPages});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: AppTheme.cardDecoration(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: AppTheme.gold, size: 20),
          const SizedBox(width: 8),
          Text(
            '${score.score} pts',
            style: const TextStyle(
                color: AppTheme.gold,
                fontWeight: FontWeight.w800,
                fontSize: 16),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.check_circle_rounded,
              color: AppTheme.success, size: 18),
          const SizedBox(width: 6),
          Text(
            '${score.correctCount}'
            '${totalPages > 0 ? '/$totalPages' : ''} corretas',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.leaderboard_rounded,
              color: AppTheme.accent, size: 18),
          const SizedBox(width: 6),
          Text(
            '${score.rank}º',
            style: const TextStyle(
                color: AppTheme.accent,
                fontWeight: FontWeight.w700,
                fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ClosedQuestionView extends StatelessWidget {
  final bool wasCorrect;
  final bool answered;
  final String? selectedText;
  final ScoreEntity? myScore;
  final int totalPages;

  const _ClosedQuestionView({
    required this.wasCorrect,
    required this.answered,
    required this.selectedText,
    required this.myScore,
    required this.totalPages,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Responsive.horizontalPadding(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: answered
                        ? (wasCorrect
                            ? [AppTheme.success, const Color(0xFF00A152)]
                            : [AppTheme.danger, const Color(0xFFB71C1C)])
                        : [AppTheme.warning, const Color(0xFFF57F17)],
                  ),
                  borderRadius: BorderRadius.circular(50),
                  boxShadow: [
                    BoxShadow(
                      color: (answered
                              ? (wasCorrect
                                  ? AppTheme.success
                                  : AppTheme.danger)
                              : AppTheme.warning)
                          .withValues(alpha: 0.4),
                      blurRadius: 24,
                    )
                  ],
                ),
                child: Icon(
                  answered
                      ? (wasCorrect ? Icons.check_circle : Icons.cancel)
                      : Icons.timer_off,
                  color: Colors.white,
                  size: 52,
                ),
              ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
              const SizedBox(height: 24),
              Text(
                answered
                    ? (wasCorrect ? 'Correto! +1000 pts' : 'Incorreto!')
                    : 'Tempo esgotado!',
                style: AppTheme.headlineMedium,
              ),
              if (selectedText != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Sua resposta: $selectedText',
                  style: TextStyle(
                    color: wasCorrect ? AppTheme.success : AppTheme.danger,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (myScore != null) ...[
                const SizedBox(height: 20),
                _ScoreSummaryCard(score: myScore!, totalPages: totalPages),
              ],
              const SizedBox(height: 24),
              const Text(
                'Aguardando próxima questão...',
                style:
                    TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FinalView extends StatelessWidget {
  final ScoreEntity? myScore;
  final int totalPages;
  const _FinalView({required this.myScore, required this.totalPages});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Responsive.horizontalPadding(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events, color: AppTheme.gold, size: 80)
                .animate()
                .scale(duration: 600.ms, curve: Curves.elasticOut)
                .then()
                .shimmer(duration: 1500.ms, color: Colors.white),
            const SizedBox(height: 20),
            Text('Quiz Finalizado!', style: AppTheme.headlineLarge),
            const SizedBox(height: 8),
            const Text(
              'Obrigado por participar!',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 16),
            ),
            if (myScore != null) ...[
              const SizedBox(height: 32),
              _ScoreSummaryCard(score: myScore!, totalPages: totalPages),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: AppTheme.cardDecoration(),
                child: Column(
                  children: [
                    _StatRow(
                      icon: Icons.format_list_numbered_rounded,
                      label: 'Questões respondidas',
                      value: '${myScore!.totalAnswered}'
                          '${totalPages > 0 ? ' de $totalPages' : ''}',
                      color: AppTheme.textPrimary,
                    ),
                    const SizedBox(height: 8),
                    _StatRow(
                      icon: Icons.check_circle_rounded,
                      label: 'Respostas corretas',
                      value: '${myScore!.correctCount}',
                      color: AppTheme.success,
                    ),
                    const SizedBox(height: 8),
                    _StatRow(
                      icon: Icons.cancel_rounded,
                      label: 'Respostas erradas',
                      value:
                          '${myScore!.totalAnswered - myScore!.correctCount}',
                      color: AppTheme.danger,
                    ),
                    const SizedBox(height: 8),
                    _StatRow(
                      icon: Icons.star_rounded,
                      label: 'Pontuação total',
                      value: '${myScore!.score} pts',
                      color: AppTheme.gold,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatRow(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14))),
        Text(value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 15)),
      ],
    );
  }
}
