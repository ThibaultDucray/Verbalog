// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Words + speaker turns -> chronological speaking turns. Ported from Verbalog's merge.py.

import 'models.dart';

const newTurnPause = 2.0;
const nearestTurnTolerance = 1.0;

/// Speaker whose turn overlaps the word most; else the nearest turn close by; else the previous word's speaker.
String speakerForWord(Word word, List<SpeakerTurn> turns, String fallback) {
  String? best, nearest;
  var bestOverlap = 0.0, nearestGap = nearestTurnTolerance;
  for (final turn in turns) {
    final overlap = (word.end < turn.end ? word.end : turn.end) - (word.start > turn.start ? word.start : turn.start);
    if (overlap > bestOverlap) {
      best = turn.label;
      bestOverlap = overlap;
    }
    var gap = turn.start - word.end;
    if (word.start - turn.end > gap) gap = word.start - turn.end;
    if (gap < 0) gap = 0;
    if (gap < nearestGap) {
      nearest = turn.label;
      nearestGap = gap;
    }
  }
  return best ?? nearest ?? fallback;
}

/// Group a track's words. Pass `label` for a track with one known speaker, or
/// `speakerTurns` to attribute each word from diarization.
List<Turn> buildTurns(List<Segment> segments, String track, {List<SpeakerTurn>? speakerTurns, String? label}) {
  final turns = <Turn>[];
  var currentLabel = label ?? (speakerTurns != null && speakerTurns.isNotEmpty ? speakerTurns.first.label : 'INCONNU');
  Turn? current;
  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
  for (final segment in sorted) {
    final words = segment.words.isNotEmpty
        ? segment.words
        : [Word(segment.text, segment.start, segment.end, 1.0, segment.lang)];
    for (final word in words) {
      if (label == null && speakerTurns != null && speakerTurns.isNotEmpty) {
        currentLabel = speakerForWord(word, speakerTurns, currentLabel);
      }
      if (current == null || current.label != currentLabel || word.start - current.end > newTurnPause) {
        current = Turn(start: word.start, end: word.end, label: currentLabel, track: track);
        turns.add(current);
      }
      if (word.end > current.end) current.end = word.end;
      current.words.add(word);
    }
  }
  for (final turn in turns) {
    finishTurn(turn);
  }
  return turns.where((t) => t.text.isNotEmpty).toList();
}

/// Derive a turn's text and statistics from its words.
void finishTurn(Turn turn) {
  final b = StringBuffer();
  for (final w in turn.words) {
    // Whisper words carry their leading space; segment-level text doesn't.
    if (b.isNotEmpty && !w.text.startsWith(' ')) b.write(' ');
    b.write(w.text);
  }
  turn.text = b.toString().trim();
  turn.start = r3(turn.start);
  turn.end = r3(turn.end);
  final langs = <String, int>{};
  for (final w in turn.words) {
    if (w.lang.isNotEmpty) langs[w.lang] = (langs[w.lang] ?? 0) + 1;
  }
  turn.lang = langs.isEmpty ? '' : (langs.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  turn.confidence =
      turn.words.isEmpty ? 0 : r3(turn.words.map((w) => w.confidence).reduce((a, b) => a + b) / turn.words.length);
}

/// Overlapping speech from different tracks stays, ordered by start of speech.
List<Turn> mergeTracks(List<List<Turn>> tracks) {
  final merged = [for (final t in tracks) ...t];
  merged.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.end.compareTo(b.end);
  });
  return merged;
}

/// Index of the turn each note follows (-1 = before the first). A note goes at
/// the end of the turn in progress at its timestamp, never mid-sentence.
List<int> notePositions(List<Turn> turns, List<double> noteTimes) => [
      for (final t in noteTimes)
        () {
          var index = -1;
          for (var i = 0; i < turns.length; i++) {
            if (turns[i].start <= t) {
              index = i;
            } else {
              break;
            }
          }
          return index;
        }()
    ];
