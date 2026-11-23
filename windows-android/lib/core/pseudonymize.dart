// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replace sensitive terms before any text leaves the device. The alias table stays
// next to the meeting and is never sent; it's reused so that CLIENT_A stays the same
// client across previews and re-sends. Ported from Verbalog's pseudonymize.py
// (without the spaCy entity detection, which has no light on-device equivalent).

import 'text.dart';

const _accents = {
  'a': 'aàâäáã',
  'c': 'cç',
  'e': 'eéèêë',
  'i': 'iîïíì',
  'n': 'nñ',
  'o': 'oôöóòõ',
  'u': 'uùûüú',
  'y': 'yÿ',
};
final _fold = {
  for (final e in _accents.entries)
    for (final ch in e.value.split('')) ch: e.key
};
const lettered = {'CLIENT', 'PROJET', 'TERME'};
const nearMissMinLength = 5;
const nearMissRatio = 0.8;

// Python's \w is Unicode-aware; Dart's isn't, even in unicode mode.
const _notW = r'(?<![\p{L}\p{N}_])';
const _notWAfter = r'(?![\p{L}\p{N}_])';

final email = RegExp(r'[\p{L}\p{N}_.+-]+@[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)+', unicode: true);
final phone = RegExp(
    r'(?<![\p{L}\p{N}_:])(?:\+\d{1,3}[ .\- ]?(?:\(0\)[ .\- ]?)?\d(?:[ .\- ]?\d){6,12}|0\d(?:[ .\- ]?\d{2}){4})(?![\p{L}\p{N}_:])',
    unicode: true);
const _num = r'\d(?:[\d   .,]*\d)?';
final amount = RegExp(
  '(?:[\$€£] ?$_num(?: ?(?:k|K|M|Md|millions?|milliards?)(?![\\p{L}\\p{N}_]))?)'
  "|(?:(?<![\\p{L}\\p{N}_:])$_num ?(?:(?:k|K|M|Md|millions?(?: d[e'] ?)?|milliards?(?: d[e'] ?)?) ?)?(?:€|\\\$|£|(?:euros?|dollars?|EUR|USD|GBP)(?![\\p{L}\\p{N}_])))",
  unicode: true,
);

/// Case- and accent-insensitive whole-term pattern: "Société Générale" also catches "SOCIETE GENERALE".
String termRegex(String term) {
  final parts = StringBuffer();
  var lastWasSpace = false;
  for (final ch in term.trim().split('')) {
    final base = _fold[ch.toLowerCase()];
    if (ch.trim().isEmpty) {
      if (!lastWasSpace) parts.write(r'\s+');
      lastWasSpace = true;
      continue;
    }
    lastWasSpace = false;
    if (ch == "'" || ch == '’') {
      parts.write("['’]");
    } else if (base != null) {
      parts.write('[${_accents[base]}]');
    } else {
      parts.write(RegExp.escape(ch));
    }
  }
  return '$_notW$parts$_notWAfter';
}

String _folded(String term) => term.toLowerCase().split('').map((c) => _fold[c] ?? c).join().trim();

/// Lines are `Term` or `CATEGORY: Term`, e.g. `CLIENT: Acme`, `PERSONNE: Jim`.
List<(String, String)> parseSensitive(String text) {
  final terms = <(String, String)>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf(':');
    if (i > 0) {
      final category = line.substring(0, i).trim();
      final term = line.substring(i + 1).trim();
      if (RegExp(r'^[A-Za-zÀ-ÿ_]+$').hasMatch(category) && term.isNotEmpty) {
        terms.add((category.toUpperCase(), term));
        continue;
      }
    }
    terms.add(('TERME', line));
  }
  return terms;
}

class Pseudonymizer {
  Pseudonymizer([Map<String, String>? mapping]) : mapping = Map.of(mapping ?? {}) {
    _byTerm.addAll({for (final e in this.mapping.entries) _folded(e.value): e.key});
  }

  final Map<String, String> mapping; // alias -> original
  final Map<String, String> _byTerm = {};

