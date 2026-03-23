import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/config/app_config.dart';
import '../../domain/entities/moodle_course.dart';
import '../../domain/entities/moodle_quiz.dart';
import '../../domain/entities/question_entity.dart';
import '../../domain/entities/quiz_state_entity.dart';
import '../../domain/entities/score_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_quiz_repository.dart';
import '../../domain/usecases/close_question_usecase.dart';
import '../../domain/usecases/release_question_usecase.dart';

/// Gerencia estado do professor: seleção de curso/quiz + controle do quiz.
class ProfessorController extends ChangeNotifier {
  final IQuizRepository _quizRepo;
  final ReleaseQuestionUseCase _releaseQuestion;
  final CloseQuestionUseCase _closeQuestion;

  // ── Seleção ────────────────────────────────────────────────────────────────
  List<MoodleCourse> _courses = [];
  List<MoodleQuiz> _quizzes = [];
  MoodleCourse? _selectedCourse;
  MoodleQuiz? _selectedQuiz;

  // ── Lista de questões carregadas do Moodle ─────────────────────────────────
  List<QuestionEntity> _questions = [];
  int? _attemptId; // tentativa usada para preview das questões

  // ── Estado do quiz ─────────────────────────────────────────────────────────
  QuizStateEntity _quizState = QuizStateEntity.empty();
  List<ScoreEntity> _scores = [];
  int _selectedDuration = 30;
  bool _isLoading = false;
  String? _error;
  Timer? _pollTimer;

  ProfessorController({
    required IQuizRepository quizRepo,
    required ReleaseQuestionUseCase releaseQuestion,
    required CloseQuestionUseCase closeQuestion,
  })  : _quizRepo = quizRepo,
        _releaseQuestion = releaseQuestion,
        _closeQuestion = closeQuestion;

  // ── Getters ────────────────────────────────────────────────────────────────
  List<MoodleCourse> get courses => _courses;
  List<MoodleQuiz> get quizzes => _quizzes;
  MoodleCourse? get selectedCourse => _selectedCourse;
  MoodleQuiz? get selectedQuiz => _selectedQuiz;
  List<QuestionEntity> get questions => _questions;
  int? get attemptId => _attemptId;
  QuizStateEntity get quizState => _quizState;
  List<ScoreEntity> get scores => _scores;
  int get selectedDuration => _selectedDuration;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isSetup => _selectedQuiz != null && _questions.isNotEmpty;

  // ── Seleção de curso / quiz ────────────────────────────────────────────────

  Future<void> loadCourses(UserEntity user) async {
    _setLoading(true);
    _error = null;
    try {
      _courses = await _quizRepo.getCourses(user);
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> selectCourse(UserEntity user, MoodleCourse course) async {
    _selectedCourse = course;
    _selectedQuiz = null;
    _quizzes = [];
    _questions = [];
    _setLoading(true);
    _error = null;
    try {
      _quizzes = await _quizRepo.getQuizzesByCourse(user, course.id);
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  /// Seleciona o quiz e carrega a lista de questões iniciando uma tentativa.
  Future<void> selectQuiz(UserEntity user, MoodleQuiz quiz) async {
    _selectedQuiz = quiz;
    _questions = [];
    _setLoading(true);
    _error = null;
    try {
      _attemptId = await _quizRepo.startAttempt(user, quiz.id);
      await _loadAllQuestions(user, _attemptId!);
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  // ── Controle do quiz ───────────────────────────────────────────────────────

  void setDuration(int seconds) {
    _selectedDuration = seconds;
    notifyListeners();
  }

  Future<void> releaseQuestion(QuestionEntity q) async {
    if (_selectedQuiz == null) return;
    _setLoading(true);
    _error = null;
    try {
      await _releaseQuestion(
        teacherToken: AppConfig.teacherToken,
        page: q.page,
        duration: _selectedDuration,
        totalPages: _questions.length,
        quizName: _selectedQuiz!.name,
        quizId: _selectedQuiz!.id,
      );
      await _refreshState();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> extendQuestion(int extraSeconds) async {
    final state = quizState;
    if (!state.isActive || state.endsAt == null) return;
    final remaining = state.endsAt!.difference(DateTime.now()).inSeconds;
    final newDuration = (remaining < 0 ? 0 : remaining) + extraSeconds;
    _setLoading(true);
    _error = null;
    try {
      await _releaseQuestion(
        teacherToken: AppConfig.teacherToken,
        page: state.currentPage,
        duration: newDuration,
        totalPages: state.totalPages,
        quizName: state.quizTitle,
        quizId: _selectedQuiz?.id ?? 0,
      );
      await _refreshState();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> stopQuestion() async {
    _setLoading(true);
    _error = null;
    try {
      await _closeQuestion(AppConfig.teacherToken);
      await _refreshState();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> finishQuiz() async {
    _setLoading(true);
    _error = null;
    try {
      await _quizRepo.setFinished(AppConfig.teacherToken);
      await _refreshState();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> resetQuiz() async {
    _setLoading(true);
    try {
      await _quizRepo.resetQuiz(AppConfig.teacherToken);
      _scores = [];
      await _refreshState();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  void startPolling() {
    _pollTimer?.cancel();
    _refreshState();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshState());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ── Privado ────────────────────────────────────────────────────────────────

  Future<void> _loadAllQuestions(UserEntity user, int attemptId) async {
    // Primeiro, determina o total de páginas carregando uma a uma
    final allQuestions = <QuestionEntity>[];
    int page = 0;
    while (true) {
      try {
        final q = await _quizRepo.getQuestion(user, attemptId, page);
        allQuestions.add(q);
        page++;
      } catch (_) {
        break;
      }
    }
    _questions = allQuestions;
    notifyListeners();

    // Depois, carrega novamente com respostas corretas via nova attempt
    if (allQuestions.isNotEmpty) {
      try {
        final newAttemptId = await _quizRepo.startAttempt(user, _selectedQuiz!.id);
        _attemptId = newAttemptId;
        final withAnswers = await _quizRepo.loadQuestionsWithAnswers(
            user, newAttemptId, allQuestions.length);
        if (withAnswers.isNotEmpty) {
          _questions = withAnswers;
          notifyListeners();
        }
      } catch (_) {
        // Se falhar, mantém as questões sem marcação de correto
      }
    }
  }

  Future<void> _refreshState() async {
    try {
      _quizState = await _quizRepo.getQuizState();
      _scores = await _quizRepo.getScores();
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
