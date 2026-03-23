import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/responsive.dart';
import '../../../domain/entities/question_entity.dart';
import '../../../domain/entities/quiz_state_entity.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/professor_controller.dart';
import '../../../core/utils/fullscreen_button.dart';
import '../../widgets/timer_widget.dart';

/// Painel do professor – controle de questões + status do quiz.
class ProfessorHomePage extends StatefulWidget {
  const ProfessorHomePage({super.key});

  @override
  State<ProfessorHomePage> createState() => _ProfessorHomePageState();
}

class _ProfessorHomePageState extends State<ProfessorHomePage> {
  int _questionIndex = 0; // índice da questão atualmente selecionada

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProfessorController>().startPolling();
    });
  }

  @override
  void dispose() {
    context.read<ProfessorController>().stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ProfessorController, AuthController>(
      builder: (context, prof, auth, _) {
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
            child: SafeArea(
              child: Responsive.isDesktop(context)
                  ? _DesktopLayout(
                      prof: prof,
                      auth: auth,
                      questionIndex: _questionIndex,
                      onIndexChanged: (i) =>
                          setState(() => _questionIndex = i),
                    )
                  : _MobileLayout(
                      prof: prof,
                      auth: auth,
                      questionIndex: _questionIndex,
                      onIndexChanged: (i) =>
                          setState(() => _questionIndex = i),
                    ),
            ),
          ),
        );
      },
    );
  }
}

// ── Desktop: side-by-side ─────────────────────────────────────────────────────

class _DesktopLayout extends StatelessWidget {
  final ProfessorController prof;
  final AuthController auth;
  final int questionIndex;
  final void Function(int) onIndexChanged;

  const _DesktopLayout({
    required this.prof,
    required this.auth,
    required this.questionIndex,
    required this.onIndexChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Painel lateral – lista de questões
        SizedBox(
          width: 320,
          child: _QuestionListPanel(
            questions: prof.questions,
            selectedIndex: questionIndex,
            quizState: prof.quizState,
            onSelect: onIndexChanged,
          ),
        ),
        const VerticalDivider(
            width: 1, color: AppTheme.bgCard),
        // Painel principal – controles
        Expanded(
          child: _ControlPanel(
            prof: prof,
            auth: auth,
            selectedIndex: questionIndex,
          ),
        ),
      ],
    );
  }
}

// ── Mobile: abas ──────────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  final ProfessorController prof;
  final AuthController auth;
  final int questionIndex;
  final void Function(int) onIndexChanged;

  const _MobileLayout({
    required this.prof,
    required this.auth,
    required this.questionIndex,
    required this.onIndexChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          _ProfessorAppBar(auth: auth, prof: prof),
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.list_alt), text: 'Questões'),
              Tab(icon: Icon(Icons.tune), text: 'Controle'),
            ],
            indicatorColor: AppTheme.primary,
            labelColor: AppTheme.textPrimary,
            unselectedLabelColor: AppTheme.textSecondary,
          ),
          Expanded(
            child: TabBarView(
              children: [
                _QuestionListPanel(
                  questions: prof.questions,
                  selectedIndex: questionIndex,
                  quizState: prof.quizState,
                  onSelect: onIndexChanged,
                ),
                _ControlPanel(
                  prof: prof,
                  auth: auth,
                  selectedIndex: questionIndex,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── AppBar do professor ───────────────────────────────────────────────────────

class _ProfessorAppBar extends StatelessWidget {
  final AuthController auth;
  final ProfessorController prof;
  const _ProfessorAppBar({required this.auth, required this.prof});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: AppTheme.textSecondary, size: 20),
            tooltip: 'Voltar para seleção de questionário',
            onPressed: () {
              prof.stopPolling();
              context.go(AppRouter.professorQuiz);
            },
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.school_rounded,
                color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              prof.quizState.quizTitle.isNotEmpty
                ? prof.quizState.quizTitle
                : AppConfig.appName,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const FullscreenButton(),
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded,
                color: AppTheme.textSecondary),
            tooltip: 'QR Code do Aluno',
            onPressed: () => context.go(AppRouter.professorQrCode),
          ),
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded,
                color: AppTheme.accent),
            tooltip: 'Ver Ranking',
            onPressed: () => context.push(AppRouter.professorRank),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppTheme.textSecondary),
            tooltip: 'Sair',
            onPressed: () async {
              prof.stopPolling();
              await auth.logout();
              if (context.mounted) context.go(AppRouter.login);
            },
          ),
        ],
      ),
    );
  }
}

// ── Lista de questões ─────────────────────────────────────────────────────────

class _QuestionListPanel extends StatelessWidget {
  final List<QuestionEntity> questions;
  final int selectedIndex;
  final QuizStateEntity quizState;
  final void Function(int) onSelect;

