// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orchestration: transcribe and separate speakers of a recorded meeting, merge the
// tracks, apply naming hints from the notes. Ported from Verbalog's pipeline.py and
// transcribe.py. The speech engine is injected, so this file is pure Dart and testable.

import 'dart:io';
import 'dart:typed_data';

import 'audio.dart' as au;
import 'i18n.dart';
import 'merge.dart' as merge;
import 'models.dart';
import 'naming.dart' as naming;
import 'notes.dart';
import 'session.dart';
import 'text.dart';

typedef Progress = void Function(double fraction);
typedef Emit = void Function(String label, double fraction);

abstract class Transcriber {
  /// Transcribe each region; segment times are absolute in `audio`.
  List<Segment> transcribeRegions(Float32List audio, List<au.Region> regions, {Progress? progress});
}

abstract class Diarizer {
  /// Speaker turns with raw labels (any string), sorted by start.
  List<SpeakerTurn> diarize(Float32List audio, {int? numSpeakers, Progress? progress});
}

const supportedLanguages = ['fr', 'en', 'de', 'nl', 'es', 'it', 'pt'];
const defaultLanguages = ['fr', 'en'];

/// The languages ticked for a meeting, among the supported ones; French and English if none.
List<String> meetingLanguages(List<String>? chosen) {
  final out = supportedLanguages.where((c) => chosen?.contains(c) ?? false).toList();
  return out.isEmpty ? defaultLanguages : out;
}

// Stock phrases Whisper invents on silence or music: they come from its subtitle training data.
const hallucinations = [
  'sous-titres realises par',
  'sous-titrage',
  'amara.org',
  "merci d'avoir regarde",
  'thanks for watching',
  'thank you for watching',
  'subtitles by',
  'untertitel im auftrag',
  'untertitelung',
  'vielen dank furs zuschauen',
  'ondertiteld door',
  'ondertiteling',
  'bedankt voor het kijken',
  'subtitulos realizados por',
  'subtitulado por',
  'gracias por ver el video',
  'sottotitoli creati dalla comunita',
  'sottotitoli a cura di',
  'grazie per la visione',
  'legendas pela comunidade',
  'legendas por',
  'obrigado por assistir',
];

String _normalize(String text) => fold(text).replaceAll('’', "'").replaceAll(RegExp(r'\s+'), ' ').trim();

double compressionRatio(String text) {
  final bytes = text.codeUnits;
  if (bytes.isEmpty) return 0;
  return bytes.length / zlib.encode(bytes).length;
}

bool isHallucination(String text) {
  final n = _normalize(text);
  if (n.isEmpty) return true;
  if (hallucinations.any(n.contains)) return true;
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(n)) return true; // "...": nothing understood
  return n.length > 40 && compressionRatio(n) > 2.6; // repetition loop
}

/// Speaker turns to transcription chunks: join same-speaker neighbours, absorb
/// fragments too short for language detection, split anything over Whisper's window.
List<au.Region> regionsFromTurns(Float32List audio, List<SpeakerTurn> turns) {
  final joined = <(double, double, String)>[];
  final sorted = [...turns]..sort((a, b) => a.start.compareTo(b.start));
  for (final turn in sorted) {
    if (joined.isNotEmpty &&
        ((turn.label == joined.last.$3 && turn.start - joined.last.$2 < 0.5) ||
            (turn.end - turn.start < 0.6 && turn.start - joined.last.$2 < 0.5))) {
      final last = joined.removeLast();
      joined.add((last.$1, turn.end > last.$2 ? turn.end : last.$2, last.$3));
    } else {
      joined.add((turn.start, turn.end, turn.label));
    }
  }
  final regions = [for (final j in joined) (j.$1, j.$2)];
  // Diarization can mark clear speech as silence: energy VAD recovers what it missed.
  final all = [...regions, ..._uncovered(au.energyVad(audio), regions)]..sort((a, b) => a.$1.compareTo(b.$1));
  return regionsFromVad(audio, all);
}

