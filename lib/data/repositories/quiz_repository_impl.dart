import 'dart:convert';

import '../../core/utils/debug_logger.dart';
import '../../core/utils/moodle_html_parser.dart';
import '../../domain/entities/moodle_course.dart';
import '../../domain/entities/moodle_quiz.dart';
import '../../domain/entities/question_entity.dart';
import '../../domain/entities/quiz_state_entity.dart';
import '../../domain/entities/score_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/i_quiz_repository.dart';
import '../datasources/moodle_datasource.dart';
import '../datasources/moodle_state_datasource.dart';
import '../models/quiz_state_model.dart';
import '../models/score_model.dart';

/// L: Substitui IQuizRepository; D: depende de interfaces, não concretos.
class QuizRepositoryImpl implements IQuizRepository {
  final IStateDatasource _state;
  final IMoodleDatasource _moodle;

  Map<String, int> _prevRanks = {};

  QuizRepositoryImpl(this._state, this._moodle);

  // ── Moodle ─────────────────────────────────────────────────────────────────

  @override
  Future<List<MoodleCourse>> getCourses(UserEntity user) async {
    final list = await _moodle.getCourses(user.baseUrl, user.token, user.id);
    return list.map(MoodleCourse.fromJson).toList();
  }

  @override
  Future<List<MoodleQuiz>> getQuizzesByCourse(
      UserEntity user, int courseId) async {
    final list =
        await _moodle.getQuizzesByCourse(user.baseUrl, user.token, courseId);
    return list.map(MoodleQuiz.fromJson).toList();
  }

  @override
  Future<int> startAttempt(UserEntity user, int quizId,
      {void Function(String)? onLog}) async {
    void log(String m) => onLog?.call(m);

    // 1. Busca tentativa em andamento antes de criar
    log('Verificando tentativas existentes (status=unfinished)…');
    final existingId =
        await _getUnfinishedAttemptId(user, quizId, onLog: onLog);
    if (existingId != null) {
      log('Tentativa existente reutilizada: ID $existingId');
      return existingId;
    }

    // 2. Tenta criar nova tentativa
    log('Nenhuma encontrada — criando nova tentativa…');
    try {
      final id = await _moodle.startAttempt(user.baseUrl, user.token, quizId);
      log('Nova tentativa criada: ID $id');
      return id;
    } on MoodleException catch (e) {
      log('Moodle recusou [${e.errorCode ?? '?'}]: ${e.message}');

      // "quizalreadystarted": já existe tentativa aberta não listada antes
      final retryId = await _getUnfinishedAttemptId(user, quizId, onLog: onLog);
      if (retryId != null) {
        log('Tentativa encontrada na segunda busca: ID $retryId');
        return retryId;
      }
      log('Tentando status=all como último recurso…');
      final anyId = await _getUnfinishedAttemptId(user, quizId,
          status: 'all', onLog: onLog);
      if (anyId != null) {
        log('Tentativa encontrada (all): ID $anyId');
        return anyId;
      }

      // Verifica se há tentativa de preview bloqueando
      log('Verificando tentativas de pré-visualização…');
      final previewAttempts = await _moodle.getUserAttempts(
          user.baseUrl, user.token, quizId,
          status: 'all', userId: user.id, includePreviews: true);
      final previews = previewAttempts
          .where((a) =>
              (a['preview'] == 1 || a['preview'] == true) &&
              (a['state']?.toString() == 'inprogress' ||
                  a['state']?.toString() == 'overdue'))
          .toList();
      log('Previews em andamento: ${previews.length}');

      if (previews.isNotEmpty) {
        // Estratégia 1: forcenew=1 — o Moodle deleta previews internamente
        log('Tentando startAttempt com forcenew=1 (deleta previews automaticamente)…');
        try {
          final freshId = await _moodle
              .startAttempt(user.baseUrl, user.token, quizId, forcenew: true);
          log('Nova tentativa criada com forcenew: ID $freshId');
          return freshId;
        } catch (forceErr) {
          log('forcenew falhou [${forceErr is MoodleException ? forceErr.errorCode ?? "?" : "?"}]: $forceErr');
        }

        // Estratégia 2: deletar preview via API
        for (final preview in previews) {
          final pid = (preview['id'] as num?)?.toInt() ?? 0;
          log('Tentando deletar preview ID $pid…');
          try {
            await _moodle.deleteAttempt(user.baseUrl, user.token, pid);
            log('Preview $pid deletado — criando nova tentativa…');
            final freshId =
                await _moodle.startAttempt(user.baseUrl, user.token, quizId);
            log('Nova tentativa criada: ID $freshId');
            return freshId;
          } catch (deleteErr) {
            log('deleteAttempt($pid) falhou [${deleteErr is MoodleException ? deleteErr.errorCode ?? "?" : "?"}]: $deleteErr');
          }
        }

        // Estratégia 3: finalizar preview com timeup
        for (final preview in previews) {
          final pid = (preview['id'] as num?)?.toInt() ?? 0;
          log('Tentando finalizar preview ID $pid com timeup…');
          try {
            await _moodle.finishAttempt(user.baseUrl, user.token, pid,
                timeup: true);
            log('Preview $pid finalizado — criando nova tentativa…');
            final freshId =
                await _moodle.startAttempt(user.baseUrl, user.token, quizId);
            log('Nova tentativa criada: ID $freshId');
            return freshId;
          } catch (finishErr) {
            log('finishAttempt($pid) falhou [${finishErr is MoodleException ? finishErr.errorCode ?? "?" : "?"}]: $finishErr');
          }
        }

        throw MoodleException(
          'Existe uma tentativa de pré-visualização bloqueando o quiz (ID: ${previews.map((p) => p["id"]).join(", ")}). '
          'Acesse Moodle → Quiz → Resultados → Tentativas e delete a tentativa de pré-visualização, depois clique em Reiniciar Quiz.',
          errorCode: 'previewblocking',
        );
      }
      rethrow;
    }
  }

