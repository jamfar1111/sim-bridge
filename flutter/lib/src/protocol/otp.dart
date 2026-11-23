/// One-time-code extraction from SMS bodies and phone-number matching.
///
/// Port of `OTPExtractor` and `PhoneNumber` in Tether's iOS core
/// (`TetherCore/Util.swift`). Tested against the `otp` vectors in
/// `protocol/vectors.json`.
library;

/// Finds one-time codes in message text.
abstract final class OtpExtractor {
  /// Words that announce a one-time code (lower-cased; Persian with and
  /// without hamza / ZWNJ variants).
  static const List<String> keywords = [
    'code', 'otp', 'pin', 'password', 'passcode', 'verification',
    'one-time', 'one time', 'security code',
    'کد', 'رمز', 'تایید', 'تأیید', 'پویا', 'یکبار', 'یک بار', 'یک‌بار',
    'کلمه عبور', 'گذرواژه',
  ];

  /// Words that mark the number next to them as something else (money,
  /// balance, card, date, time, phone).
  static const List<String> notCode = [
    'ریال', 'تومان', 'مبلغ', 'مانده', 'موجودی', 'برداشت', 'واریز',
    'rial', 'toman', 'irr', 'amount', 'balance', 'usd', r'$', '€',
    'کارت', 'card', 'حساب', 'account', 'تاریخ', 'date', 'ساعت', 'time',
    'ثانیه', 'دقیقه', 'seconds', 'minutes', 'sec', 'min',
    'تلفن', 'phone', 'tel',
  ];

  static const List<String> units = [
    'ریال', 'تومان', 'rial', 'toman', 'irr', 'usd', r'$', '€',
    'ثانیه', 'دقیقه', 'sec', 'min',
  ];

