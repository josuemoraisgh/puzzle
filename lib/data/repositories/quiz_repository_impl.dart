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
  Future<int> startAttempt(UserEntity user, int quizId) async {
    // 1. Verifica tentativa em progresso antes de criar
    final existingId = await _getUnfinishedAttemptId(user, quizId);
    if (existingId != null) return existingId;

    // 2. Tenta criar nova tentativa
    try {
      return await _moodle.startAttempt(user.baseUrl, user.token, quizId);
    } catch (_) {
      // 3. Se falhar (já existe tentativa não listada), busca novamente
      final retryId = await _getUnfinishedAttemptId(user, quizId);
      if (retryId != null) return retryId;
      // Tenta buscar qualquer tentativa (inclusive recém-finalizada)
      final anyId = await _getUnfinishedAttemptId(user, quizId, status: 'all');
      if (anyId != null) return anyId;
      rethrow;
    }
  }

  Future<int?> _getUnfinishedAttemptId(UserEntity user, int quizId,
      {String status = 'unfinished'}) async {
    try {
      final attempts = await _moodle.getUserAttempts(
          user.baseUrl, user.token, quizId, status: status);
      if (attempts.isNotEmpty) {
        // Prefere tentativas não finalizadas
        final unfinished = attempts.where((a) =>
            a['state']?.toString() == 'inprogress' ||
            a['state']?.toString() == 'overdue').toList();
        final target = unfinished.isNotEmpty ? unfinished.first : attempts.first;
        return (target['id'] as num?)?.toInt();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<QuestionEntity> getQuestion(
      UserEntity user, int attemptId, int page) async {
    final data = await _moodle.getAttemptData(
        user.baseUrl, user.token, attemptId, page);

    final questions = data['questions'] as List? ?? [];
    if (questions.isEmpty) {
      throw Exception('Nenhuma questão encontrada na página $page');
    }

    // Usa a primeira questão da página (compatibilidade com callers existentes)
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

  /// Carrega todas as questões do quiz usando UMA attempt, depois a finaliza
  /// e busca as respostas corretas via revisão. Usa nextpage do Moodle para
  /// navegar corretamente independente de quantas questões há por página.
  @override
  Future<List<QuestionEntity>> loadQuestionsWithAnswers(
      UserEntity user, int attemptId, int totalPages) async {

    // 1. Carrega todas as páginas usando nextpage do Moodle
    final allQuestions = <QuestionEntity>[];
    // Map de slot → page para uso na revisão
    final slotToPage = <int, int>{};
    int page = 0;

    while (page >= 0) {
      try {
        final data = await _moodle.getAttemptData(
            user.baseUrl, user.token, attemptId, page);

        final questions = data['questions'] as List? ?? [];
        for (final q in questions) {
          final qMap = Map<String, dynamic>.from(q as Map);
          final html = qMap['html'] as String? ?? '';
          final slot = (qMap['slot'] as num? ?? 1).toInt();
          final qPage = (qMap['page'] as num? ?? page).toInt();

          final parsed = MoodleHtmlParser.parse(
            html: html,
            attemptId: attemptId,
            slot: slot,
            token: user.token,
            baseUrl: user.baseUrl,
          );

          allQuestions.add(QuestionEntity(
            slot: parsed.slot,
            page: qPage,
            text: parsed.text,
            choices: parsed.choices,
            imageUrls: parsed.imageUrls,
            inputBaseName: parsed.inputBaseName,
            seqCheck: parsed.seqCheck,
            type: parsed.type,
          ));
          slotToPage[slot] = qPage;
        }

        // nextpage == -1 significa última página
        final nextPage = (data['nextpage'] as num? ?? -1).toInt();
        page = nextPage;
      } catch (_) {
        break;
      }
    }

    if (allQuestions.isEmpty) return allQuestions;

    // 2. Finaliza a attempt para liberar revisão
    try {
      await _moodle.finishAttempt(user.baseUrl, user.token, attemptId);
    } catch (_) {
      return allQuestions;
    }

    // 3. Busca revisão e marca isCorrect — agrupa por página
    final reviewPages = slotToPage.values.toSet();
    final reviewHtmlBySlot = <int, String>{};

    for (final reviewPage in reviewPages) {
      try {
        final review = await _moodle.getAttemptReview(
            user.baseUrl, user.token, attemptId, reviewPage);
        for (final rq in (review['questions'] as List? ?? [])) {
          final rqMap = rq as Map;
          final slot = (rqMap['slot'] as num?)?.toInt();
          final html = rqMap['html'] as String? ?? '';
          if (slot != null && html.isNotEmpty) {
            reviewHtmlBySlot[slot] = html;
          }
        }
      } catch (_) {}
    }

    final result = <QuestionEntity>[];
    for (final q in allQuestions) {
      // Filtra questões sem alternativas (dissertativas/abertas)
      if (q.choices.isEmpty) continue;

      final reviewHtml = reviewHtmlBySlot[q.slot] ?? '';
      if (reviewHtml.isEmpty) {
        result.add(q);
        continue;
      }
      final correctValues = MoodleHtmlParser.parseCorrectValues(reviewHtml);
      final newChoices = q.choices.map((c) => ParsedChoice(
        value: c.value,
        text: c.text,
        isCorrect: correctValues.contains(c.value),
      )).toList();
      result.add(QuestionEntity(
        slot: q.slot,
        page: q.page,
        text: q.text,
        choices: newChoices,
        imageUrls: q.imageUrls,
        inputBaseName: q.inputBaseName,
        seqCheck: q.seqCheck,
        type: q.type,
      ));
    }
    return result;
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
