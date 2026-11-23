// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Markdown meant for reading and for the LLM. Ported from Verbalog's export.py.

import 'dart:convert';

import 'i18n.dart';
import 'merge.dart';
import 'models.dart';
import 'notes.dart';
import 'text.dart';

String _yamlStr(String value, {bool inFlow = false}) {
  // JSON strings are valid YAML; quote only when a bare value would be misread.
  final specials = ':#[]{}&*!|>\'"%@`\n${inFlow ? ',' : ''}';
  if (value.isEmpty || value.split('').any(specials.contains) || value != value.trim()) {
    return jsonEncode(value);
  }
  return value;
}

List<String> _participants(Transcript doc, String userName) {
  final lines = <String>[];
  for (final s in doc.speakers.values) {
    final details = <String>[];
    if (userName.isNotEmpty && s.display == userName) details.add(t('organizer'));
    // An imported file is one mixed track: nobody is "in the room" or "remote" there.
    if ((s.origin == 'salle' || s.origin == 'distant') && !doc.imported) {
      details.add(t(s.origin == 'salle' ? 'room' : 'remote'));
    }
    if (s.name == null || s.name!.isEmpty) details.add(t('unidentified'));
    lines.add(s.display + (details.isNotEmpty ? ' (${details.join(', ')})' : ''));
  }
  return lines.toSet().toList();
}

String _noteBlock(Note n) {
  final head = '> **${t(exportLabels[n.type]!)} [${hms(n.t)}]**';
  return n.text.isNotEmpty ? '$head ${n.text}' : head;
}

String renderMarkdown(Transcript doc, {String userName = ''}) {
  final lines = <String>[
    '---',
    'title: ${_yamlStr(doc.title)}',
    'date: ${doc.date}',
    'duration: ${hms(doc.duration)}',
    'context: ${doc.imported ? 'import' : doc.context}',
    'languages: [${doc.languages.join(', ')}]',
  ];
  final participants = _participants(doc, userName);
  if (participants.isNotEmpty) {
    lines.add('participants:');
    lines.addAll(participants.map((p) => '  - ${_yamlStr(p)}'));
  }
  if (doc.expectedParticipants.isNotEmpty) {
    lines.add('expected_participants: [${doc.expectedParticipants.map((p) => _yamlStr(p, inFlow: true)).join(', ')}]');
  }
  if (doc.glossary.isNotEmpty) {
    lines.add('glossary: [${doc.glossary.map((g) => _yamlStr(g, inFlow: true)).join(', ')}]');
  }
  lines.addAll(['---', '', '# ${doc.title}', '']);

  // Private notes stop here: they exist only in the JSON, which is never sent anywhere.
  final notes = doc.notes.where((n) => exportLabels.containsKey(n.type)).toList();
  final summary = notes.where((n) => const {'action', 'decision', 'question'}.contains(n.type)).toList();
  if (summary.isNotEmpty) {
    lines.add('## ${t('Organizer notes (summary)')}');
    lines.addAll(summary.map((n) => '- ${t(exportLabels[n.type]!)} [${hms(n.t)}] ${n.text}'));
    lines.add('');
  }

  lines.addAll(['## ${t('Transcript')}', '']);
  final colon = appLanguage == 'fr' ? ' :' : ':'; // French typography
  final positions = notePositions(doc.turns, notes.map((n) => n.t).toList());
  final after = <int, List<Note>>{};
  for (var i = 0; i < notes.length; i++) {
    after.putIfAbsent(positions[i], () => []).add(notes[i]);
  }
  for (final n in after[-1] ?? const <Note>[]) {
    lines.addAll([_noteBlock(n), '']);
  }
  for (var i = 0; i < doc.turns.length; i++) {
    final turn = doc.turns[i];
    final speaker = doc.speakers[turn.label]?.display ?? turn.label;
    lines.addAll(['**[${hms(turn.start)}] $speaker$colon** ${turn.text}', '']);
    for (final n in after[i] ?? const <Note>[]) {
      lines.addAll([_noteBlock(n), '']);
    }
  }
  return '${lines.join('\n').trimRight()}\n';
}