  String _alias(String category, String original) {
    final key = _folded(original);
    final existing = _byTerm[key];
    if (existing != null) return existing;
    final count = mapping.keys.where((a) => a.startsWith('${category}_')).length;
    String suffix;
    if (lettered.contains(category)) {
      var n = count;
      suffix = '';
      while (true) {
        suffix = String.fromCharCode(65 + n % 26) + suffix;
        n = n ~/ 26 - 1;
        if (n < 0) break;
      }
    } else {
      suffix = '${count + 1}';
    }
    final alias = '${category}_$suffix';
    mapping[alias] = original;
    _byTerm[key] = alias;
    return alias;
  }

  String applyTerms(String text, Iterable<(String, String)> terms) {
    // Longest first, so "Acme Europe" isn't half-replaced by the rule for "Acme".
    final unique = terms.toSet().toList()..sort((a, b) => b.$2.length.compareTo(a.$2.length));
    for (final (category, term) in unique) {
      if (term.trim().isEmpty) continue;
      text = text.replaceAllMapped(
          RegExp(termRegex(term), caseSensitive: false, unicode: true), (_) => _alias(category, term));
    }
    return text;
  }

  /// Whisper misspells proper nouns, and a misspelled client name is still that client.
  /// Over-replacing a rare word costs little; the preview shows it, and leaking costs more.
  String applyNearMisses(String text, Iterable<(String, String)> terms) {
    final singles = [
      for (final (c, t) in terms.toSet())
        if (t.trim().length >= nearMissMinLength && !t.trim().contains(' ')) (c, t.trim(), _folded(t))
    ];
    if (singles.isEmpty) return text;
    final replacements = <String, String>{};
    final words = RegExp("(?<![\\p{L}\\p{N}_'’])\\p{L}{$nearMissMinLength,}$_notWAfter", unicode: true)
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toSet();
    for (final word in words) {
      final folded = _folded(word);
      var best = singles.first;
      var ratio = -1.0;
      for (final s in singles) {
        final r = similarity(folded, s.$3);
        if (r > ratio) {
          ratio = r;
          best = s;
        }
      }
      if (ratio >= nearMissRatio && folded[0] == best.$3[0]) replacements[word] = _alias(best.$1, best.$2);
    }
    replacements.forEach((word, alias) {
      text = text.replaceAll(RegExp('$_notW${RegExp.escape(word)}$_notWAfter', unicode: true), alias);
    });
    return text;
  }

  String applyPatterns(String text) {
    for (final (category, pattern) in [('EMAIL', email), ('TEL', phone), ('MONTANT', amount)]) {
      text = text.replaceAllMapped(pattern, (m) => _alias(category, m.group(0)!.trim()));
    }
    return text;
  }

  String reidentify(String text) {
    if (mapping.isEmpty) return text;
    // The alternation tries longest first, so PERSONNE_10 can't match as PERSONNE_1.
    final aliases = mapping.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    final pattern = aliases.map(RegExp.escape).join('|');
    return text.replaceAllMapped(
        RegExp('$_notW(?:$pattern)$_notWAfter', unicode: true), (m) => mapping[m.group(0)!]!);
  }
}

const _placeholderPrefixes = ['Intervenant', 'Speaker', 'Room speaker', 'Remote speaker'];

/// Returns the pseudonymized text; `pseudonymizer.mapping` is updated in place.
String pseudonymizeText(String text, Pseudonymizer engine, List<(String, String)> sensitive, Iterable<String> participants) {
  final people = <(String, String)>[];
  for (var person in participants) {
    person = person.trim();
    if (person.isEmpty || _placeholderPrefixes.any(person.startsWith)) continue;
    people.add(('PERSONNE', person));
    // Full name first, then its parts, so "Sophie" alone is caught too.
    for (final part in person.split(RegExp(r'\s+'))) {
      if (part.length >= 3) people.add(('PERSONNE', part));
    }
  }
  var result = engine.applyTerms(text, [...sensitive, ...people]);
  result = engine.applyNearMisses(result, [...sensitive, ...people]);
  result = engine.applyPatterns(result);
  return result;
}