  const _QuestionListPanel({
    required this.questions,
    required this.selectedIndex,
    required this.quizState,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (questions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Nenhuma questão de múltipla escolha.\nConsulte o log de carregamento.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: questions.length,
      itemBuilder: (_, i) {
        final q = questions[i];
        final isActive =
            quizState.currentPage == q.page && quizState.isActive;
        final isSelected = i == selectedIndex;

        return GestureDetector(
          onTap: () => onSelect(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: isActive ? AppTheme.primaryGradient : null,
              color: isActive ? null : (isSelected ? AppTheme.bgCard : AppTheme.bgCardAlt),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? AppTheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isActive
                        ? Colors.white.withValues(alpha: 0.2)
                        : AppTheme.bgDark,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w800,
                        color: isActive ? Colors.white : AppTheme.primary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    q.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive
                          ? Colors.white
                          : AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (isActive)
                  const Icon(Icons.play_circle_fill,
                      color: Colors.white, size: 18),
              ],
            ),
          ).animate(delay: Duration(milliseconds: i * 40)).fadeIn().slideX(
              begin: -0.1, duration: 300.ms),
        );
      },
    );
  }
}

// ── Painel de controle ────────────────────────────────────────────────────────

class _ControlPanel extends StatelessWidget {
  final ProfessorController prof;
  final AuthController auth;
  final int selectedIndex;

  const _ControlPanel({
    required this.prof,
    required this.auth,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final state = prof.quizState;
    final questions = prof.questions;
    final hasQuestions = questions.isNotEmpty;
    final selectedQ =
        hasQuestions && selectedIndex < questions.length
            ? questions[selectedIndex]
            : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AppBar só no desktop
          if (Responsive.isDesktop(context))
            _ProfessorAppBar(auth: auth, prof: prof),

          // ── Status atual ─────────────────────────────────────────────
          _StatusCard(state: state),
          const SizedBox(height: 16),

          // ── Timer da questão ativa ───────────────────────────────────
          if (state.isActive && state.endsAt != null) ...[
            TimerWidget(
              endsAt: state.endsAt!,
              onTimeUp: () => prof.stopQuestion(),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: prof.isLoading ? null : () => prof.extendQuestion(15),
              icon: const Icon(Icons.add_alarm_rounded, color: AppTheme.accent),
              label: const Text('+15s',
                  style: TextStyle(color: AppTheme.accent)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accent),
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // ── Seletor de tempo ─────────────────────────────────────────
          _DurationSelector(
            value: prof.selectedDuration,
            onChange: prof.setDuration,
            enabled: !state.isActive,
          ),
          const SizedBox(height: 16),

          // ── Questão selecionada ──────────────────────────────────────
          if (selectedQ != null) ...[
            _SelectedQuestionCard(question: selectedQ, index: selectedIndex),
            const SizedBox(height: 16),
          ],

          // ── Botões de ação ───────────────────────────────────────────
          if (state.isActive)
            _ActionButton(
              label: 'Encerrar Questão',
              icon: Icons.stop_circle_rounded,
              color: AppTheme.danger,
              loading: prof.isLoading,
              onPressed: prof.stopQuestion,
            )
          else
            _ActionButton(
              label: selectedQ != null
                  ? 'Liberar Questão ${selectedIndex + 1}'
                  : 'Selecione uma questão',
              icon: Icons.play_circle_fill_rounded,
              color: AppTheme.success,
              loading: prof.isLoading,
              onPressed: (selectedQ != null && !prof.isLoading)
                  ? () => prof.releaseQuestion(selectedQ)
                  : null,
            ),

          const SizedBox(height: 12),

          // ── Mostrar Gabarito (quando questão encerrada) ───────────────
          if (state.isClosed || state.isFinished) ...[
            const SizedBox(height: 4),
            ElevatedButton.icon(
              onPressed: () => context.push(AppRouter.professorReveal),
              icon: const Icon(Icons.fact_check_rounded),
              label: const Text('Mostrar Gabarito'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],

          const SizedBox(height: 4),

          // ── Ver Ranking ──────────────────────────────────────────────
          OutlinedButton.icon(
            onPressed: () => context.push(AppRouter.professorRank),
            icon: const Icon(Icons.leaderboard_rounded,
                color: AppTheme.accent),
            label: const Text('Ver Ranking Completo',
                style: TextStyle(color: AppTheme.accent)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.accent),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),

          const SizedBox(height: 12),

          // ── Reset quiz ───────────────────────────────────────────────
          TextButton.icon(
            onPressed: prof.isLoading
                ? null
                : () => _confirmReset(context, prof),
            icon: const Icon(Icons.refresh_rounded,
                color: AppTheme.textSecondary, size: 18),
            label: const Text('Reiniciar Quiz',
                style:
                    TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          ),

          // ── Erro ─────────────────────────────────────────────────────
          if (prof.error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.danger.withValues(alpha: 0.4)),
              ),
              child: Text(prof.error!,
                  style: const TextStyle(
                      color: AppTheme.danger, fontSize: 13)),
            ),
          ],

          // ── Log de carregamento — sempre visível no painel de controle ──
          if (prof.log.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(height: 220, child: _LogPanel(log: prof.log)),
          ],

          // ── Mini ranking ─────────────────────────────────────────────
          if (prof.scores.isNotEmpty) ...[
            const SizedBox(height: 24),
            _MiniRanking(scores: prof.scores),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmReset(
      BuildContext context, ProfessorController prof) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text('Reiniciar Quiz',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Isso apaga todas as respostas e pontuações. Confirma?',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reiniciar'),
          ),
        ],
      ),
    );
    if (ok == true) await prof.resetQuiz();
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final QuizStateEntity state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state.status) {
      QuizStatus.active => ('Questão Ativa', AppTheme.success, Icons.play_circle_fill),
      QuizStatus.closed => ('Questão Encerrada', AppTheme.warning, Icons.pause_circle_filled),
      QuizStatus.finished => ('Quiz Finalizado', AppTheme.accent, Icons.emoji_events),
      _ => ('Aguardando Início', AppTheme.textSecondary, Icons.hourglass_empty),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration(
          glowing: state.isActive),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
              if (state.currentPage >= 0)
                Text(
                  'Questão ${state.currentPage + 1}'
                  '${state.totalPages > 0 ? ' / ${state.totalPages}' : ''}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
            ],
          ),
          const Spacer(),
          if (state.isActive)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                  color: AppTheme.success, shape: BoxShape.circle),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .scaleXY(end: 0.5, duration: 600.ms),
        ],
      ),
    );
  }
}

