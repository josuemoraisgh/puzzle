import '../../core/utils/moodle_html_parser.dart';
import '../../domain/entities/moodle_course.dart';
import '../../domain/entities/moodle_quiz.dart';
import '../../domain/entities/question_entity.dart';
import '../../domain/entities/quiz_state_entity.dart';
import '../../domain/entities/score_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_quiz_repository.dart';
import '../datasources/gsheet_datasource.dart';
import '../datasources/moodle_datasource.dart';
import '../models/quiz_state_model.dart';
import '../models/score_model.dart';

/// L: Substitui IQuizRepository; D: depende de interfaces, não concretos.
class QuizRepositoryImpl implements IQuizRepository {
  final IGSheetDatasource _gsheet;
  final IMoodleDatasource _moodle;

  Map<String, int> _prevRanks = {};

  QuizRepositoryImpl(this._gsheet, this._moodle);

  // ── Moodle ─────────────────────────────────────────────────────────────────

  @override
  Future<List<MoodleCourse>> getCourses(UserEntity user) async {
    final list = await _moodle.getCourses(user.baseUrl, user.token, user.id);
    return list.map(MoodleCourse.fromJson).toList();
  }

  @override
  Future<List<MoodleQuiz>> getQuizzesByCourse(
      UserEntity user, int courseId) async {
    final list = await _moodle.getQuizzesByCourse(
        user.baseUrl, user.token, courseId);
    return list.map(MoodleQuiz.fromJson).toList();
  }

  @override
  Future<int> startAttempt(UserEntity user, int quizId) =>
      _moodle.startAttempt(user.baseUrl, user.token, quizId);

  @override
  Future<QuestionEntity> getQuestion(
      UserEntity user, int attemptId, int page) async {
    final data = await _moodle.getAttemptData(
        user.baseUrl, user.token, attemptId, page);

    final questions = data['questions'] as List? ?? [];
    if (questions.isEmpty) {
      throw Exception('Nenhuma questão encontrada na página $page');
    }

    final qMap = Map<String, dynamic>.from(questions.first as Map);
    final html = qMap['html'] as String? ?? '';
    final slot = (qMap['slot'] as num? ?? 1).toInt();

    final parsed = MoodleHtmlParser.parse(
      html: html,
      attemptId: attemptId,
      slot: slot,
      token: user.token,
      baseUrl: user.baseUrl,
    );

    return QuestionEntity(
      slot: parsed.slot,
      page: page,
      text: parsed.text,
      choices: parsed.choices,
      imageUrls: parsed.imageUrls,
      inputBaseName: parsed.inputBaseName,
      seqCheck: parsed.seqCheck,
      type: parsed.type,
    );
  }

  @override
  Future<List<QuestionEntity>> loadQuestionsWithAnswers(
      UserEntity user, int attemptId, int totalPages) async {
    // 1. Carrega todas as questões
    final allQuestions = <QuestionEntity>[];
    for (int page = 0; page < totalPages; page++) {
      try {
        final q = await getQuestion(user, attemptId, page);
        allQuestions.add(q);
      } catch (_) {
        break;
      }
    }

    // 2. Finaliza a tentativa para liberar o acesso à revisão
    try {
      await _moodle.finishAttempt(user.baseUrl, user.token, attemptId);
    } catch (_) {
      // Se não conseguir finalizar, retorna as questões sem marcação
      return allQuestions;
    }

    // 3. Para cada página, busca a revisão e marca isCorrect nas choices
    final enriched = <QuestionEntity>[];
    for (final q in allQuestions) {
      try {
        final review = await _moodle.getAttemptReview(
            user.baseUrl, user.token, attemptId, q.page);
        final questions = review['questions'] as List? ?? [];
        String reviewHtml = '';
        for (final rq in questions) {
          final rqMap = rq as Map;
          if ((rqMap['slot'] as num?)?.toInt() == q.slot) {
            reviewHtml = rqMap['html'] as String? ?? '';
            break;
          }
        }

        if (reviewHtml.isNotEmpty) {
          final correctValues = MoodleHtmlParser.parseCorrectValues(reviewHtml);
          final newChoices = q.choices.map((c) => ParsedChoice(
            value: c.value,
            text: c.text,
            isCorrect: correctValues.contains(c.value),
          )).toList();
          enriched.add(QuestionEntity(
            slot: q.slot,
            page: q.page,
            text: q.text,
            choices: newChoices,
            imageUrls: q.imageUrls,
            inputBaseName: q.inputBaseName,
            seqCheck: q.seqCheck,
            type: q.type,
          ));
        } else {
          enriched.add(q);
        }
      } catch (_) {
        enriched.add(q);
      }
    }

    return enriched;
  }