List<au.Region> _uncovered(List<au.Region> candidates, List<au.Region> covered, {double minLen = 1.0}) {
  final out = <au.Region>[];
  final cov = [...covered]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (start, end) in candidates) {
    var cursor = start;
    for (final (cs, ce) in cov) {
      if (ce <= cursor || cs >= end) continue;
      if (cs - cursor >= minLen) out.add((cursor, cs));
      if (ce > cursor) cursor = ce;
    }
    if (end - cursor >= minLen) out.add((cursor, end));
  }
  return out;
}

List<au.Region> regionsFromVad(Float32List audio, List<au.Region> regions, {double pad = 0.1}) {
  final total = au.duration(audio);
  return [
    for (final (s, e) in regions)
      ...au.splitLongRegion(audio, (s - pad).clamp(0.0, total), (e + pad).clamp(0.0, total)),
  ];
}

/// Raw diarization labels -> SALLE_1 / DISTANT_1, numbered by first appearance.
List<SpeakerTurn> relabel(List<SpeakerTurn> turns, String prefix) {
  final mapping = <String, String>{};
  return [
    for (final t in turns) SpeakerTurn(t.start, t.end, mapping.putIfAbsent(t.label, () => '${prefix}_${mapping.length + 1}')),
  ];
}

/// On a call, your own voice is only on the mic. A mic that heard almost nothing for a
/// whole meeting usually means the call app took the headset away.
bool micNearlySilent(Float32List audio, String mode) {
  if (mode == 'presentiel') return false;
  final d = au.duration(audio);
  if (d < 120) return false;
  final voiced = au.energyVad(audio).fold(0.0, (s, r) => s + r.$2 - r.$1);
  return voiced < (0.01 * d > 5.0 ? 0.01 * d : 5.0);
}

Float32List? _readTrack(String path) {
  final f = File(path);
  if (!f.existsSync() || f.lengthSync() <= au.headerSize) return null;
  return au.readWav(path);
}

class Stages {
  Stages(this.emit, this.plan) : total = plan.fold(0.0, (s, p) => s + p.$3);
  final Emit emit;
  final List<(String, String, double)> plan;
  final double total;
  double done = 0;

  Progress run(String stage) {
    final (_, label, weight) = plan.firstWhere((p) => p.$1 == stage);
    final base = done;
    emit(label, base / total);
    done += weight;
    return (f) => emit(label, (base + weight * (f > 1 ? 1 : f)) / total);
  }
}

class PipelineOptions {
  const PipelineOptions({this.userName = '', this.lookbackSeconds = 5, this.glossary = const []});
  final String userName;
  final double lookbackSeconds;
  final List<String> glossary;
}

