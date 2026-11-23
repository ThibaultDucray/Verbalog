// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small text helpers that Python gets from its standard library: accent folding
// (unicodedata) and fuzzy matching (difflib).

const _accents = {
  'a': 'àâäáãåā',
  'c': 'çćč',
  'e': 'éèêëēę',
  'i': 'îïíìī',
  'n': 'ñń',
  'o': 'ôöóòõøō',
  'u': 'ùûüúū',
  'y': 'ÿý',
  's': 'šś',
  'z': 'žźż',
  'l': 'ł',
};

final Map<String, String> _foldMap = {
  for (final e in _accents.entries)
    for (final ch in e.value.split('')) ch: e.key,
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
};

/// Lowercase without accents: "Société" -> "societe".
String fold(String s) {
  final low = s.toLowerCase();
  final b = StringBuffer();
  for (final ch in low.split('')) {
    b.write(_foldMap[ch] ?? ch);
  }
  return b.toString().trim();
}

/// difflib.SequenceMatcher(None, a, b).ratio(): 2*M/T over matching blocks.
double similarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1.0;
  final total = a.length + b.length;
  return 2.0 * _matches(a, 0, a.length, b, 0, b.length) / total;
}

int _matches(String a, int alo, int ahi, String b, int blo, int bhi) {
  if (alo >= ahi || blo >= bhi) return 0;
  // Longest common substring, leftmost in a, then in b, like difflib.
  var bestI = alo, bestJ = blo, bestSize = 0;
  var prev = List<int>.filled(bhi - blo + 1, 0);
  for (var i = alo; i < ahi; i++) {
    final cur = List<int>.filled(bhi - blo + 1, 0);
    for (var j = blo; j < bhi; j++) {
      if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
        final k = prev[j - blo] + 1;
        cur[j - blo + 1] = k;
        if (k > bestSize) {
          bestI = i - k + 1;
          bestJ = j - k + 1;
          bestSize = k;
        }
      }
    }
    prev = cur;
  }
  if (bestSize == 0) return 0;
  return bestSize +
      _matches(a, alo, bestI, b, blo, bestJ) +
      _matches(a, bestI + bestSize, ahi, b, bestJ + bestSize, bhi);
}

/// difflib.get_close_matches.
List<String> closeMatches(String word, Iterable<String> possibilities, {int n = 3, double cutoff = 0.6}) {
  final scored = <(double, String)>[];
  for (final p in possibilities) {
    final s = similarity(word, p);
    if (s >= cutoff) scored.add((s, p));
  }
  scored.sort((x, y) {
    final c = y.$1.compareTo(x.$1);
    return c != 0 ? c : y.$2.compareTo(x.$2);
  });
  return [for (final s in scored.take(n)) s.$2];
}

String hms(double seconds) {
  final total = seconds.floor();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(total ~/ 3600)}:${two(total % 3600 ~/ 60)}:${two(total % 60)}';
}
