import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/utils/debug_logger.dart';
import '../../domain/entities/moodle_course.dart';
import '../../domain/entities/question_entity.dart';
import '../../domain/entities/quiz_state_entity.dart';
import '../../domain/entities/score_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_quiz_repository.dart';

/// Gerencia estado do estudante: seleÃ§Ã£o de disciplina + tentativa Moodle + polling.
class StudentController extends ChangeNotifier {
  final IQuizRepository _quizRepo;

  // â”€â”€ SeleÃ§Ã£o de disciplina â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<MoodleCourse> _courses = [];
  int? _selectedCourseId;
  bool _isLoadingCourses = false;
  // null = nÃ£o verificado | false = sem mq_state | true = tem mq_state
  bool? _hasActivity;

  // â”€â”€ Tentativa Moodle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  int? _attemptId;
  int? _currentQuizId;
  QuestionEntity? _currentQuestion;

  // â”€â”€ Estado do quiz â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  QuizStateEntity _quizState = QuizStateEntity.empty();
  List<ScoreEntity> _scores = [];
  String? _selectedChoice;
  String? _selectedChoiceText; // texto legível capturado no momento da seleção
  bool _hasAnswered = false;
  bool _isSubmitting = false;
  bool _lastAnswerCorrect = false;
  bool _isLoadingQuestion = false;
  String? _error;
  String? _attemptError; // erro ao criar tentativa (não bloqueia polling)
  Timer? _pollTimer;
  int _lastSeenSlot = 0;
  bool _autoSubmitted = false;
  bool _isRefreshingState = false; // guarda contra polls sobrepostos

  StudentController({
    required IQuizRepository quizRepo,
  }) : _quizRepo = quizRepo;

  // â”€â”€ Getters â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<MoodleCourse> get courses => _courses;
  int? get selectedCourseId => _selectedCourseId;
  bool get isLoadingCourses => _isLoadingCourses;

  /// null = verificando | false = sem mq_state | true = tem
  bool? get hasActivity => _hasActivity;
  int? get attemptId => _attemptId;
  QuizStateEntity get quizState => _quizState;
  QuestionEntity? get currentQuestion => _currentQuestion;
  List<ScoreEntity> get scores => _scores;
  String? get selectedChoice => _selectedChoice;
  String? get selectedChoiceText => _selectedChoiceText;
  bool get hasAnswered => _hasAnswered;
  bool get isSubmitting => _isSubmitting;
  bool get lastAnswerCorrect => _lastAnswerCorrect;
  bool get isLoadingQuestion => _isLoadingQuestion;
  String? get error => _error;
  String? get attemptError => _attemptError;

  ScoreEntity? myScore(String userId) {
    try {
      return _scores.firstWhere((s) => s.studentId == userId);
    } catch (_) {
      return null;
    }
  }

