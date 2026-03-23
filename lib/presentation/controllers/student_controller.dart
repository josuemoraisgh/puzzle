import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/entities/question_entity.dart';
import '../../domain/entities/quiz_state_entity.dart';
import '../../domain/entities/score_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_quiz_repository.dart';
import '../../domain/usecases/submit_answer_usecase.dart';

/// Gerencia estado do estudante: tentativa Moodle + polling GSheets.
class StudentController extends ChangeNotifier {
  final IQuizRepository _quizRepo;
  final SubmitAnswerUseCase _submitAnswer;

  // ── Tentativa Moodle ───────────────────────────────────────────────────────
  int? _attemptId;
  int? _currentQuizId;
  QuestionEntity? _currentQuestion;

  // ── Estado do quiz ─────────────────────────────────────────────────────────
  QuizStateEntity _quizState = QuizStateEntity.empty();
  List<ScoreEntity> _scores = [];
  String? _selectedChoice;   // valor Moodle da alternativa ("0", "1", …)
  bool _hasAnswered = false;
  bool _isSubmitting = false;
  bool _lastAnswerCorrect = false;
  bool _isLoadingQuestion = false;
  String? _error;
  Timer? _pollTimer;
  int _lastSeenPage = -1;
  bool _autoSubmitted = false;

  StudentController({
    required IQuizRepository quizRepo,
    required SubmitAnswerUseCase submitAnswer,
  })  : _quizRepo = quizRepo,
        _submitAnswer = submitAnswer;

  // ── Getters ────────────────────────────────────────────────────────────────
  int? get attemptId => _attemptId;
  QuizStateEntity get quizState => _quizState;
  QuestionEntity? get currentQuestion => _currentQuestion;
  List<ScoreEntity> get scores => _scores;
  String? get selectedChoice => _selectedChoice;

  /// Pontuação do próprio aluno (null se ainda não pontuou).
  ScoreEntity? myScore(String userId) {
    try {
      return _scores.firstWhere((s) => s.studentId == userId);
    } catch (_) {
      return null;
    }
  }
  bool get hasAnswered => _hasAnswered;
  bool get isSubmitting => _isSubmitting;
  bool get lastAnswerCorrect => _lastAnswerCorrect;
  bool get isLoadingQuestion => _isLoadingQuestion;
  String? get error => _error;

  // ── Ciclo de tentativa ─────────────────────────────────────────────────────

  /// Inicia tentativa no Moodle assim que o estudante confirma entrar no quiz.
  Future<void> ensureAttempt(UserEntity user, int quizId) async {
    if (_attemptId != null && _currentQuizId == quizId) return;
    try {
      _attemptId = await _quizRepo.startAttempt(user, quizId);
      _currentQuizId = quizId;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> finishAttempt(UserEntity user) async {
    final id = _attemptId;
    if (id == null) return;
    try {
      await _quizRepo.finishAttempt(user, id);
      _attemptId = null;
      _currentQuizId = null;
      _currentQuestion = null;
    } catch (_) {}
  }

  // ── Resposta ───────────────────────────────────────────────────────────────

  void selectChoice(String choiceValue) {
    if (_hasAnswered || !_quizState.isActive) return;
    _selectedChoice = choiceValue;
    notifyListeners();
  }

  Future<void> submitAnswer(UserEntity user) async {
    final choice = _selectedChoice;
    final q = _currentQuestion;
    final id = _attemptId;
    if (choice == null || q == null || id == null || _hasAnswered) return;

    _isSubmitting = true;
    notifyListeners();
    try {
      // Calcula pontuação: 1000 + tempo_restante × 10
      final bonus = _quizState.secondsRemaining * 10;
      final baseScore = 1000 + bonus;

      _lastAnswerCorrect = await _submitAnswer(
        user: user,
        attemptId: id,
        question: q,
        choiceValue: choice,
        baseScore: baseScore,
      );
      _hasAnswered = true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  void startPolling(UserEntity user) {
    _pollTimer?.cancel();
    _refreshState(user);
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshState(user));
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ── Privado ────────────────────────────────────────────────────────────────

  Future<void> _refreshState(UserEntity user) async {
    try {
      final newState = await _quizRepo.getQuizState();

      // Nova questão liberada
      if (newState.isActive && newState.currentPage != _lastSeenPage) {
        _lastSeenPage = newState.currentPage;
        _selectedChoice = null;
        _hasAnswered = false;
        _lastAnswerCorrect = false;
        _autoSubmitted = false;
        _currentQuestion = null;

        // Garante que a tentativa existe
        if (newState.quizId > 0) {
          await ensureAttempt(user, newState.quizId);
        }

        // Busca a questão desta página
        final id = _attemptId;
        if (id != null) {
          _isLoadingQuestion = true;
          notifyListeners();
          try {
            _currentQuestion =
                await _quizRepo.getQuestion(user, id, newState.currentPage);
          } catch (e) {
            _error = e.toString();
          } finally {
            _isLoadingQuestion = false;
          }
        }
      }

      // Questão fechada: auto-submit se selecionou mas não enviou
      if (newState.isClosed &&
          !_hasAnswered &&
          !_autoSubmitted &&
          _selectedChoice != null) {
        _autoSubmitted = true;
        await submitAnswer(user);
      }

      // Fim do quiz: finaliza tentativa
      if (newState.isFinished && _attemptId != null) {
        await finishAttempt(user);
      }

      _quizState = newState;
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

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
