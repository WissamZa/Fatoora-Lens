/// Splits a seller name that mixes Arabic and Latin scripts into its
/// Arabic and English parts.
///
/// ZATCA QR payloads frequently carry both names in a single field, and
/// different merchants separate them in different ways: a newline
/// ("عربي\nEnglish"), a pipe ("عربي | English"), brackets, slashes, or no
/// separator at all ("عربي English"). The rule is script-based, so it works
/// regardless of the separator or which language comes first.
class SplitSellerName {
  const SplitSellerName({required this.arabic, required this.english});

  final String arabic;
  final String english;
}

class SellerNameSplitter {
  const SellerNameSplitter._();

  /// Arabic block, Arabic Supplement, Arabic Extended-A/B, and the
  /// presentation forms used by some QR encoders.
  static final RegExp _arabicChar = RegExp(
    r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
  );

  /// Basic Latin letters plus Latin-1/Latin Extended, so names like
  /// "Crédit" still count as Latin.
  static final RegExp _latinChar = RegExp(r'[A-Za-z\u00C0-\u024F]');

  static bool containsArabic(String text) => _arabicChar.hasMatch(text);

  static bool containsLatin(String text) => _latinChar.hasMatch(text);

  static bool isMixedScript(String text) =>
      containsArabic(text) && containsLatin(text);

  static SplitSellerName split(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      return const SplitSellerName(arabic: '', english: '');
    }

    final hasArabic = containsArabic(text);
    final hasLatin = containsLatin(text);
    if (!hasArabic && !hasLatin) {
      // Digits and symbols only: keep everything in the primary slot.
      return SplitSellerName(arabic: text, english: '');
    }
    if (!hasLatin) return SplitSellerName(arabic: text, english: '');
    if (!hasArabic) return SplitSellerName(arabic: '', english: text);

    // Both scripts are present. Walk the text as script runs: characters
    // between two runs of the same script (spaces, punctuation, digits)
    // stay with that script. Separators between the two languages — and
    // the edges of the string — are dropped, except for numbers, which
    // stay with the name before them ("متجر 5 Store" → "متجر 5" / "Store").
    final tokens = _tokenize(text);
    final arabic = StringBuffer();
    final english = StringBuffer();
    _Script previousScript = _Script.neutral;
    for (var i = 0; i < tokens.length; i++) {
      final (script, chunk) = tokens[i];
      switch (script) {
        case _Script.arabic:
          arabic.write(chunk);
          previousScript = _Script.arabic;
        case _Script.latin:
          english.write(chunk);
          previousScript = _Script.latin;
        case _Script.neutral:
          if (previousScript == _Script.neutral) break;
          final nextScript = _nextScript(tokens, i);
          final sameScript = nextScript == previousScript;
          final boundaryWithDigit =
              nextScript != previousScript && _containsDigit(chunk);
          final trailingPunctuation =
              nextScript == _Script.neutral && _isTrailingPunctuation(chunk);
          if (sameScript || boundaryWithDigit || trailingPunctuation) {
            (previousScript == _Script.arabic ? arabic : english).write(chunk);
          }
      }
    }

    return SplitSellerName(
      arabic: _collapseSpaces(arabic.toString()),
      english: _collapseSpaces(english.toString()),
    );
  }

  static _Script _classify(String char) {
    if (containsArabic(char)) return _Script.arabic;
    if (containsLatin(char)) return _Script.latin;
    return _Script.neutral;
  }

  static List<(_Script, String)> _tokenize(String text) {
    final tokens = <(_Script, String)>[];
    final chunk = StringBuffer();
    _Script? current;
    for (final rune in text.runes) {
      final script = _classify(String.fromCharCode(rune));
      if (script != current) {
        if (current != null) tokens.add((current, chunk.toString()));
        chunk.clear();
        current = script;
      }
      chunk.writeCharCode(rune);
    }
    if (current != null) tokens.add((current, chunk.toString()));
    return tokens;
  }

  static _Script _nextScript(List<(_Script, String)> tokens, int index) {
    for (var i = index + 1; i < tokens.length; i++) {
      if (tokens[i].$1 != _Script.neutral) return tokens[i].$1;
    }
    return _Script.neutral;
  }

  static bool _containsDigit(String value) => RegExp(r'\d').hasMatch(value);

  /// Trailing punctuation worth keeping with the name — abbreviation dots
  /// as in "Co. Ltd." — but not separators like ")" or a newline.
  static bool _isTrailingPunctuation(String chunk) =>
      chunk.contains('.') && RegExp(r'^[\s.]+$').hasMatch(chunk);

  static String _collapseSpaces(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

enum _Script { arabic, latin, neutral }