  // â”€â”€ SeleÃ§Ã£o de disciplina â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> loadCourses(UserEntity user) async {
    _isLoadingCourses = true;
    _error = null;
    notifyListeners();
    try {
      _courses = await _quizRepo.getCourses(user);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoadingCourses = false;
      notifyListeners();
    }
  }

  /// Define o curso cujo mq_state serÃ¡ monitorado.
  /// Verifica se a atividade existe antes de iniciar o polling.
  void selectCourse(UserEntity user, int courseId) {
    stopPolling();
    _selectedCourseId = courseId;
    _hasActivity = null; // verificando
    _lastSeenSlot = 0;
    _quizState = QuizStateEntity.empty();
    _currentQuestion = null;
    _scores = [];
    _error = null;
    _attemptError = null;
    _selectedChoiceText = null;
    notifyListeners();
    _checkAndStartPolling(user);
  }

  Future<void> _checkAndStartPolling(UserEntity user) async {
    final courseId = _selectedCourseId;
    if (courseId == null) return;
    try {
      // Uma chamada de teste â€” se lanÃ§ar "mq_state nÃ£o encontrada" â†’ sem atividade
      await _quizRepo.getQuizState(user, courseId);
      _hasActivity = true;
      notifyListeners();
      startPolling(user);
    } catch (e) {
      final msg = e.toString();
      // Mensagem especÃ­fica do MoodleStateDatasource quando nÃ£o acha o Database
      if (msg.contains('mq_state') || msg.contains('nÃ£o encontrada')) {
        _hasActivity = false;
      } else {
        _hasActivity = null;
        _error = msg;
      }
      notifyListeners();
    }
  }

  // â”€â”€ Ciclo de tentativa â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> ensureAttempt(UserEntity user, int quizId) async {
    if (_attemptId != null && _currentQuizId == quizId) return;
    try {
      _attemptId = await _quizRepo.startAttempt(user, quizId);
      _currentQuizId = quizId;
      _attemptError = null; // sucesso — limpa aviso anterior
    } catch (e) {
      // Não bloqueia o polling, mas avisa o aluno sobre o problema.
      _attemptError = e.toString();
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

  // â”€â”€ Resposta â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void selectChoice(String choiceValue) {
    if (_hasAnswered || !_quizState.isActive) return;
    _selectedChoice = choiceValue;
    // Captura o texto legível agora, enquanto _currentQuestion está disponível
    try {
      _selectedChoiceText = _currentQuestion?.choices
          .firstWhere((c) => c.value == choiceValue)
          .text;
    } catch (_) {
      _selectedChoiceText = null;
    }
    notifyListeners();
  }

  Future<void> submitAnswer(UserEntity user) async {
    final dlog = DebugLogger.instance;
    final choice = _selectedChoice;
    final q = _currentQuestion;
    final id = _attemptId;
    final courseId = _selectedCourseId;
    if (choice == null ||
        q == null ||
        id == null ||
        _hasAnswered ||
        _isSubmitting ||
        courseId == null) {
      dlog.log('STUDENT', 'submitAnswer cancelado — pré-condição falhou',
          data: {
            'choice': choice,
            'question': q != null ? 'slot=${q.slot}' : 'null',
            'attemptId': id,
            'hasAnswered': _hasAnswered,
            'isSubmitting': _isSubmitting,
            'courseId': courseId,
          });
      return;
    }

    _isSubmitting = true;
    notifyListeners();
    try {
      final bonus = _quizState.secondsRemaining * 10;
      final baseScore = 1000 + bonus;

      dlog.separator('STUDENT SUBMIT');
      dlog.log('STUDENT', 'Submetendo resposta', data: {
        'attemptId': id,
        'slot': q.slot,
        'page': q.page,
        'choiceValue': choice,
        'choiceText': _selectedChoiceText ?? '?',
        'timeBonus': bonus,
        'baseScore': baseScore,
        'inputBaseName': q.inputBaseName,
        'seqCheck': q.seqCheck,
      });

      // Moodle é a única fonte de verdade.
      final correct = await _quizRepo.submitPage(user, id, q, choice);

      dlog.log(
          'STUDENT', '★ Resultado: ${correct ? "CORRETO ✓" : "INCORRETO ✗"}',
          data: {
            'score_a_registrar': correct ? baseScore : 0,
          });

      // Registra pontuação no leaderboard
      await _quizRepo.submitScore(
        user: user,
        courseId: courseId,
        score: correct ? baseScore : 0,
        correct: correct,
        page: q.page,
      );

      _lastAnswerCorrect = correct;
      _hasAnswered = true;
    } catch (e) {
      dlog.log('STUDENT', '✗ ERRO ao submeter: $e');
      _error = e.toString();
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  // â”€â”€ Polling â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void startPolling(UserEntity user) {
    _pollTimer?.cancel();
    _refreshState(user);
    _pollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshState(user));
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // â”€â”€ Privado â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _refreshState(UserEntity user) async {
    final courseId = _selectedCourseId;
    if (courseId == null) return;
    if (_isRefreshingState) return;
    _isRefreshingState = true;
    final dlog = DebugLogger.instance;
    try {
      final newState = await _quizRepo.getQuizState(user, courseId);
      dlog.log('STUDENT_POLL', 'estado lido', data: {
        'status': newState.status.name,
        'slot': newState.currentSlot,
        'page': newState.currentPage,
        'quizId': newState.quizId,
        'lastSeenSlot': _lastSeenSlot,
        'attemptId': _attemptId,
        'hasQuestion': _currentQuestion != null,
      });

      // Atualiza _quizState ANTES de qualquer notifyListeners() intermediário
      // para evitar que a UI continue exibindo o estado anterior enquanto a
      // questão está sendo carregada.
      _quizState = newState;

      // Detecta reset do quiz (voltou ao estado 'waiting' após uma rodada)
      if (newState.isWaiting && _lastSeenSlot > 0) {
        dlog.log('STUDENT_POLL', 'reset detectado (voltou para waiting)');
        _lastSeenSlot = 0;
        _selectedChoice = null;
        _selectedChoiceText = null;
        _hasAnswered = false;
        _lastAnswerCorrect = false;
        _autoSubmitted = false;
        _currentQuestion = null;
        _attemptId = null;
        _currentQuizId = null;
        _attemptError = null;
        _scores = [];
      }

      if (newState.isActive && newState.currentSlot != _lastSeenSlot) {
        dlog.log('STUDENT_POLL', '★ NOVA QUESTÃO LIBERADA', data: {
          'slot': newState.currentSlot,
          'quizId': newState.quizId,
        });
        // Marca o slot imediatamente para evitar re-entradas no próximo poll
        _lastSeenSlot = newState.currentSlot;
        _selectedChoice = null;
        _selectedChoiceText = null;
        _hasAnswered = false;
        _lastAnswerCorrect = false;
        _autoSubmitted = false;
        _currentQuestion = null;

        if (newState.quizId > 0) {
          await ensureAttempt(user, newState.quizId);
          dlog.log('STUDENT_POLL', 'ensureAttempt resultado', data: {
            'attemptId': _attemptId,
            'attemptError': _attemptError,
          });
        }

        final id = _attemptId;
        if (id != null && newState.currentSlot > 0) {
          _isLoadingQuestion = true;
          notifyListeners();
          try {
            _currentQuestion =
                await _quizRepo.getQuestion(user, id, newState.currentSlot);
            _error = null;
            dlog.log('STUDENT_POLL', '✓ questão carregada', data: {
              'slot': _currentQuestion?.slot,
            });
          } catch (e) {
            _error = e.toString();
            dlog.log('STUDENT_POLL', '✗ ERRO ao carregar questão: $e');
          } finally {
            _isLoadingQuestion = false;
          }
        } else {
          dlog.log('STUDENT_POLL',
              'sem attemptId válido — questão não será carregada neste ciclo');
        }
      }

      // Retry: se a questão não foi carregada no ciclo anterior (attempt ou
      // getQuestion falharam), tenta novamente sem resetar o estado do aluno.
      if (newState.isActive &&
          newState.currentSlot == _lastSeenSlot &&
          _currentQuestion == null &&
          !_isLoadingQuestion) {
        dlog.log('STUDENT_POLL', 'retry: questão ainda não carregada');
        if (_attemptId == null && newState.quizId > 0) {
          await ensureAttempt(user, newState.quizId);
        }
        final id = _attemptId;
        if (id != null && newState.currentSlot > 0) {
          _isLoadingQuestion = true;
          notifyListeners();
          try {
            _currentQuestion =
                await _quizRepo.getQuestion(user, id, newState.currentSlot);
            _error = null;
            dlog.log('STUDENT_POLL', '✓ retry: questão carregada');
          } catch (e) {
            _error = e.toString();
            dlog.log('STUDENT_POLL', '✗ retry ERRO: $e');
          } finally {
            _isLoadingQuestion = false;
          }
        }
      }

      if (newState.isClosed &&
          !_hasAnswered &&
          !_isSubmitting &&
          !_autoSubmitted &&
          _selectedChoice != null) {
        _autoSubmitted = true;
        await submitAnswer(user);
      }

      if (newState.isFinished && _attemptId != null) {
        await finishAttempt(user);
      }

      // getScores em try isolado: falha aqui não pode ocultar a questão.
      try {
        _scores = await _quizRepo.getScores(user, courseId);
      } catch (e) {
        dlog.log('STUDENT_POLL', 'getScores falhou: $e');
      }
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      dlog.log('STUDENT_POLL', '✗ ERRO no polling: $e');
      notifyListeners();
    } finally {
      _isRefreshingState = false;
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