  /// Converts Persian (U+06F0–U+06F9) and Arabic-Indic (U+0660–U+0669)
  /// digits to ASCII.
  static String normalizeDigits(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      if (rune >= 0x06f0 && rune <= 0x06f9) {
        out.writeCharCode(0x30 + rune - 0x06f0);
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        out.writeCharCode(0x30 + rune - 0x0660);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// The one-time code in [text], or `null` when there is none.
  static String? extract(String text) => find(text)?.code;

  /// The one-time code and its UTF-16 range in the original string,
  /// or `null`.
  ///
  /// Candidates are 4–8 digit runs (or 3+3 groups such as "123-456")
  /// that are not part of a longer number, a masked card ("6037**1234"),
  /// a date / time ("1403/08/30", "14:35") or a decimal / grouped amount
  /// ("1,250,000"). The message must contain a code keyword; the
  /// candidate nearest after a keyword wins, 5–6 digits preferred, and
  /// numbers next to money / card / date / time words are skipped.
  static ({String code, int start, int end})? find(String text) {
    final normalized = normalizeDigits(text);
    final lower = normalized.toLowerCase();
    final keywordEnds = <int>[];
    final keywordStarts = <int>[];
    for (final keyword in keywords) {
      var from = 0;
      while (true) {
        final index = lower.indexOf(keyword, from);
        if (index < 0) break;
        keywordStarts.add(index);
        keywordEnds.add(index + keyword.length);
        from = index + keyword.length;
      }
    }
    if (keywordEnds.isEmpty) return null;

    ({int score, String code, int start, int end})? best;
    for (final match in _candidateMatches(normalized)) {
      final start = match.$1;
      final end = match.$2;
      final code =
          normalized.substring(start, end).replaceAll(RegExp(r'[^0-9]'), '');
      if (code.length < 4 || code.length > 8) continue;

      // Context: ~14 characters on each side.
      final beforeStart = start - 14 < 0 ? 0 : start - 14;
      final before = lower.substring(beforeStart, start);
      final afterEnd = end + 14 > lower.length ? lower.length : end + 14;
      final after = lower.substring(end, afterEnd);
      // Bank texts are one field per line: context stops at a line break.
      final nearBefore = before.length <= 9
          ? before
          : before.substring(before.length - 9);
      final nearBeforeLine =
          nearBefore.split('\n').last;
      final nearAfter = after.length <= 9 ? after : after.substring(0, 9);
      final nearAfterLine = nearAfter.split('\n').first;
      // Labels come before a number ("مبلغ", "card", "date"); units after
      // it ("ریال", "seconds").
      if (notCode.any(nearBeforeLine.contains) ||
          units.any(nearAfterLine.contains)) {
        // …unless a code keyword sits right before the number
        // ("رمز: 1234 مبلغ" still is a code).
        if (!keywordEnds.any((kwEnd) =>
            start - kwEnd >= 0 && start - kwEnd <= 4)) {
          continue;
        }
      }
      var score = (code.length >= 5 && code.length <= 6) ? 3 : 1;
      final beforeDistances = keywordEnds
          .map((kwEnd) => start - kwEnd)
          .where((d) => d >= 0);
      if (beforeDistances.isNotEmpty) {
        final d = beforeDistances.reduce((a, b) => a < b ? a : b);
        score += d <= 3 ? 6 : d <= 30 ? 4 : 1;
      }
      final afterDistances = keywordStarts
          .map((kwStart) => kwStart - end)
          .where((d) => d >= 0);
      if (afterDistances.isNotEmpty) {
        final d = afterDistances.reduce((a, b) => a < b ? a : b);
        if (d <= 30) score += 2; // "123456 is your code"
      }
      if (best == null || score > best.score) {
        best = (score: score, code: code, start: start, end: end);
      }
    }
    if (best == null) return null;
    return (code: best.code, start: best.start, end: best.end);
  }

  /// Candidate digit runs with the boundary rules of the reference
  /// regex, applied in plain code (Dart RegExp has no lookbehind):
  /// `(?<![\d*/:.,،٫٬])(?<!\d[-\s])(?:\d{3}[-\s]\d{3}|\d{4,8})
  /// (?![\d*/:٫٬])(?![.,،]\d)(?![-\s]\d)`.
  ///
  /// Returns `(start, end)` pairs in UTF-16 code-unit offsets.
  static Iterable<(int, int)> _candidateMatches(String text) sync* {
    final digitRun = RegExp(r'\d{3}[-\s]\d{3}|\d{4,8}');
    for (final match in digitRun.allMatches(text)) {
      final start = match.start;
      final end = match.end;
      // (?<![\d*/:.,،٫٬]) — not glued to a digit, mask, date, time,
      // decimal or thousands separator on the left.
      if (start > 0) {
        final prev = text[start - 1];
        if (RegExp(r'[0-9*/:.,،٫٬]').hasMatch(prev)) continue;
      }
      // (?<!\d[-\s]) — the run must not continue a digit across a
      // separator (e.g. the second half of "1234-5678").
      if (start >= 2) {
        final before2 = text[start - 2];
        final before1 = text[start - 1];
        if (RegExp(r'[0-9]').hasMatch(before2) &&
            RegExp(r'[-\s]').hasMatch(before1)) {
          continue;
        }
      }
      // (?![\d*/:٫٬]) — not glued on the right.
      if (end < text.length) {
        final next = text[end];
        if (RegExp(r'[0-9*/:٫٬]').hasMatch(next)) continue;
      }
      // (?![.,،]\d) — not a decimal / grouped amount.
      if (end + 1 < text.length) {
        final next = text[end];
        final afterNext = text[end + 1];
        if (RegExp(r'[.,،]').hasMatch(next) &&
            RegExp(r'[0-9]').hasMatch(afterNext)) {
          continue;
        }
      }
      // (?![-\s]\d) — not the first half of a longer dashed number.
      if (end + 1 < text.length) {
        final next = text[end];
        final afterNext = text[end + 1];
        if (RegExp(r'[-\s]').hasMatch(next) &&
            RegExp(r'[0-9]').hasMatch(afterNext)) {
          continue;
        }
      }
      yield (start, end);
    }
  }
}

/// Normalises phone numbers for matching contacts to SMS / calls.
abstract final class PhoneNumber {
  static String digits(String value) => OtpExtractor.normalizeDigits(value)
      .replaceAll(RegExp(r'[^0-9+]'), '');

  /// Last 9 digits; good enough to match "+98912…" with "0912…".
  static String matchKey(String value) {
    final d = digits(value).replaceAll('+', '');
    return d.length <= 9 ? d : d.substring(d.length - 9);
  }
}
