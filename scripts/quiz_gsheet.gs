/**
 * MoodleQuiz Live – Google Apps Script Backend
 * =============================================
 * Implantação: Extensões → Apps Script → Implantar → App da Web
 *   Execute como: Eu mesmo
 *   Acesso: Qualquer pessoa
 *
 * Questões NÃO são armazenadas aqui. Vêm diretamente do Moodle via API.
 * Esta planilha gerencia apenas:
 *   - Estado do quiz (qual página está ativa, timer, quiz_id)
 *   - Pontuações dos estudantes (reportadas pelo cliente após feedback do Moodle)
 *
 * Estrutura de Planilhas criada por setupSheets():
 *   config       – Configurações (moodle_url, quiz_title, default_question_time, question_time_options, teacher_token)
 *   quiz_state   – Estado atual (state, current_page, total_pages, quiz_id, …)
 *   scores       – Pontuações por estudante
 */

// ── Constantes ──────────────────────────────────────────────────────────────

const SHEETS = {
  CONFIG: 'config',
  STATE: 'quiz_state',
  SCORES: 'scores',
};

// ── Roteador principal ───────────────────────────────────────────────────────

function doGet(e) {
  try {
    const action = (e.parameter && e.parameter.action) || '';
    let result;

    switch (action) {
      case 'getConfig':       result = getConfig();             break;
      case 'getState':        result = getState();              break;
      case 'releaseQuestion': result = releaseQuestion(e);      break;
      case 'closeQuestion':   result = closeQuestion(e);        break;
      case 'submitScore':     result = submitScore(e);          break;
      case 'getScores':       result = getScores();             break;
      case 'resetQuiz':       result = resetQuiz(e);            break;
      case 'setFinished':     result = setFinished(e);          break;
      case 'setup':           result = setupSheets();           break;
      default:
        result = { error: 'Ação desconhecida: ' + action };
    }

    return jsonResponse(result);
  } catch (err) {
    return jsonResponse({ error: err.message });
  }
}

function doPost(e) {
  return doGet(e);
}