  @override
  Future<bool> submitPage(UserEntity user, int attemptId,
      QuestionEntity question, String choiceValue) async {
    final answerData = {
      question.inputBaseName: choiceValue,
      '${question.inputBaseName.replaceFirst('_answer', ':sequencecheck')}':
          question.seqCheck,
    };

    final result = await _moodle.processAttempt(
        user.baseUrl, user.token, attemptId, answerData);

    // Moodle retorna o estado mas o feedback de "correto/errado" está na
    // revisão da tentativa. Usamos mod_quiz_get_attempt_review para verificar.
    // Por ora, checamos via get_attempt_data re-fetching.
    return await _checkAnswerCorrect(
        user, attemptId, question.slot, choiceValue, result);
  }

  @override
  Future<void> finishAttempt(UserEntity user, int attemptId) =>
      _moodle.finishAttempt(user.baseUrl, user.token, attemptId);

  // ── GSheets ────────────────────────────────────────────────────────────────

  @override
  Future<QuizStateEntity> getQuizState() async {
    final data = await _gsheet.getState();
    return QuizStateModel.fromJson(data);
  }

  @override
  Future<void> releaseQuestion({
    required String teacherToken,
    required int page,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  }) =>
      _gsheet.releaseQuestion(
        token: teacherToken,
        page: page,
        duration: duration,
        totalPages: totalPages,
        quizName: quizName,
        quizId: quizId,
      );

  @override
  Future<void> closeQuestion(String teacherToken) =>
      _gsheet.closeQuestion(teacherToken);

  @override
  Future<void> submitScore({
    required UserEntity user,
    required int score,
    required bool correct,
    required int page,
  }) =>
      _gsheet.submitScore(
        token: user.token,
        studentId: user.id.toString(),
        studentName: user.fullname,
        score: score,
        correct: correct,
        page: page,
      );

  @override
  Future<List<ScoreEntity>> getScores() async {
    final list = await _gsheet.getScores();
    final result = list.map((j) {
      final id = j['student_id']?.toString() ?? '';
      return ScoreModel.fromJson(j, previousRank: _prevRanks[id]);
    }).toList();
    _prevRanks = {for (final s in result) s.studentId: s.rank};
    return result;
  }

  @override
  Future<void> resetQuiz(String teacherToken) async {
    await _gsheet.resetQuiz(teacherToken);
    _prevRanks = {};
  }

  @override
  Future<void> setFinished(String teacherToken) =>
      _gsheet.setFinished(teacherToken);

  // ── Privado ────────────────────────────────────────────────────────────────

  /// Verifica se a resposta submetida foi correta consultando o Moodle.
  /// O Moodle com comportamento "immediate feedback" inclui a marcação
  /// correct/incorrect na resposta retornada após process_attempt.
  Future<bool> _checkAnswerCorrect(UserEntity user, int attemptId, int slot,
      String choiceValue, Map<String, dynamic> processResult) async {
    try {
      // Tenta extrair o feedback de gradedright/gradedwrong do HTML retornado
      final state = processResult['state']?.toString() ?? '';
      if (state == 'complete' || state == 'gradedright') return true;
      if (state == 'gradedwrong' || state == 'gradedpartial') return false;

      // Fallback: re-fetch a página para verificar marcação de correto
      // (funciona quando o quiz usa "immediate feedback")
      final page = (slot - 1); // aproximação slot→page
      final data = await _moodle.getAttemptData(
          user.baseUrl, user.token, attemptId, page);
      final questions = data['questions'] as List? ?? [];
      for (final q in questions) {
        final qMap = q as Map;
        if ((qMap['slot'] as num?)?.toInt() == slot) {
          final html = qMap['html'] as String? ?? '';
          if (html.contains('correct') && !html.contains('incorrect')) {
            return true;
          }
          return false;
        }
      }
    } catch (_) {}
    return false;
  }
}