/// Process a recorded meeting into a transcript. Runs in a background isolate.
Transcript process(Meeting m, Transcriber transcriber, Diarizer? diarizer,
    {PipelineOptions options = const PipelineOptions(), Emit? emit}) {
  emit ??= (_, _) {};
  final mode = m.mode;
  final warnings = <String>[];
  final userName = options.userName.isNotEmpty ? options.userName : t('Me');

  final mic = _readTrack(m.micPath);
  final system = mode == 'presentiel' ? null : _readTrack(m.systemPath);
  if (mic == null && system == null) throw StateError(t('No audio to process: it was deleted or never recorded.'));
  if (mic == null) warnings.add(t('Mic track missing or empty.'));
  final micSilent = mic != null && micNearlySilent(mic, mode);
  if (micSilent) {
    warnings.add(t(
        'Your microphone recorded almost no speech. If you spoke during this meeting, your voice is missing from the transcript: the audio is kept so you can check.'));
  }
  if (system == null && mode != 'presentiel') warnings.add(t('Call audio track missing or empty.'));

  final plan = <(String, String, double)>[];
  if (system != null) {
    plan.addAll([
      ('diarize_system', t('Remote participants diarization'), 2),
      ('transcribe_system', t('Remote participants transcription'), 5),
    ]);
  }
  if (mic != null) {
    plan.add(('transcribe_mic', t('Mic transcription'), 5));
    if (mode != 'visio') plan.add(('diarize_mic', t('Room diarization'), 2));
  }
  plan.add(('merge', t('Merging and naming'), 1));
  final stages = Stages(emit, plan);

  List<SpeakerTurn>? safeDiarize(Float32List audio, int? count, String prefix, Progress progress) {
    if (diarizer == null) return null;
    try {
      return relabel(diarizer.diarize(audio, numSpeakers: count, progress: progress), prefix);
    } catch (e) {
      // the transcript is still worth having without speaker separation
      warnings.add(t("Diarization unavailable, voices on this track aren't separated: {error}", {'error': e}));
      return null;
    }
  }

  final tracks = <List<Turn>>[];
  if (system != null) {
    final turns = safeDiarize(system, m.remoteCount, 'DISTANT', stages.run('diarize_system'));
    final regions = (turns != null && turns.isNotEmpty)
        ? regionsFromTurns(system, turns)
        : regionsFromVad(system, au.energyVad(system));
    final segments = transcriber.transcribeRegions(system, regions, progress: stages.run('transcribe_system'));
    tracks.add(turns != null && turns.isNotEmpty
        ? merge.buildTurns(segments, 'system', speakerTurns: turns)
        : merge.buildTurns(segments, 'system', label: 'DISTANT_1'));
  }

  final fixed = <String>{};
  if (mic != null) {
    List<SpeakerTurn>? roomTurns;
    late List<Segment> micSegments;
    if (mode == 'presentiel' || mode == 'hybride') {
      roomTurns = safeDiarize(mic, m.roomCount, 'SALLE', stages.run('diarize_mic'));
      final regions = (roomTurns != null && roomTurns.isNotEmpty)
          ? regionsFromTurns(mic, roomTurns)
          : regionsFromVad(mic, au.energyVad(mic));
      micSegments = transcriber.transcribeRegions(mic, regions, progress: stages.run('transcribe_mic'));
    } else {
      micSegments = transcriber.transcribeRegions(mic, regionsFromVad(mic, au.energyVad(mic)),
          progress: stages.run('transcribe_mic'));
    }
    if (mode == 'visio') {
      tracks.add(merge.buildTurns(micSegments, 'mic', label: 'MOI'));
      fixed.add('MOI');
    } else if (roomTurns != null && roomTurns.isNotEmpty) {
      tracks.add(merge.buildTurns(micSegments, 'mic', speakerTurns: roomTurns));
    } else {
      tracks.add(merge.buildTurns(micSegments, 'mic', label: 'SALLE_1'));
    }
  }

  stages.run('merge');
  final turns = merge.mergeTracks(tracks);
  final notes = parseNotes(m.rawNotes(), expected: m.participants);

  double trackEnergy(String track, double at) {
    final audio = track == 'mic' ? mic : system;
    return audio == null ? -120.0 : au.rmsDb(au.sliceSeconds(audio, at - 1, at + 1));
  }

  final (hints, conflicts) = naming.resolveHints(notes, turns, options.lookbackSeconds, fixed, trackEnergy);
  // Priority: live hints win over the review screen.
  final names = <String, (String, String)>{if (fixed.contains('MOI')) 'MOI': (userName, 'user')};
  hints.forEach((label, name) => names[label] = (name, 'hint'));

  final speakers = naming.summarizeSpeakers(turns, names, mode);
  final languages = turns.map((t) => t.lang).where((l) => l.isNotEmpty).toSet().toList()..sort();
  final durations = [for (final a in [mic, system]) if (a != null) au.duration(a)];

  final doc = Transcript(
    sessionId: m.id,
    title: m.title,
    date: m.createdAt,
    duration: (durations.reduce((a, b) => a > b ? a : b) * 10).roundToDouble() / 10,
    context: mode,
    imported: m.imported,
    headset: m.headset,
    languages: languages,
    expectedParticipants: m.participants,
    glossary: options.glossary,
    speakers: speakers,
    turns: turns,
    notes: notes,
    conflicts: conflicts,
    warnings: warnings,
    micSilent: micSilent,
    needsReview: conflicts.isNotEmpty || speakers.values.any((s) => s.name == null || s.name!.isEmpty),
  );
  m.saveTranscript(doc);
  emit(t('Merging and naming'), 1.0);
  return doc;
}
