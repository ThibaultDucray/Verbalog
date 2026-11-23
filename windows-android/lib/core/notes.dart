// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed note prefixes, live speaker naming hints, and participant name matching.
// Ported from Verbalog's notes.py.

import 'models.dart';
import 'text.dart';

const prefixes = {'!': 'action', '#': 'decision', '?': 'question', '~': 'private'};
const exportLabels = {
  'note': 'NOTE',
  'action': 'ACTION',
  'decision': 'DECISION',
  'question': 'QUESTION',
  'bookmark': 'BOOKMARK',
};

const defaultNamingPatterns = [
  "ici c'est {nom}",
  "c'est {nom} qui parle",
  '{nom} parle',
  'this is {nom}',
  '{nom} speaking',
  'hier ist {nom}',
  'hier spricht {nom}',
  'hier is {nom}',
  '{nom} spreekt',
  'soy {nom}',
  'aquí habla {nom}',
  'qui parla {nom}',
  'sono {nom}',
  'aqui fala {nom}',
  'sou {nom}',
];

/// Closest expected participant, tolerating typos ("jmi" -> "Jim") and first-name-only input.
String? matchParticipant(String name, List<String> expected) {
  final folded = {for (final p in expected) fold(p): p};
  final target = fold(name);
  if (folded.containsKey(target)) return folded[target];
  for (final e in folded.entries) {
    if (target.isNotEmpty && e.key.split(RegExp(r'\s+')).contains(target)) return e.value;
  }
  final close = closeMatches(target, folded.keys, n: 1);
  if (close.isNotEmpty) return folded[close.first];
  // Compare against first names too, for a typo on "Sophie" when "Sophie Martin" is expected.
  final firsts = {
    for (final e in folded.entries)
      if (e.key.isNotEmpty) e.key.split(RegExp(r'\s+')).first: e.value
  };
  final closeFirst = closeMatches(target, firsts.keys, n: 1);
  return closeFirst.isNotEmpty ? firsts[closeFirst.first] : null;
}

const _nameGroup = r"(?<nom>\p{L}[\p{L}\p{M}0-9_'\- ]{0,39})";

List<RegExp> _patternRegexes(List<String> patterns) => [
      for (final p in patterns)
        RegExp(
          '^${RegExp.escape(p.replaceAll('’', "'")).replaceAll(r'\{nom\}', '{nom}').replaceAll('{nom}', _nameGroup)}[.!]?\$',
          caseSensitive: false,
          unicode: true,
        )
    ];

Note parseNote(double t, String raw, {List<String> patterns = defaultNamingPatterns, List<String> expected = const []}) {
  final text = raw.trim();
  if (text.isEmpty) return Note(t, 'bookmark');

  if (text.startsWith('@')) {
    var name = text.substring(1).trim();
    final announce = name.endsWith('+');
    name = name.replaceAll(RegExp(r'\+$'), '').trim();
    if (name.isNotEmpty) {
      return Note(t, 'speaker', speaker: matchParticipant(name, expected) ?? name, announce: announce);
    }
  }

  final first = text[0];
  if (prefixes.containsKey(first)) return Note(t, prefixes[first]!, text: text.substring(1).trim());

  final normalized = text.replaceAll('’', "'");
  for (final regex in _patternRegexes(patterns)) {
    final m = regex.firstMatch(normalized);
    if (m == null) continue;
    final name = m.namedGroup('nom')!.trim();
    final known = matchParticipant(name, expected);
    // "le client parle" fits "{nom} parle": with a participant list, an unknown
    // name means an ordinary note, and a note must never be silently consumed.
    if (known != null || expected.isEmpty) return Note(t, 'speaker', speaker: known ?? name);
  }
  return Note(t, 'note', text: text);
}

/// Raw notes as typed during the meeting: (seconds since start, text).
class RawNote {
  RawNote(this.t, this.text);
  final double t;
  final String text;
  Map<String, dynamic> toJson() => {'t': t, 'text': text};
  factory RawNote.fromJson(Map<String, dynamic> j) => RawNote((j['t'] as num).toDouble(), j['text'] as String? ?? '');
}

List<Note> parseNotes(List<RawNote> raw, {List<String> patterns = defaultNamingPatterns, List<String> expected = const []}) {
  final notes = [for (final r in raw) parseNote(r.t, r.text, patterns: patterns, expected: expected)];
  notes.sort((a, b) => a.t.compareTo(b.t));
  return notes;
}