  Future<int?> _getUnfinishedAttemptId(UserEntity user, int quizId,
      {String status = 'unfinished',
      bool includePreviews = false,
      void Function(String)? onLog}) async {
    void log(String m) => onLog?.call(m);
    try {
      final attempts = await _moodle.getUserAttempts(
          user.baseUrl, user.token, quizId,
          status: status, userId: user.id, includePreviews: includePreviews);
      log('  getUserAttempts($status): ${attempts.length} resultado(s)');
      for (final a in attempts) {
        log('    id=${a['id']} state=${a['state']}');
      }
      if (attempts.isNotEmpty) {
        final inprogress = attempts
            .where((a) =>
                a['state']?.toString() == 'inprogress' ||
                a['state']?.toString() == 'overdue')
            .toList();
        // Nunca retorna tentativa finalizada — apenas inprogress/overdue
        if (inprogress.isEmpty) return null;
        return (inprogress.first['id'] as num?)?.toInt();
      }
    } catch (e) {
      log('  getUserAttempts($status) ERRO: $e');
    }
    return null;
  }

  @override
  Future<QuestionEntity> getQuestion(
      UserEntity user, int attemptId, int slot) async {
    final dlog = DebugLogger.instance;
    dlog.separator('GET QUESTION');
    dlog.log('QUESTION', 'Buscando questão slot=$slot attemptId=$attemptId');

    // Tenta page=0 primeiro (cobre quizzes com todas as questões na mesma página)
    Map<String, dynamic>? qMap = await _findQuestionBySlot(
        user.baseUrl, user.token, attemptId, slot,
        moodlePage: 0);

    // Fallback: quiz com 1 questão por página (slot N está na página N-1)
    if (qMap == null && slot > 1) {
      dlog.log(
          'QUESTION', 'Não encontrada na page=0, tentando page=${slot - 1}');
      qMap = await _findQuestionBySlot(
          user.baseUrl, user.token, attemptId, slot,
          moodlePage: slot - 1);
    }

    if (qMap == null) {
      dlog.log('QUESTION', '✗ Questão slot=$slot NÃO encontrada');
      throw Exception(
          'Questão com slot $slot não encontrada na tentativa $attemptId');
    }

    final html = qMap['html'] as String? ?? '';
    final actualSlot = (qMap['slot'] as num? ?? slot).toInt();

    dlog.log('QUESTION', 'HTML recebido do Moodle', data: {
      'slot': actualSlot,
      'page': qMap['page'],
      'state': qMap['state'],
      'htmlLength': html.length,
      'htmlPreview': html.length > 300 ? '${html.substring(0, 300)}…' : html,
    });

    final parsed = MoodleHtmlParser.parse(
      html: html,
      attemptId: attemptId,
      slot: actualSlot,
      token: user.token,
      baseUrl: user.baseUrl,
    );

    dlog.log('QUESTION', 'Questão parseada', data: {
      'inputBaseName': parsed.inputBaseName,
      'hardcoded_seria': 'q$attemptId:${actualSlot}_answer',
      'base_difere': parsed.inputBaseName != 'q$attemptId:${actualSlot}_answer'
          ? '⚠️ SIM — ID real ≠ attemptId!'
          : 'não (iguais)',
      'seqCheck': parsed.seqCheck,
      'type': parsed.type,
      'choicesCount': parsed.choices.length,
      'choices': parsed.choices
          .map((c) => 'value="${c.value}" text="${c.text}"')
          .join(' | '),
    });

    return QuestionEntity(
      slot: parsed.slot,
      page: (qMap['page'] as num? ?? 0)
          .toInt(), // página real do Moodle (0-based)
      text: parsed.text,
      htmlText: parsed.htmlText,
      choices: parsed.choices,
      imageUrls: parsed.imageUrls,
      inputBaseName: parsed.inputBaseName,
      seqCheck: parsed.seqCheck,
      type: parsed.type,
    );
  }

