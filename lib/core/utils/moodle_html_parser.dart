/// Extrai dados estruturados de um bloco HTML de questão do Moodle.
/// Implementado em Dart puro (compatível com WASM – sem dart:html).
library;

// ── Entidades de saída ────────────────────────────────────────────────────────

class ParsedChoice {
  final String value;     // "0", "1", "2"…
  final String text;      // texto exibido para o aluno
  final bool isCorrect;   // true se esta alternativa é a resposta correta

  const ParsedChoice({required this.value, required this.text, this.isCorrect = false});
}

class ParsedQuestion {
  final int slot;
  final String text;           // texto da questão (HTML stripped)
  final List<ParsedChoice> choices;
  final List<String> imageUrls;
  final String inputBaseName;  // "q{attemptId}:{slot}_answer"
  final String seqCheck;       // valor do input sequencecheck
  final String type;           // "multichoice" | "truefalse" | "other"

  const ParsedQuestion({
    required this.slot,
    required this.text,
    required this.choices,
    required this.imageUrls,
    required this.inputBaseName,
    required this.seqCheck,
    required this.type,
  });

  bool get isMultiChoice => type == 'multichoice' || type == 'truefalse';
}

// ── Parser ────────────────────────────────────────────────────────────────────

class MoodleHtmlParser {
  /// Analisa o HTML de `mod_quiz_get_attempt_data.questions[].html`.
  static ParsedQuestion parse({
    required String html,
    required int attemptId,
    required int slot,
    required String token,
    required String baseUrl,
  }) {
    final text = _extractText(html);
    final choices = _extractChoices(html);
    final images = _extractImages(html, token, baseUrl);
    final seqCheck = _extractSeqCheck(html);

    final inputBase = 'q$attemptId:${slot}_answer';
    final type =
        choices.length == 2 ? 'truefalse' : (choices.isEmpty ? 'other' : 'multichoice');

    return ParsedQuestion(
      slot: slot,
      text: text,
      choices: choices,
      imageUrls: images,
      inputBaseName: inputBase,
      seqCheck: seqCheck,
      type: type,
    );
  }

  /// Extrai os values dos inputs de rádio dentro de containers com classe
  /// "correct" (mas não "incorrect") no HTML da revisão da tentativa.
  /// Padrão Moodle: `<li class="r0 correct">` contém `<input type="radio" value="X">`.
  static List<String> parseCorrectValues(String reviewHtml) {
    final correctValues = <String>[];

    // Regex para encontrar elementos li/div com classe contendo "correct"
    // mas não "incorrect"
    final containerRe = RegExp(
      r'<(?:li|div)\b[^>]*class="([^"]*)"[^>]*>(.*?)</(?:li|div)>',
      caseSensitive: false,
      dotAll: true,
    );

    final radioValueRe = RegExp(
      r'<input\b[^>]*type="radio"[^>]*value="([^"]*)"',
      caseSensitive: false,
    );

    for (final m in containerRe.allMatches(reviewHtml)) {
      final classAttr = m.group(1) ?? '';
      final content = m.group(2) ?? '';

      // Verifica se a classe contém "correct" mas não "incorrect"
      if (classAttr.contains('correct') && !classAttr.contains('incorrect')) {
        final radioMatch = radioValueRe.firstMatch(content);
        if (radioMatch != null) {
          final value = radioMatch.group(1) ?? '';
          if (value.isNotEmpty && value != '-1') {
            correctValues.add(value);
          }
        }
      }
    }

    return correctValues;
  }

  // ── Extração do texto da questão ──────────────────────────────────────────

  static String _extractText(String html) {
    String text = _extractTag(html, 'qtext') ??
        _extractTag(html, 'formulation') ??
        '';

    if (text.isEmpty) {
      text = html;
    }

    text = _removeBlock(text, r'class="(?:ablock|answer)');

    return _stripHtml(text).trim();
  }

  // ── Extração de alternativas ──────────────────────────────────────────────

