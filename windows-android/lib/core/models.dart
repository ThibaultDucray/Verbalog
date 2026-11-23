// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain data passed between pipeline stages. The JSON shapes follow Verbalog's,
// so a transcript exported here can be read by the macOS app and vice versa.

double r3(double v) => (v * 1000).roundToDouble() / 1000;

class Word {
  Word(this.text, this.start, this.end, [this.confidence = 1.0, this.lang = '']);
  final String text;
  final double start;
  final double end;
  final double confidence;
  final String lang;

  Map<String, dynamic> toJson() =>
      {'w': text, 'start': r3(start), 'end': r3(end), 'conf': r3(confidence), 'lang': lang};

  factory Word.fromJson(Map<String, dynamic> j) => Word(
        j['w'] as String,
        (j['start'] as num).toDouble(),
        (j['end'] as num).toDouble(),
        (j['conf'] as num? ?? 1).toDouble(),
        j['lang'] as String? ?? '',
      );
}

class Segment {
  Segment(this.start, this.end, this.text, this.lang, [List<Word>? words]) : words = words ?? [];
  final double start;
  final double end;
  final String text;
  final String lang;
  final List<Word> words;
}

class SpeakerTurn {
  const SpeakerTurn(this.start, this.end, this.label);
  final double start;
  final double end;
  final String label;
}

/// A chronological speaking turn: consecutive words of one speaker on one track.
class Turn {
  Turn({
    required this.start,
    required this.end,
    required this.label,
    required this.track,
    List<Word>? words,
    this.text = '',
    this.lang = '',
    this.confidence = 0,
  }) : words = words ?? [];

  double start;
  double end;
  String label;
  final String track;
  final List<Word> words;
  String text;
  String lang;
  double confidence;

  Map<String, dynamic> toJson() => {
        'start': r3(start),
        'end': r3(end),
        'label': label,
        'track': track,
        'text': text,
        'lang': lang,
        'confidence': r3(confidence),
        'words': words.map((w) => w.toJson()).toList(),
      };

  factory Turn.fromJson(Map<String, dynamic> j) => Turn(
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        label: j['label'] as String,
        track: j['track'] as String? ?? 'mic',
        words: [for (final w in (j['words'] as List? ?? [])) Word.fromJson(Map<String, dynamic>.from(w as Map))],
        text: j['text'] as String? ?? '',
        lang: j['lang'] as String? ?? '',
        confidence: (j['confidence'] as num? ?? 0).toDouble(),
      );
}

/// note, action, decision, question, bookmark, private, or speaker (a naming hint).
class Note {
  Note(this.t, this.type, {this.text = '', this.speaker, this.announce = false});
  final double t;
  final String type;
  final String text;
  final String? speaker;
  final bool announce;

  Map<String, dynamic> toJson() =>
      {'t': r3(t), 'type': type, 'text': text, if (speaker != null) 'speaker': speaker};

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        (j['t'] as num).toDouble(),
        j['type'] as String,
        text: j['text'] as String? ?? '',
        speaker: j['speaker'] as String?,
      );
}

class Sample {
  Sample(this.t, this.end, this.track, this.text);
  final double t;
  final double end;
  final String track;
  final String text;
  Map<String, dynamic> toJson() => {'t': t, 'end': end, 'track': track, 'text': text};
  factory Sample.fromJson(Map<String, dynamic> j) => Sample(
      (j['t'] as num).toDouble(), (j['end'] as num).toDouble(), j['track'] as String? ?? 'mic', j['text'] as String? ?? '');
}

class Speaker {
  Speaker({
    required this.track,
    required this.origin,
    this.talkSeconds = 0,
    this.name,
    this.source,
    this.display = '',
    List<Sample>? samples,
  }) : samples = samples ?? [];

  final String track;
  final String origin; // salle (room), distant (remote), moi (me), or ''
  double talkSeconds;
  String? name;
  String? source; // user, hint, voiceprint, review
  String display;
  List<Sample> samples;