  /// Busca a questão com determinado [slot] na [moodlePage] da tentativa.
  /// Retorna null se não encontrada.
  Future<Map<String, dynamic>?> _findQuestionBySlot(
      String baseUrl, String token, int attemptId, int slot,
      {required int moodlePage}) async {
    try {
      final data =
          await _moodle.getAttemptData(baseUrl, token, attemptId, moodlePage);
      final questions = data['questions'] as List? ?? [];
      for (final q in questions) {
        final qMap = Map<String, dynamic>.from(q as Map);
        final qSlot = (qMap['slot'] as num?)?.toInt();
        if (qSlot == slot) return qMap;
      }
    } catch (_) {}
    return null;
  }

  /// Carrega todas as questões do quiz usando UMA attempt, depois a finaliza
  /// e busca as respostas corretas via revisão. Usa nextpage do Moodle para
  /// navegar corretamente independente de quantas questões há por página.
  @override
  Future<List<QuestionEntity>> loadQuestionsWithAnswers(
      UserEntity user, int attemptId, int totalPages,
      {void Function(String)? onLog}) async {
    void log(String msg) => onLog?.call(msg);

    // 1. Carrega todas as páginas usando nextpage do Moodle
    final allQuestions = <QuestionEntity>[];
    final slotToPage = <int, int>{};
    int page = 0;
    int pageCount = 0;

    log('Carregando páginas da tentativa $attemptId…');
    while (page >= 0) {
      try {
        log('  → Buscando página $page…');
        final data = await _moodle.getAttemptData(
            user.baseUrl, user.token, attemptId, page);

        final questions = data['questions'] as List? ?? [];
        log('  → Página $page: ${questions.length} questão(ões) retornada(s)');

        for (final q in questions) {
          final qMap = Map<String, dynamic>.from(q as Map);
          final html = qMap['html'] as String? ?? '';
          final slot = (qMap['slot'] as num? ?? 1).toInt();
          final qPage = (qMap['page'] as num? ?? page).toInt();
          final type = qMap['type']?.toString() ?? '';

          final parsed = MoodleHtmlParser.parse(
            html: html,
            attemptId: attemptId,
            slot: slot,
            token: user.token,
            baseUrl: user.baseUrl,
          );

          log('     slot=$slot page=$qPage tipo=${type.isNotEmpty ? type : parsed.type} alternativas=${parsed.choices.length}');

          allQuestions.add(QuestionEntity(
            slot: parsed.slot,
            page: qPage,
            text: parsed.text,
            htmlText: parsed.htmlText,
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
        log('  → nextpage=$nextPage');
        page = nextPage;
        pageCount++;
      } catch (e) {
        log('  → ERRO ao buscar página $page: $e');
        break;
      }
    }

    log('Total bruto: ${allQuestions.length} questões em $pageCount página(s)');
    if (allQuestions.isEmpty) return allQuestions;

    // 2. Finaliza a attempt para liberar revisão
    log('Finalizando attempt para obter revisão…');
    try {
      await _moodle.finishAttempt(user.baseUrl, user.token, attemptId);
      log('Attempt finalizado com sucesso');
    } catch (e) {
      log('AVISO: finishAttempt falhou ($e) — respostas corretas não disponíveis');
      return allQuestions;
    }

    // 3. Busca revisão e marca isCorrect — agrupa por página
    final reviewPages = slotToPage.values.toSet();
    final reviewHtmlBySlot = <int, String>{};

    log('Buscando revisão em ${reviewPages.length} página(s)…');
    for (final reviewPage in reviewPages) {
      try {
        log('  → Revisão página $reviewPage…');
        final review = await _moodle.getAttemptReview(
            user.baseUrl, user.token, attemptId, reviewPage);
        int found = 0;
        for (final rq in (review['questions'] as List? ?? [])) {
          final rqMap = rq as Map;
          final slot = (rqMap['slot'] as num?)?.toInt();
          final html = rqMap['html'] as String? ?? '';
          if (slot != null && html.isNotEmpty) {
            reviewHtmlBySlot[slot] = html;
            found++;
          }
        }
        log('  → $found slot(s) com HTML de revisão');
      } catch (e) {
        log('  → ERRO na revisão página $reviewPage: $e');
      }
    }

    final result = <QuestionEntity>[];
    int skipped = 0;
    for (final q in allQuestions) {
      // Filtra questões sem alternativas (dissertativas/abertas)
      if (q.choices.isEmpty) {
        log('  ✗ slot=${q.slot} ignorada — sem alternativas (dissertativa/aberta)');
        skipped++;
        continue;
      }

      final reviewHtml = reviewHtmlBySlot[q.slot] ?? '';
      if (reviewHtml.isEmpty) {
        log('  ? slot=${q.slot} sem revisão — gabarito não disponível');
        result.add(q);
        continue;
      }
      final correctValues = MoodleHtmlParser.parseCorrectValues(reviewHtml);
      log('  ✓ slot=${q.slot} gabarito: $correctValues');

      // Debug: log detalhado do gabarito para o DebugLogger
      DebugLogger.instance.log(
          'GABARITO', 'slot=${q.slot} correctValues=$correctValues',
          data: {
            'choices': q.choices
                .map((c) => 'value="${c.value}" text="${c.text}"')
                .join(' | '),
            'reviewHtmlLength': reviewHtml.length,
            'reviewContainsRightAnswer': reviewHtml.contains('rightanswer'),
          });
      final newChoices = q.choices
          .map((c) => ParsedChoice(
                value: c.value,
                text: c.text,
                isCorrect: correctValues.contains(c.value),
              ))
          .toList();
      final feedback = MoodleHtmlParser.parseGeneralFeedback(reviewHtml);
      result.add(QuestionEntity(
        slot: q.slot,
        page: q.page,
        text: q.text,
        htmlText: q.htmlText,
        choices: newChoices,
        imageUrls: q.imageUrls,
        inputBaseName: q.inputBaseName,
        seqCheck: q.seqCheck,
        type: q.type,
        generalFeedback: feedback,
      ));
    }
    if (skipped > 0) log('Questões abertas ignoradas: $skipped');
    return result;
  }

  @override
  Future<bool> submitPage(UserEntity user, int attemptId,
      QuestionEntity question, String choiceValue) async {
    final dlog = DebugLogger.instance;
    dlog.separator('SUBMIT PAGE');

    // Log detalhado do que está sendo enviado
    final choiceText = question.choices
            .where((c) => c.value == choiceValue)
            .map((c) => c.text)
            .firstOrNull ??
        '?';

    dlog.log('SUBMIT', 'Dados da questão', data: {
      'attemptId': attemptId,
      'slot': question.slot,
      'page': question.page,
      'type': question.type,
      'inputBaseName': question.inputBaseName,
      'seqCheck': question.seqCheck,
      'choiceValue': choiceValue,
      'choiceText': choiceText,
      'totalChoices': question.choices.length,
      'allChoices': question.choices
          .map((c) =>
              'value="${c.value}" text="${c.text}" correct=${c.isCorrect}')
          .join(' | '),
    });

    final answerKey = question.inputBaseName;
    final seqCheckKey =
        question.inputBaseName.replaceFirst('answer', ':sequencecheck');
    // No Moodle, variáveis de comportamento usam prefixo "-" (hífen),
    // enquanto metadados do engine usam ":" (e.g. :sequencecheck).
    // O botão "Verificar" do quiz se chama -submit, não :submit.
    final submitKey = question.inputBaseName.replaceFirst('answer', '-submit');

    final answerData = {
      answerKey: choiceValue,
      seqCheckKey: question.seqCheck,
      submitKey: '1',
    };

    dlog.log('SUBMIT', 'Payload para Moodle', data: {
      answerKey: choiceValue,
      seqCheckKey: question.seqCheck,
      submitKey: '1',
    });

    // Salva e avalia a resposta sem fechar a tentativa.
    await _moodle.processAttempt(
        user.baseUrl, user.token, attemptId, answerData,
        page: question.page);

    // Lê o estado da questão após a avaliação.
    try {
      dlog.log('SUBMIT',
          'Lendo estado pós-avaliação (getAttemptData page=${question.page})…');
      final data = await _moodle.getAttemptData(
          user.baseUrl, user.token, attemptId, question.page);

      final questions = data['questions'] as List? ?? [];
      dlog.log(
          'SUBMIT', 'getAttemptData retornou ${questions.length} questão(ões)');

      for (final q in questions) {
        final qMap = q as Map;
        final qSlot = (qMap['slot'] as num?)?.toInt();
        final state = qMap['state']?.toString() ?? '';
        final status = qMap['status']?.toString() ?? '';
        final stateclass = qMap['stateclass']?.toString() ?? '';
        final seqCheckApi = qMap['sequencecheck']?.toString() ?? '';
        final flagged = qMap['flagged'];
        final qHtml = qMap['html'] as String? ?? '';

        dlog.log('SUBMIT', 'Questão retornada', data: {
          'slot': qSlot,
          'state': state,
          'stateclass': stateclass,
          'status': status,
          'sequencecheck': seqCheckApi,
          'flagged': flagged,
          'htmlLength': qHtml.length,
        });

        if (qSlot == question.slot) {
          // Analisa o HTML para pistas de avaliação
          final htmlHasCorrect = qHtml.contains('class="correct"') ||
              qHtml.contains('class="gradedright"');
          final htmlHasIncorrect = qHtml.contains('class="incorrect"') ||
              qHtml.contains('class="gradedwrong"') ||
              qHtml.contains('class="notanswered"');
          final htmlHasRightAnswer = qHtml.contains('rightanswer');
          final htmlHasFeedback = qHtml.contains('class="feedback"') ||
              qHtml.contains('specificfeedback') ||
              qHtml.contains('generalfeedback');
          // Verifica se o div principal tem a classe de estado
          final divClassMatch =
              RegExp(r'class="que\s+multichoice\s+immediatefeedback\s+(\w+)"')
                  .firstMatch(qHtml);
          final queStateClass = divClassMatch?.group(1) ?? '';

          dlog.log('SUBMIT', '★ Diagnóstico completo', data: {
            'state_api': state.isEmpty ? '(vazio)' : state,
            'stateclass_api': stateclass.isEmpty ? '(vazio)' : stateclass,
            'status_api': status,
            'queStateClass_html':
                queStateClass.isEmpty ? '(não encontrado)' : queStateClass,
            'html_correct': htmlHasCorrect,
            'html_incorrect': htmlHasIncorrect,
            'html_rightanswer': htmlHasRightAnswer,
            'html_feedback': htmlHasFeedback,
            'htmlPreview_200':
                qHtml.length > 200 ? qHtml.substring(0, 200) : qHtml,
          });

          // 1) Prioridade: campo state da API
          if (state == 'gradedright') return true;
          if (state == 'gradedwrong' || state == 'gradedpartial') return false;

          // 2) Fallback: stateclass da API
          if (stateclass == 'correct') return true;
          if (stateclass == 'incorrect' || stateclass == 'notanswered')
            return false;

          // 3) Fallback: classe no div principal do HTML
          if (queStateClass == 'correct') return true;
          if (queStateClass == 'incorrect' || queStateClass == 'notanswered')
            return false;

          // 4) Fallback: pistas genéricas no HTML
          if (htmlHasCorrect && !htmlHasIncorrect) return true;
          if (htmlHasIncorrect) return false;
          if (htmlHasRightAnswer) {
            // Se tem "rightanswer" no HTML, foi avaliado como errado
            // (Moodle mostra a resposta certa apenas quando errou)
            return false;
          }

          dlog.log('SUBMIT',
              '⚠ Nenhum indicador de correção encontrado. Possíveis causas:');
          dlog.log(
              'SUBMIT', '  1) Quiz usa deferred feedback (não avalia na hora)');
          dlog.log('SUBMIT',
              '  2) Opções de revisão não mostram "Se está correto" durante tentativa');

          break;
        }
      }
    } catch (e) {
      dlog.log('SUBMIT', '✗ ERRO ao ler estado pós-avaliação: $e');
    }

    dlog.log('SUBMIT', '→ Retornando FALSE (nenhum gradedright detectado)');
    return false;
  }

  @override
  Future<void> finishAttempt(UserEntity user, int attemptId) =>
      _moodle.finishAttempt(user.baseUrl, user.token, attemptId);

  // ── Moodle State ───────────────────────────────────────────────────────────

  @override
  Future<QuizStateEntity> getQuizState(UserEntity user, int courseId) async {
    final data = await _state.getState(user.baseUrl, user.token, courseId);
    return QuizStateModel.fromJson(data);
  }

  @override
  Future<void> setSelectedQuiz({
    required UserEntity user,
    required int courseId,
    required int quizId,
    required String quizName,
  }) =>
      _state.setSelectedQuiz(
        baseUrl: user.baseUrl,
        token: user.token,
        courseId: courseId,
        quizId: quizId,
        quizName: quizName,
      );

  @override
  Future<void> releaseQuestion({
    required UserEntity user,
    required int courseId,
    required int page,
    required int slot,
    required int duration,
    required int totalPages,
    required String quizName,
    required int quizId,
  }) =>
      _state.releaseQuestion(
        baseUrl: user.baseUrl,
        token: user.token,
        courseId: courseId,
        page: page,
        slot: slot,
        duration: duration,
        totalPages: totalPages,
        quizName: quizName,
        quizId: quizId,
      );

  @override
  Future<void> closeQuestion(UserEntity user, int courseId) =>
      _state.closeQuestion(user.baseUrl, user.token, courseId);

  @override
  Future<void> submitScore({
    required UserEntity user,
    required int courseId,
    required int score,
    required bool correct,
    required int page,
  }) async {
    final dl = DebugLogger.instance;
    dl.log('SCORE', 'submitScore chamado', data: {
      'studentId': user.id,
      'score': score,
      'correct': correct,
      'page': page,
    });
    await _state.submitScore(
      baseUrl: user.baseUrl,
      token: user.token,
      courseId: courseId,
      studentId: user.id.toString(),
      studentName: user.fullname,
      score: score,
      correct: correct,
      page: page,
    );
    dl.log('SCORE', 'submitScore concluído ✓');
  }

  @override
  Future<List<ScoreEntity>> getScores(UserEntity user, int courseId) async {
    final list = await _state.getScores(user.baseUrl, user.token, courseId);

    // Ordena por score desc para atribuir rank
    final sorted = [...list];
    sorted.sort((a, b) {
      final sa = (a['score'] as num? ?? 0).toInt();
      final sb = (b['score'] as num? ?? 0).toInt();
      return sb.compareTo(sa);
    });

    final result = sorted.indexed.map(((int, Map<String, dynamic>) entry) {
      final rank = entry.$1 + 1;
      final j = entry.$2;
      final id = j['student_id']?.toString() ?? '';
      // total_answered = número de páginas respondidas
      int totalAnswered = 0;
      try {
        final pages = j['pages'];
        if (pages is String && pages.isNotEmpty) {
          final decoded = jsonDecode(pages);
          if (decoded is Map) {
            // Novo formato: {"0": {"s": 1230, "c": 1}, ...}
            totalAnswered = decoded.length;
          } else if (decoded is List) {
            // Formato legado: [0, 1, 2]
            totalAnswered = decoded.length;
          }
        } else if (pages is List) {
          totalAnswered = pages.length;
        } else if (pages is Map) {
          totalAnswered = pages.length;
        }
      } catch (_) {}
      return ScoreModel.fromJson(
        {...j, 'rank': rank, 'total_answered': totalAnswered},
        previousRank: _prevRanks[id],
      );
    }).toList();

    _prevRanks = {for (final s in result) s.studentId: s.rank};
    return result;
  }

  @override
  Future<void> resetQuiz(UserEntity user, int courseId) async {
    await _state.resetQuiz(user.baseUrl, user.token, courseId);
    _prevRanks = {};
  }

  @override
  Future<void> setFinished(UserEntity user, int courseId) =>
      _state.setFinished(user.baseUrl, user.token, courseId);
}
