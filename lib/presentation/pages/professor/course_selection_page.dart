import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/responsive.dart';
import '../../../domain/entities/moodle_course.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/professor_controller.dart';

class CourseSelectionPage extends StatefulWidget {
  const CourseSelectionPage({super.key});

  @override
  State<CourseSelectionPage> createState() => _CourseSelectionPageState();
}

class _CourseSelectionPageState extends State<CourseSelectionPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCourses());
  }

  Future<void> _loadCourses() async {
    final user = context.read<AuthController>().user;
    if (user == null) return;
    await context.read<ProfessorController>().loadCourses(user);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: Responsive.contentWidth(context)),
              child: Padding(
                padding: Responsive.horizontalPadding(context)
                    .add(const EdgeInsets.symmetric(vertical: 24)),
                child: Consumer<ProfessorController>(
                  builder: (_, ctrl, __) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Header(),
                      const SizedBox(height: 24),
                      if (ctrl.error != null) _ErrorCard(ctrl.error!),
                      if (ctrl.isLoading)
                        const Expanded(
                            child: Center(
                                child: CircularProgressIndicator()))
                      else
                        Expanded(child: _CourseList(courses: ctrl.courses)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: AppTheme.cardDecoration(
              gradient: AppTheme.primaryGradient, glowing: true),
          child: const Icon(Icons.school, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Selecionar Disciplina',
                  style: AppTheme.headlineMedium),
              Text('Escolha a disciplina para o quiz',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 14)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.logout, color: AppTheme.textSecondary),
          tooltip: 'Sair',
          onPressed: () async {
            await context.read<AuthController>().logout();
            if (context.mounted) context.go(AppRouter.login);
          },
        ),
      ],
    );
  }
}

class _CourseList extends StatelessWidget {
  final List<MoodleCourse> courses;
  const _CourseList({required this.courses});

  @override
  Widget build(BuildContext context) {
    if (courses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined,
                size: 64, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text('Nenhuma disciplina encontrada',
                style:
                    TextStyle(color: AppTheme.textSecondary, fontSize: 16)),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: courses.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _CourseTile(course: courses[i]),
    );
  }
}

class _CourseTile extends StatelessWidget {
  final MoodleCourse course;
  const _CourseTile({required this.course});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          final user = context.read<AuthController>().user;
          if (user == null) return;
          final router = GoRouter.of(context);
          await context
              .read<ProfessorController>()
              .selectCourse(user, course);
          router.push(AppRouter.professorQuiz);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.cardDecoration(),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    course.shortname.isNotEmpty
                        ? course.shortname[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(course.fullname,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    Text(course.shortname,
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.cardDecoration(color: AppTheme.danger.withValues(alpha: 0.2)),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppTheme.danger, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: AppTheme.danger, fontSize: 13))),
        ],
      ),
    );
  }
}
