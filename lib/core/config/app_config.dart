/// Configurações globais carregadas do Google Sheets.
/// S: Responsabilidade única – apenas armazena config.
class AppConfig {
  static const String appName = 'MoodleQuiz Live';
  static const String version = '1.0.0';

  static String gsheetScriptUrl = '';
  static String studentUrl = 'https://lasec-ufu.github.io/MoodleQuiz/';
  static String moodleBaseUrl = '';
  static String quizTitle = 'Quiz Interativo';
  static int defaultQuestionTime = 30;
  static List<int> questionTimeOptions = [15, 20, 30, 45, 60, 90];
  static String teacherToken = '';

  static void loadFromMap(Map<String, dynamic> config) {
    moodleBaseUrl =
        (config['moodle_url'] as String?)?.trim() ?? moodleBaseUrl;
    quizTitle = (config['quiz_title'] as String?) ?? quizTitle;
    defaultQuestionTime =
        int.tryParse(config['default_question_time']?.toString() ?? '') ??
            defaultQuestionTime;
    teacherToken = (config['teacher_token'] as String?) ?? teacherToken;

    final raw = config['question_time_options']?.toString() ?? '';
    if (raw.isNotEmpty) {
      final parsed = raw
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
      if (parsed.isNotEmpty) questionTimeOptions = parsed;
    }
  }

  static bool get isConfigured => gsheetScriptUrl.isNotEmpty;
}