  Map<String, dynamic> toJson() => {
        'track': track,
        'origin': origin,
        'talk_seconds': talkSeconds,
        'name': name,
        'source': source,
        'display': display,
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  factory Speaker.fromJson(Map<String, dynamic> j) => Speaker(
        track: j['track'] as String? ?? 'mic',
        origin: j['origin'] as String? ?? '',
        talkSeconds: (j['talk_seconds'] as num? ?? 0).toDouble(),
        name: j['name'] as String?,
        source: j['source'] as String?,
        display: j['display'] as String? ?? '',
        samples: [for (final s in (j['samples'] as List? ?? [])) Sample.fromJson(Map<String, dynamic>.from(s as Map))],
      );
}

class Conflict {
  Conflict(this.kind, this.t, this.name, this.labels, [this.previous]);
  final String kind; // ambiguous, no_speaker, contradiction
  final double t;
  final String name;
  final List<String> labels;
  final String? previous;
  Map<String, dynamic> toJson() =>
      {'kind': kind, 't': t, 'name': name, 'labels': labels, if (previous != null) 'previous': previous};
  factory Conflict.fromJson(Map<String, dynamic> j) => Conflict(j['kind'] as String, (j['t'] as num).toDouble(),
      j['name'] as String, List<String>.from(j['labels'] as List? ?? []), j['previous'] as String?);
}

/// The processed meeting: what the review screen edits and the exports are built from.
class Transcript {
  Transcript({
    required this.sessionId,
    required this.title,
    required this.date,
    required this.duration,
    required this.context,
    this.imported = false,
    this.headset = true,
    this.languages = const [],
    this.expectedParticipants = const [],
    this.glossary = const [],
    required this.speakers,
    required this.turns,
    required this.notes,
    this.conflicts = const [],
    this.warnings = const [],
    this.micSilent = false,
    this.needsReview = false,
  });

  final String sessionId;
  String title;
  final String date;
  final double duration;
  final String context; // visio (call), presentiel (in person), hybride (hybrid)
  final bool imported;
  final bool headset;
  final List<String> languages;
  final List<String> expectedParticipants;
  final List<String> glossary;
  Map<String, Speaker> speakers;
  List<Turn> turns;
  List<Note> notes;
  List<Conflict> conflicts;
  List<String> warnings;
  final bool micSilent;
  bool needsReview;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'session_id': sessionId,
        'title': title,
        'date': date,
        'duration': duration,
        'context': context,
        if (imported) 'imported': true,
        'headset': headset,
        'languages': languages,
        'expected_participants': expectedParticipants,
        'glossary': glossary,
        'speakers': speakers.map((k, v) => MapEntry(k, v.toJson())),
        'turns': turns.map((t) => t.toJson()).toList(),
        'notes': notes.map((n) => n.toJson()).toList(),
        'conflicts': conflicts.map((c) => c.toJson()).toList(),
        'warnings': warnings,
        'mic_silent': micSilent,
        'needs_review': needsReview,
      };

  factory Transcript.fromJson(Map<String, dynamic> j) => Transcript(
        sessionId: j['session_id'] as String,
        title: j['title'] as String? ?? '',
        date: j['date'] as String? ?? '',
        duration: (j['duration'] as num? ?? 0).toDouble(),
        context: j['context'] as String? ?? 'presentiel',
        imported: j['imported'] as bool? ?? false,
        headset: j['headset'] as bool? ?? true,
        languages: List<String>.from(j['languages'] as List? ?? []),
        expectedParticipants: List<String>.from(j['expected_participants'] as List? ?? []),
        glossary: List<String>.from(j['glossary'] as List? ?? []),
        speakers: (j['speakers'] as Map? ?? {})
            .map((k, v) => MapEntry(k as String, Speaker.fromJson(Map<String, dynamic>.from(v as Map)))),
        turns: [for (final t in (j['turns'] as List? ?? [])) Turn.fromJson(Map<String, dynamic>.from(t as Map))],
        notes: [for (final n in (j['notes'] as List? ?? [])) Note.fromJson(Map<String, dynamic>.from(n as Map))],
        conflicts: [
          for (final c in (j['conflicts'] as List? ?? [])) Conflict.fromJson(Map<String, dynamic>.from(c as Map))
        ],
        warnings: List<String>.from(j['warnings'] as List? ?? []),
        micSilent: j['mic_silent'] as bool? ?? false,
        needsReview: j['needs_review'] as bool? ?? false,
      );
}
