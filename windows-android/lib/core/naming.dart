// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Attach names to speaker labels. Priority: live hints, then the review screen.
// Unnamed speakers get a numbered placeholder. Ported from Verbalog's naming.py.

import 'i18n.dart';
import 'models.dart';

const ambiguousDb = 3.0;
const _origins = {'SALLE': 'salle', 'DISTANT': 'distant', 'MOI': 'moi'};

String originOf(String label) => _origins[label.split('_').first] ?? '';

/// Latest speaker at t on each track; if nobody speaks, whoever spoke in the last `lookback` seconds.
List<Turn> _activeAt(List<Turn> turns, double t, double lookback) {
  final active = <String, Turn>{};
  for (final turn in turns) {
    if (turn.start <= t && t <= turn.end) active[turn.track] = turn;
  }
  if (active.isNotEmpty) return active.values.toList();
  final recent = turns.where((turn) => t - lookback <= turn.end && turn.end < t).toList();
  if (recent.isEmpty) return [];
  recent.sort((a, b) => b.end.compareTo(a.end));
  return [recent.first];
}

typedef TrackEnergy = double Function(String track, double at);

/// Returns (label -> name, conflicts). `fixedLabels` are speakers whose identity
/// is already certain, such as the user's own track in a video call.
(Map<String, String>, List<Conflict>) resolveHints(
  List<Note> notes,
  List<Turn> turns,
  double lookback,
  Set<String> fixedLabels, [
  TrackEnergy? trackEnergy,
]) {
  final assigned = <String, String>{};
  final conflicts = <Conflict>[];
  final candidates = turns.where((t) => !fixedLabels.contains(t.label)).toList();

  for (final note in notes) {
    if (note.type != 'speaker' || note.speaker == null) continue;
    Turn? chosen;
    if (note.announce) {
      final upcoming = candidates.where((t) => t.start > note.t).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      chosen = upcoming.isEmpty ? null : upcoming.first;
    } else {
      final active = _activeAt(candidates, note.t, lookback);
      chosen = active.isEmpty ? null : active.first;
      if (active.length > 1 && trackEnergy != null) {
        // Voices on both tracks: the louder one wins, unless too close to call.
        final ranked = [...active]
          ..sort((a, b) => trackEnergy(b.track, note.t).compareTo(trackEnergy(a.track, note.t)));
        chosen = ranked.first;
        final gap = trackEnergy(ranked[0].track, note.t) - trackEnergy(ranked[1].track, note.t);
        if (gap < ambiguousDb) {
          conflicts.add(Conflict('ambiguous', note.t, note.speaker!, [for (final t in ranked) t.label]));
          continue;
        }
      }
    }
    if (chosen == null) {
      conflicts.add(Conflict('no_speaker', note.t, note.speaker!, []));
      continue;
    }
    final previous = assigned[chosen.label];
    if (previous != null && previous != note.speaker) {
      conflicts.add(Conflict('contradiction', note.t, note.speaker!, [chosen.label], previous));
    } else {
      assigned[chosen.label] = note.speaker!;
    }
  }
  return (assigned, conflicts);
}

/// Build the speakers table. `names`: label -> (name, source).
Map<String, Speaker> summarizeSpeakers(List<Turn> turns, Map<String, (String, String)> names, String mode) {
  final speakers = <String, Speaker>{};
  final byLabel = <String, List<Turn>>{};
  for (final turn in turns) {
    final s = speakers.putIfAbsent(turn.label, () => Speaker(track: turn.track, origin: originOf(turn.label)));
    s.talkSeconds += turn.end - turn.start;
    byLabel.putIfAbsent(turn.label, () => []).add(turn);
  }
  final counters = <String, int>{};
  for (final e in speakers.entries) {
    final s = e.value;
    final named = names[e.key];
    s.name = named?.$1;
    s.source = named?.$2;
    if (s.name == null || s.name!.isEmpty) {
      final origin = mode == 'hybride' ? s.origin : '';
      counters[origin] = (counters[origin] ?? 0) + 1;
      final placeholder = {'salle': 'Room speaker {n}', 'distant': 'Remote speaker {n}'}[origin] ?? 'Speaker {n}';
      s.display = t(placeholder, {'n': counters[origin]});
    } else {
      s.display = s.name!;
    }
    final longest = [...byLabel[e.key]!]..sort((a, b) => b.text.length.compareTo(a.text.length));
    final top = longest.take(3).toList()..sort((a, b) => a.start.compareTo(b.start));
    s.samples = [
      for (final t in top) Sample(t.start, t.end, t.track, t.text.length > 200 ? t.text.substring(0, 200) : t.text)
    ];
    s.talkSeconds = (s.talkSeconds * 10).roundToDouble() / 10;
  }
  return speakers;
}

/// Recompute the speakers table from the turns, keeping the names already given.
void rebuildSpeakers(Transcript doc) {
  final names = <String, (String, String)>{
    for (final e in doc.speakers.entries)
      if (e.value.name != null && e.value.name!.isNotEmpty) e.key: (e.value.name!, e.value.source ?? 'review')
  };
  doc.speakers = summarizeSpeakers(doc.turns, names, doc.context);
  doc.needsReview = false;
}

/// Merges are [keep, absorbed] pairs: diarization split one person into two labels.
void applyReview(Transcript doc, {Map<String, String>? names, List<(String, String)> merges = const []}) {
  names = names == null ? null : Map.of(names);
  for (final (keep, absorbed) in merges) {
    if (keep == absorbed || !doc.speakers.containsKey(keep) || !doc.speakers.containsKey(absorbed)) continue;
    final kept = doc.speakers[keep]!;
    final gone = doc.speakers.remove(absorbed)!;
    if ((kept.name == null || kept.name!.isEmpty) && gone.name != null) {
      kept.name = gone.name;
      kept.source = gone.source;
    }
    for (final turn in doc.turns) {
      if (turn.label == absorbed) turn.label = keep;
    }
    if (names != null && names.containsKey(absorbed)) names.putIfAbsent(keep, () => names![absorbed]!);
  }
  names?.forEach((label, name) {
    if (doc.speakers.containsKey(label) && name.trim().isNotEmpty) {
      doc.speakers[label]!
        ..name = name.trim()
        ..source = 'review';
    }
  });
  doc.conflicts = [];
  rebuildSpeakers(doc);
}
