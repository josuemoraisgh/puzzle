import '../entities/moodle_course.dart';
import '../entities/moodle_quiz.dart';
import '../entities/question_entity.dart';
import '../entities/quiz_state_entity.dart';
import '../entities/score_entity.dart';
import '../entities/user_entity.dart';

/// I: Interface segregada – operações de quiz (Moodle + GSheets).
abstract class IQuizRepository {
  // ── Moodle: dados ──────────────────────────────────────────────────────────

  Future<List<MoodleCourse>> getCourses(UserEntity user);

  Future<List<MoodleQuiz>> getQuizzesByCourse(UserEntity user, int courseId);

  /// Inicia (ou retoma) tentativa. Retorna attemptId.
  Future<int> startAttempt(UserEntity user, int quizId,
      {void Function(String)? onLog});

  /// Obtém e parseia a questão pelo slot Moodle da tentativa.
  Future<QuestionEntity> getQuestion(UserEntity user, int attemptId, int slot);

  /// Submete resposta ao Moodle e retorna se acertou.
  /// Finaliza a tentativa internamente se o quiz usa "deferred feedback".
  Future<bool> submitPage(UserEntity user, int attemptId,
      QuestionEntity question, String choiceValue);

  /// Finaliza a tentativa do usuário no Moodle.
  Future<void> finishAttempt(UserEntity user, int attemptId);

  /// Carrega todas as questões, finaliza a tentativa e marca as respostas corretas.
  /// [onLog] callback opcional para acompanhar o progresso passo a passo.
  Future<List<QuestionEntity>> loadQuestionsWithAnswers(
      UserEntity user, int attemptId, int totalPages,
      {void Function(String)? onLog});

  // ── Moodle State: estado compartilhado do quiz ────────────────────────────

  Future<QuizStateEntity> getQuizState(UserEntity user, int courseId);

  /// Atualiza no estado compartilhado qual quiz está selecionado no curso.
  Future<void> setSelectedQuiz({
    required UserEntity user,
    required int courseId,
    required int quizId,
    required String quizName,
  });

  Future<void> releaseQuestion({
    required UserEntity user,
    required int courseId,
    required int page,
    required int slot,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  });

  Future<void> closeQuestion(UserEntity user, int courseId);

  /// Estudante registra pontuação com bônus de tempo no mod_data.
  Future<void> submitScore({
    required UserEntity user,
    required int courseId,
    required int score,
    required bool correct,
    required int page,
  });

  Future<List<ScoreEntity>> getScores(UserEntity user, int courseId);

  Future<void> resetQuiz(UserEntity user, int courseId);

  Future<void> setFinished(UserEntity user, int courseId);
}