function jsonResponse(data) {
  return ContentService
    .createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

// ── Helpers de planilha ──────────────────────────────────────────────────────

function ss() {
  return SpreadsheetApp.getActiveSpreadsheet();
}

function sheet(name) {
  const s = ss().getSheetByName(name);
  if (!s) throw new Error('Planilha "' + name + '" não encontrada. Execute ?action=setup primeiro.');
  return s;
}

function getConfigValue(key) {
  const data = sheet(SHEETS.CONFIG).getDataRange().getValues();
  for (const row of data) {
    if (String(row[0]) === key) return row[1];
  }
  return null;
}

function setConfigValue(key, value) {
  const s = sheet(SHEETS.CONFIG);
  const data = s.getDataRange().getValues();
  for (let i = 0; i < data.length; i++) {
    if (String(data[i][0]) === key) {
      s.getRange(i + 1, 2).setValue(value);
      return;
    }
  }
  s.appendRow([key, value]);
}

function requireTeacher(e) {
  const token = (e.parameter && e.parameter.token) || '';
  const teacherToken = String(getConfigValue('teacher_token') || '');
  if (!teacherToken || token !== teacherToken) {
    throw new Error('Não autorizado. Token de professor inválido.');
  }
}

// ── Actions ──────────────────────────────────────────────────────────────────

/**
 * GET ?action=getConfig
 * Retorna todas as configurações (incluindo teacher_token).
 * Mantenha a URL do script em segredo – é a primeira linha de defesa.
 */
function getConfig() {
  const data = sheet(SHEETS.CONFIG).getDataRange().getValues();
  const config = {};
  for (const row of data) {
    if (row[0] && String(row[0]) !== 'key') {
      config[String(row[0])] = row[1];
    }
  }
  return { success: true, ...config };
}

function getStateValue(key) {
  const data = sheet(SHEETS.STATE).getDataRange().getValues();
  for (const row of data) {
    if (String(row[0]) === key) return row[1];
  }
  return null;
}

function setStateValue(key, value) {
  const s = sheet(SHEETS.STATE);
  const data = s.getDataRange().getValues();
  for (let i = 0; i < data.length; i++) {
    if (String(data[i][0]) === key) {
      s.getRange(i + 1, 2).setValue(value);
      return;
    }
  }
  s.appendRow([key, value]);
}

/**
 * GET ?action=getState
 * Retorna o estado atual do quiz (sem questões – essas vêm do Moodle).
 */
function getState() {
  const stateData = sheet(SHEETS.STATE).getDataRange().getValues();
  const state = {};
  for (const row of stateData) {
    if (row[0]) state[String(row[0])] = row[1];
  }

  return {
    success: true,
    state:        state['state']        || 'waiting',
    current_page: state['current_page'] !== undefined ? Number(state['current_page']) : -1,
    total_pages:  Number(state['total_pages'])  || 0,
    quiz_id:      Number(state['quiz_id'])      || 0,
    quiz_name:    state['quiz_name']    || 'Quiz',
    started_at:   state['started_at']   || '',
    ends_at:      state['ends_at']      || '',
  };
}

/**
 * GET ?action=releaseQuestion&page=0&duration=30&totalPages=5&quizName=X&quizId=Y
 * Professor libera uma página de questão para os estudantes.
 */
function releaseQuestion(e) {
  requireTeacher(e);
  const { page, duration, totalPages, quizName, quizId } = e.parameter || {};

  if (page === undefined) return { error: 'page obrigatório' };

  const dur = parseInt(duration) || 30;
  const now = new Date();
  const endsAt = new Date(now.getTime() + dur * 1000);

  setStateValue('state',        'active');
  setStateValue('current_page', parseInt(page));
  setStateValue('started_at',   now.toISOString());
  setStateValue('ends_at',      endsAt.toISOString());

  if (totalPages !== undefined) setStateValue('total_pages', parseInt(totalPages));
  if (quizName)                 setStateValue('quiz_name',   quizName);
  if (quizId)                   setStateValue('quiz_id',     parseInt(quizId));

  return { success: true, endsAt: endsAt.toISOString() };
}

/**
 * GET ?action=closeQuestion
 * Professor encerra a questão atual.
 */
function closeQuestion(e) {
  requireTeacher(e);
  setStateValue('state', 'closed');
  return { success: true };
}

/**
 * GET ?action=setFinished
 * Professor marca o quiz como finalizado.
 */
function setFinished(e) {
  requireTeacher(e);
  setStateValue('state', 'finished');
  return { success: true };
}

/**
 * GET ?action=submitScore&studentId=X&studentName=N&score=1000&correct=true&page=0
 * Estudante reporta sua pontuação após receber feedback do Moodle.
 * Idempotente: uma submissão por estudante por página.
 */
function submitScore(e) {
  const { studentId, studentName, score, correct, page } = e.parameter || {};

  if (!studentId) return { error: 'studentId obrigatório' };

  const pageNum    = parseInt(page) || 0;
  const scoreNum   = parseInt(score) || 0;
  const isCorrect  = String(correct).toLowerCase() === 'true';
  const name       = studentName || 'Desconhecido';

  const sc   = sheet(SHEETS.SCORES);
  const data = sc.getDataRange().getValues();

  // ── Verifica duplicidade por (studentId, page) ─────────────────────────
  // Col: 0=student_id, 1=student_name, 2=correct_count, 3=total_answered,
  //      4=score, 5=rank, 6+=pages_answered (JSON array)
  for (let i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(studentId)) continue;

    const pagesAnswered = data[i][6] ? JSON.parse(String(data[i][6])) : [];
    if (pagesAnswered.includes(pageNum)) {
      return { success: true, duplicate: true };
    }

    // Atualiza linha existente
    pagesAnswered.push(pageNum);
    const newCorrect = (Number(data[i][2]) || 0) + (isCorrect ? 1 : 0);
    const newTotal   = (Number(data[i][3]) || 0) + 1;
    const newScore   = (Number(data[i][4]) || 0) + scoreNum;

    sc.getRange(i + 1, 2).setValue(name);
    sc.getRange(i + 1, 3).setValue(newCorrect);
    sc.getRange(i + 1, 4).setValue(newTotal);
    sc.getRange(i + 1, 5).setValue(newScore);
    sc.getRange(i + 1, 7).setValue(JSON.stringify(pagesAnswered));

    _updateRanks();
    return { success: true };
  }

  // Nova entrada
  sc.appendRow([
    studentId,
    name,
    isCorrect ? 1 : 0,
    1,
    scoreNum,
    0,                             // rank (preenchido por _updateRanks)
    JSON.stringify([pageNum]),     // pages_answered
  ]);

  _updateRanks();
  return { success: true };
}

/**
 * GET ?action=getScores
 * Retorna o ranking atual.
 */
