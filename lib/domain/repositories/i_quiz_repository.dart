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
  Future<int> startAttempt(UserEntity user, int quizId);

  /// Obtém e parseia a questão de uma página da tentativa.
  Future<QuestionEntity> getQuestion(
      UserEntity user, int attemptId, int page);

  /// Submete resposta ao Moodle e retorna se acertou.
  Future<bool> submitPage(
      UserEntity user, int attemptId, QuestionEntity question, String choiceValue);

  /// Finaliza a tentativa do usuário no Moodle.
  Future<void> finishAttempt(UserEntity user, int attemptId);

  /// Carrega todas as questões, finaliza a tentativa e marca as respostas corretas.
  /// [onLog] callback opcional para acompanhar o progresso passo a passo.
  Future<List<QuestionEntity>> loadQuestionsWithAnswers(
      UserEntity user, int attemptId, int totalPages,
      {void Function(String)? onLog});

  // ── GSheets: estado compartilhado ─────────────────────────────────────────

  Future<QuizStateEntity> getQuizState();

  Future<void> releaseQuestion({
    required String teacherToken,
    required int page,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  });

  Future<void> closeQuestion(String teacherToken);

  /// Estudante reporta pontuação ao GSheets após feedback do Moodle.
  Future<void> submitScore({
    required UserEntity user,
    required int score,
    required bool correct,
    required int page,
  });

  Future<List<ScoreEntity>> getScores();

  Future<void> resetQuiz(String teacherToken);

  Future<void> setFinished(String teacherToken);
}