class _DurationSelector extends StatelessWidget {
  final int value;
  final void Function(int) onChange;
  final bool enabled;

  const _DurationSelector({
    required this.value,
    required this.onChange,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final options = AppConfig.questionTimeOptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Tempo por questão',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((sec) {
            final selected = sec == value;
            return GestureDetector(
              onTap: enabled ? () => onChange(sec) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  gradient: selected ? AppTheme.primaryGradient : null,
                  color: selected ? null : AppTheme.bgCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? AppTheme.primary
                        : AppTheme.bgCardAlt,
                  ),
                ),
                child: Text(
                  '${sec}s',
                  style: TextStyle(
                    color: selected
                        ? Colors.white
                        : AppTheme.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _SelectedQuestionCard extends StatelessWidget {
  final QuestionEntity question;
  final int index;
  const _SelectedQuestionCard(
      {required this.question, required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Questão ${index + 1}',
              style: const TextStyle(
                  color: AppTheme.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            question.text,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.4),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: question.choices.asMap().entries.map((e) {
              final label =
                  String.fromCharCode(65 + e.key); // A, B, C…
              final choice = e.value;
              final isCorrect = choice.isCorrect;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isCorrect
                      ? AppTheme.success.withValues(alpha: 0.18)
                      : AppTheme.bgCardAlt,
                  borderRadius: BorderRadius.circular(6),
                  border: isCorrect
                      ? Border.all(
                          color: AppTheme.success.withValues(alpha: 0.6),
                          width: 1.5)
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCorrect) ...[
                      const Icon(Icons.check_circle_rounded,
                          color: AppTheme.success, size: 14),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      '$label: ${choice.text}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isCorrect
                            ? AppTheme.success
                            : AppTheme.textSecondary,
                        fontWeight: isCorrect
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool loading;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2))
          : Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  final List<String> log;
  const _LogPanel({required this.log});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.bgCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.terminal_rounded, color: AppTheme.accent, size: 14),
              SizedBox(width: 6),
              Text('Log de carregamento',
                  style: TextStyle(
                      color: AppTheme.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: log.length,
              itemBuilder: (_, i) => Text(
                log[i],
                style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniRanking extends StatelessWidget {
  final List<dynamic> scores;
  const _MiniRanking({required this.scores});

  @override
  Widget build(BuildContext context) {
    final top5 = scores.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Top 5',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...top5.asMap().entries.map((e) {
          final s = e.value;
          final colors = [
            AppTheme.gold,
            AppTheme.silver,
            AppTheme.bronze,
            AppTheme.textSecondary,
            AppTheme.textSecondary,
          ];
          final rankColor = e.key < 3
              ? colors[e.key]
              : AppTheme.textSecondary;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text('${e.key + 1}',
                      style: TextStyle(
                          color: rankColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 13)),
                ),
                Expanded(
                  child: Text(
                    s.studentName,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${s.score} pts',
                  style: TextStyle(
                      color: rankColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