function getScores() {
  const data = sheet(SHEETS.SCORES).getDataRange().getValues();
  if (data.length <= 1) return { success: true, scores: [] };

  const scores = [];
  for (let i = 1; i < data.length; i++) {
    if (!data[i][0]) continue;
    scores.push({
      student_id:      String(data[i][0]),
      student_name:    String(data[i][1]),
      correct_count:   Number(data[i][2]) || 0,
      total_answered:  Number(data[i][3]) || 0,
      score:           Number(data[i][4]) || 0,
      rank:            Number(data[i][5]) || 99,
    });
  }

  scores.sort((a, b) => (a.rank || 999) - (b.rank || 999));
  return { success: true, scores };
}

/**
 * GET ?action=resetQuiz
 * Apaga pontuações e volta ao estado inicial.
 */
function resetQuiz(e) {
  requireTeacher(e);
  // Limpa pontuações
  const sc = sheet(SHEETS.SCORES);
  if (sc.getLastRow() > 1) {
    sc.deleteRows(2, sc.getLastRow() - 1);
  }

  // Reseta estado
  setStateValue('state',        'waiting');
  setStateValue('current_page', -1);
  setStateValue('started_at',   '');
  setStateValue('ends_at',      '');

  return { success: true };
}

// ── Lógica de ranking ────────────────────────────────────────────────────────

function _updateRanks() {
  const sc = sheet(SHEETS.SCORES);
  const data = sc.getDataRange().getValues();
  if (data.length <= 1) return;

  const rows = [];
  for (let i = 1; i < data.length; i++) {
    if (data[i][0]) rows.push({ row: i + 1, score: Number(data[i][4]) || 0 });
  }
  rows.sort((a, b) => b.score - a.score);
  rows.forEach((item, idx) => {
    sc.getRange(item.row, 6).setValue(idx + 1);
  });
}

// ── Configuração inicial ─────────────────────────────────────────────────────

/**
 * Execute ?action=setup UMA VEZ para criar a estrutura de planilhas.
 */
function setupSheets() {
  const spreadsheet = ss();

  // ── config ──────────────────────────────────────────────────────────────
  let cfg = spreadsheet.getSheetByName(SHEETS.CONFIG);
  if (cfg) spreadsheet.deleteSheet(cfg);
  cfg = spreadsheet.insertSheet(SHEETS.CONFIG);
  cfg.getRange('A1:B1').setValues([['key', 'value']]);
  cfg.getRange('A2:B6').setValues([
    ['moodle_url',             'https://moodle.suainstituicao.edu.br'],
    ['quiz_title',             'Quiz Interativo'],
    ['default_question_time',  30],
    ['question_time_options',  '15,20,30,45,60,90'],  // ← lista separada por vírgula
    ['teacher_token',          'TROQUE_ESTE_TOKEN_AGORA'],  // ← ALTERE!
  ]);
  cfg.setFrozenRows(1);

  // ── quiz_state ──────────────────────────────────────────────────────────
  let st = spreadsheet.getSheetByName(SHEETS.STATE);
  if (st) spreadsheet.deleteSheet(st);
  st = spreadsheet.insertSheet(SHEETS.STATE);
  st.getRange('A1:B1').setValues([['key', 'value']]);
  st.getRange('A2:B9').setValues([
    ['state',        'waiting'],
    ['current_page', -1],
    ['total_pages',  0],
    ['quiz_id',      0],
    ['quiz_name',    'Quiz'],
    ['started_at',   ''],
    ['ends_at',      ''],
    ['duration',     30],
  ]);
  st.setFrozenRows(1);

  // ── scores ──────────────────────────────────────────────────────────────
  let sc = spreadsheet.getSheetByName(SHEETS.SCORES);
  if (sc) spreadsheet.deleteSheet(sc);
  sc = spreadsheet.insertSheet(SHEETS.SCORES);
  sc.getRange('A1:G1').setValues([[
    'student_id', 'student_name', 'correct_count',
    'total_answered', 'score', 'rank', 'pages_answered'
  ]]);
  sc.setFrozenRows(1);

  // ── Formata cabeçalhos ───────────────────────────────────────────────────
  [cfg, st, sc].forEach(s => {
    s.getRange(1, 1, 1, s.getLastColumn())
      .setBackground('#1A1A3E')
      .setFontColor('#6C63FF')
      .setFontWeight('bold');
  });

  // Remove sheets antigas não mais usadas
  ['questions', 'answers'].forEach(name => {
    const old = spreadsheet.getSheetByName(name);
    if (old) {
      try { spreadsheet.deleteSheet(old); } catch (_) {}
    }
  });

  return {
    success: true,
    message: 'Planilhas criadas! Copie a URL de implantação (Implantar → Gerenciar implantações) e configure no app via parâmetro ?gs=URL',
  };
}