  static List<ParsedChoice> _extractChoices(String html) {
    final choices = <ParsedChoice>[];

    // Captura qualquer <input type="radio" ...> independente da ordem dos atributos
    final radioRe = RegExp(
      r'<input\b[^>]*type="radio"[^>]*/?>',
      caseSensitive: false,
    );

    final attrRe = RegExp(r'(\w+)="([^"]*)"', caseSensitive: false);

    final labelsByForRe = RegExp(
      r'<label\b[^>]+for="([^"]+)"[^>]*>(.*?)</label>',
      caseSensitive: false,
      dotAll: true,
    );

    final labelMap = <String, String>{};
    for (final m in labelsByForRe.allMatches(html)) {
      final forAttr = m.group(1) ?? '';
      final labelHtml = m.group(2) ?? '';
      labelMap[forAttr] = _stripHtml(labelHtml).trim();
    }

    for (final m in radioRe.allMatches(html)) {
      final inputTag = m.group(0) ?? '';
      String value = '';
      String id = '';

      for (final a in attrRe.allMatches(inputTag)) {
        final key = a.group(1)!.toLowerCase();
        final val = a.group(2)!;
        if (key == 'value') value = val;
        if (key == 'id') id = val;
      }

      // Ignora o botão "Limpar minha escolha" (value == -1)
      if (value.isEmpty || value == '-1') continue;

      String text = id.isNotEmpty ? (labelMap[id] ?? '') : '';

      if (text.isEmpty) {
        final afterInput = html.substring(m.end);
        final nextLabel = RegExp(
          r'<label\b[^>]*>(.*?)</label>',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(afterInput);
        if (nextLabel != null) {
          final candidate = _stripHtml(nextLabel.group(1) ?? '').trim();
          // Ignora se for o texto do botão de limpar
          if (!candidate.toLowerCase().contains('limpar')) {
            text = candidate;
          }
        }
      }

      choices.add(ParsedChoice(value: value, text: text));
    }

    return choices;
  }

  // ── Extração de imagens ───────────────────────────────────────────────────

  static List<String> _extractImages(
      String html, String token, String baseUrl) {
    final images = <String>[];
    final imgRe = RegExp(
      r'<img[^>]+src="([^"]+)"',
      caseSensitive: false,
    );

    for (final m in imgRe.allMatches(html)) {
      var src = m.group(1) ?? '';
      if (src.isEmpty) continue;

      if (src.startsWith('@@PLUGINFILE@@')) {
        src = src.replaceFirst(
            '@@PLUGINFILE@@', '$baseUrl/webservice/pluginfile.php');
      } else if (src.startsWith('/') && !src.startsWith('//')) {
        src = '$baseUrl$src';
      }

      if (src.contains('pluginfile.php') && !src.contains('token=')) {
        final sep = src.contains('?') ? '&' : '?';
        src = '$src${sep}token=$token';
      }

      images.add(src);
    }

    return images;
  }

  // ── Extração do sequencecheck ─────────────────────────────────────────────

  static String _extractSeqCheck(String html) {
    final re = RegExp(
      r'<input[^>]+name="[^"]*:sequencecheck"[^>]*value="([^"]+)"',
      caseSensitive: false,
    );
    return re.firstMatch(html)?.group(1) ?? '1';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Extrai conteúdo de `<div class="...{className}...">...</div>`
  static String? _extractTag(String html, String className) {
    final re = RegExp(
      'class="[^"]*$className[^"]*"',
      caseSensitive: false,
    );
    final start = re.firstMatch(html)?.start;
    if (start == null) return null;

    int tagStart = html.lastIndexOf('<', start);
    if (tagStart < 0) return null;

    int depth = 1;
    int i = html.indexOf('>', tagStart) + 1;
    while (i < html.length && depth > 0) {
      final openDiv = html.indexOf('<div', i);
      final closeDiv = html.indexOf('</div', i);
      if (closeDiv < 0) break;
      if (openDiv >= 0 && openDiv < closeDiv) {
        depth++;
        i = openDiv + 4;
      } else {
        depth--;
        if (depth == 0) return html.substring(tagStart, closeDiv);
        i = closeDiv + 5;
      }
    }
    return null;
  }

  /// Remove um bloco HTML que contém a classe/atributo indicado.
  static String _removeBlock(String html, String pattern) {
    final re = RegExp(pattern, caseSensitive: false);
    final match = re.firstMatch(html);
    if (match == null) return html;

    int tagStart = html.lastIndexOf('<', match.start);
    if (tagStart < 0) return html;

    int depth = 1;
    int i = html.indexOf('>', tagStart) + 1;
    while (i < html.length && depth > 0) {
      final open = html.indexOf('<div', i);
      final close = html.indexOf('</div', i);
      if (close < 0) break;
      if (open >= 0 && open < close) {
        depth++;
        i = open + 4;
      } else {
        depth--;
        if (depth == 0) {
          final end = html.indexOf('>', close) + 1;
          return html.substring(0, tagStart) + html.substring(end);
        }
        i = close + 5;
      }
    }
    return html;
  }

  /// Remove todas as tags HTML e decodifica entidades básicas.
  static String _stripHtml(String html) {
    return html
        .replaceAll(
            RegExp(r'<br\s*/?>|</p>|</li>|</div>', caseSensitive: false),
            '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
