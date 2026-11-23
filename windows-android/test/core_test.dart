// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from Verbalog's Python tests, so both apps behave the same.

import 'package:flutter_test/flutter_test.dart';
import 'package:verbalog/core/export.dart';
import 'package:verbalog/core/merge.dart';
import 'package:verbalog/core/models.dart';
import 'package:verbalog/core/naming.dart';
import 'package:verbalog/core/notes.dart';
import 'package:verbalog/core/pseudonymize.dart';
import 'package:verbalog/core/text.dart';

const people = ['Sophie', 'Marc', 'Jim', 'Karim'];
Note parse(String raw, [List<String> expected = people]) => parseNote(1.0, raw, expected: expected);

void main() {
  group('notes', () {
    test('typed prefixes', () {
      expect(parse('! Envoyer la grille').type, 'action');
      expect(parse('! Envoyer la grille').text, 'Envoyer la grille');
      expect(parse('# Pilote sur 2 sites').type, 'decision');
      expect(parse('? Périmètre').type, 'question');
      expect(parse('~ pas très convaincu').type, 'private');
      expect(parse('texte libre').type, 'note');
      expect(parse('   ').type, 'bookmark');
    });

    test('shortcut corrects typos against expected', () {
      final n = parse('@jmi');
      expect([n.type, n.speaker, n.announce], ['speaker', 'Jim', false]);
      expect(parse('@Jim+').announce, isTrue);
    });

    test('natural language in every language', () {
      for (final raw in [
        "ici c'est Jim", 'ici c’est Jim', "C'est Jim qui parle", 'Jim parle', 'this is Jim', 'Jim speaking.',
        'hier ist Jim', 'Hier spricht Jim', 'hier is Jim', 'Jim spreekt', 'soy Jim', 'aquí habla Jim',
        'qui parla Jim', 'sono Jim', 'aqui fala Jim', 'sou Jim',
      ]) {
        final n = parse(raw);
        expect([n.type, n.speaker], ['speaker', 'Jim'], reason: raw);
      }
    });

    test('an unknown name in a pattern stays a note', () {
      final n = parse('le directeur financier parle');
      expect(n.type, 'note');
      expect(n.text, 'le directeur financier parle');
      expect(parse("ici c'est Jim", []).speaker, 'Jim');
    });

    test('matching handles accents and full names', () {
      expect(matchParticipant('helene', ['Hélène Dupont']), 'Hélène Dupont');
      expect(matchParticipant('zzz', people), isNull);
    });
  });

  group('difflib parity', () {
    test('ratio', () {
      expect(similarity('abcd', 'bcde'), closeTo(0.75, 1e-9));
      expect(similarity('jmi', 'jim'), closeTo(2 * 2 / 6, 1e-9));
    });
  });

  group('pseudonymize', () {
    const text = '''**[00:17:48] Sophie Martin :** Acme Europe veut signer, ACME aussi, avec la Société Générale.
Écrivez à jim@acme.com ou au 06 12 34 56 78, ou +33 1 42 68 53 00. Budget de 500 000 € et \$2.5M, soit 1,5 million d'euros.
Le marché avance ; la Societe Generale confirme.''';

    test('no sensitive term survives and the round trip restores', () {
      final engine = Pseudonymizer();
      final out = pseudonymizeText(
          text, engine, parseSensitive('CLIENT: Acme\nCLIENT: Acme Europe\nSociété Générale\n'), ['Sophie Martin']);
      for (final leak in [
        'Acme', 'ACME', 'acme', 'Société', 'Societe', 'Sophie', 'Martin', 'jim@', '06 12', '+33', '500 000', '2.5M', '1,5'
      ]) {
        expect(out.contains(leak), isFalse, reason: leak);
      }
      for (final alias in ['CLIENT_A', 'CLIENT_B', 'TERME_A', 'PERSONNE_1', 'EMAIL_1', 'TEL_1', 'MONTANT_1']) {
        expect(out.contains(alias), isTrue, reason: alias);
      }
      expect(out.contains('marché'), isTrue);
      expect(out.contains('[00:17:48]'), isTrue);
      final restored = engine.reidentify(out);
      expect(restored.contains('Acme Europe veut signer'), isTrue);
      expect(restored.contains('Sophie Martin'), isTrue);
      expect(restored.contains('06 12 34 56 78'), isTrue);
      expect(restored.contains('500 000 €'), isTrue);
    });

    test('names inside words are untouched', () {
      expect(Pseudonymizer().applyTerms('Le marché de Marc', [('PERSONNE', 'Marc')]), 'Le marché de PERSONNE_1');
    });

    test('long alias before its prefix', () {
      final e = Pseudonymizer({for (var i = 1; i < 12; i++) 'PERSONNE_$i': 'P$i'});
      expect(e.reidentify('PERSONNE_10 et PERSONNE_1'), 'P10 et P1');
    });

    test('transcription misspellings are caught', () {
      final e = Pseudonymizer();
      final out = e.applyNearMisses(
          'Chez Enedys avec Karime, et la marche avance enfin.', [('CLIENT', 'Enedis'), ('PERSONNE', 'Karim')]);
      expect(out, 'Chez CLIENT_A avec PERSONNE_1, et la marche avance enfin.');
      expect(e.reidentify(out).startsWith('Chez Enedis avec Karim'), isTrue);
    });

    test('sensitive file format', () {
      expect(parseSensitive('# comment\n\nCLIENT: Acme\nProjet Phoenix\n'), [('CLIENT', 'Acme'), ('TERME', 'Projet Phoenix')]);
    });

    test('term regex handles accents and spacing', () {
      expect(RegExp(termRegex("L'Oréal  France"), caseSensitive: false, unicode: true).hasMatch('chez l’oreal france'),
          isTrue);
    });
  });

  group('merge and naming', () {
    List<Segment> segs() => [
          Segment(0, 2, 'Bonjour à tous', 'fr', [Word(' Bonjour', 0, 0.8, 1, 'fr'), Word(' à tous', 0.8, 2, 1, 'fr')]),
          Segment(2.5, 4, 'Merci', 'fr', [Word(' Merci', 2.5, 4, 1, 'fr')]),
        ];

    test('words follow diarization turns', () {
      final turns = buildTurns(segs(), 'mic',
          speakerTurns: const [SpeakerTurn(0, 2.1, 'SALLE_1'), SpeakerTurn(2.4, 4.2, 'SALLE_2')]);
      expect(turns.map((t) => t.label), ['SALLE_1', 'SALLE_2']);
      expect(turns.first.text, 'Bonjour à tous');
    });

    test('a hint names the person speaking, a contradiction is reported', () {
      final turns = buildTurns(segs(), 'mic',
          speakerTurns: const [SpeakerTurn(0, 2.1, 'SALLE_1'), SpeakerTurn(2.4, 4.2, 'SALLE_2')]);
      final notes = [Note(1, 'speaker', speaker: 'Jim'), Note(1.5, 'speaker', speaker: 'Marc')];
      final (names, conflicts) = resolveHints(notes, turns, 5, {});
      expect(names, {'SALLE_1': 'Jim'});
      expect(conflicts.single.kind, 'contradiction');
      final announced = resolveHints([Note(2.2, 'speaker', speaker: 'Karim', announce: true)], turns, 5, {});
      expect(announced.$1, {'SALLE_2': 'Karim'});
    });

    test('placeholders, review merges and the Markdown export', () {
      final turns = buildTurns(segs(), 'mic',
          speakerTurns: const [SpeakerTurn(0, 2.1, 'SALLE_1'), SpeakerTurn(2.4, 4.2, 'SALLE_2')]);
      final doc = Transcript(
        sessionId: 'x',
        title: 'Point hebdo',
        date: '2026-11-23T10:00:00',
        duration: 4,
        context: 'presentiel',
        languages: ['fr'],
        speakers: summarizeSpeakers(turns, {}, 'presentiel'),
        turns: turns,
        notes: [Note(1, 'action', text: 'Envoyer la grille'), Note(3, 'private', text: 'secret')],
      );
      expect(doc.speakers['SALLE_2']!.display, 'Speaker 2');
      applyReview(doc, names: {'SALLE_1': 'Sophie'}, merges: [('SALLE_1', 'SALLE_2')]);
      final md = renderMarkdown(doc);
      expect(md.contains('**[00:00:00] Sophie:** Bonjour à tous'), isTrue);
      expect(md.contains('**[00:00:02] Sophie:** Merci'), isTrue);
      expect(md.contains('- ACTION [00:00:01] Envoyer la grille'), isTrue);
      expect(md.contains('secret'), isFalse);
    });
  });
}
