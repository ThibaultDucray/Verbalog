// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One folder per meeting: meeting.json (details and status), mic.wav, system.wav,
// notes.jsonl, transcript.json, aliases.json (never sent), and the exports.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'notes.dart';

class Meeting {
  Meeting({
    required this.id,
    required this.dir,
    required this.title,
    required this.createdAt,
    this.mode = 'presentiel',
    this.languages = const ['fr', 'en'],
    this.participants = const [],
    this.roomCount,
    this.remoteCount,
    this.headset = true,
    this.imported = false,
    this.status = 'recording',
    this.error,
    this.warnings = const [],
    this.durationSeconds = 0,
    this.progress,
    this.progressLabel,
  });

  final String id;
  final String dir;
  String title;
  final String createdAt;
  String mode; // visio (call), presentiel (in person), hybride (hybrid)
  List<String> languages;
  List<String> participants;
  int? roomCount;
  int? remoteCount;
  bool headset;
  bool imported;
  String status; // recording, recorded, processing, review, done, failed
  String? error;
  List<String> warnings;
  double durationSeconds;
  // Not persisted: live processing state for the UI.
  double? progress;
  String? progressLabel;

  String get micPath => p.join(dir, 'mic.wav');
  String get systemPath => p.join(dir, 'system.wav');
  String get notesPath => p.join(dir, 'notes.jsonl');
  String get transcriptPath => p.join(dir, 'transcript.json');
  String get aliasesPath => p.join(dir, 'aliases.json');
  String get markdownPath => p.join(dir, 'transcript.md');
  String get summaryPath => p.join(dir, 'summary.md');
  String path(String name) => p.join(dir, name);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'created_at': createdAt,
        'mode': mode,
        'languages': languages,
        'participants': participants,
        'room_count': roomCount,
        'remote_count': remoteCount,
        'headset': headset,
        'imported': imported,
        'status': status,
        'error': error,
        'warnings': warnings,
        'duration': durationSeconds,
      };

  factory Meeting.fromJson(String dir, Map<String, dynamic> j) => Meeting(
        id: j['id'] as String,
        dir: dir,
        title: j['title'] as String? ?? '',
        createdAt: j['created_at'] as String? ?? '',
        mode: j['mode'] as String? ?? 'presentiel',
        languages: List<String>.from(j['languages'] as List? ?? ['fr', 'en']),
        participants: List<String>.from(j['participants'] as List? ?? []),
        roomCount: j['room_count'] as int?,
        remoteCount: j['remote_count'] as int?,
        headset: j['headset'] as bool? ?? true,
        imported: j['imported'] as bool? ?? false,
        status: j['status'] as String? ?? 'recorded',
        error: j['error'] as String?,
        warnings: List<String>.from(j['warnings'] as List? ?? []),
        durationSeconds: (j['duration'] as num? ?? 0).toDouble(),
      );

  void save() {
    final tmp = File(p.join(dir, 'meeting.json.tmp'));
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    tmp.renameSync(p.join(dir, 'meeting.json'));
  }

  void appendNote(RawNote note) {
    File(notesPath).writeAsStringSync('${jsonEncode(note.toJson())}\n', mode: FileMode.append, flush: true);
  }

  List<RawNote> rawNotes() {
    final f = File(notesPath);
    if (!f.existsSync()) return [];
    final out = <RawNote>[];
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(RawNote.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // a line cut by a crash; the others are intact
      }
    }
    return out;
  }

  Transcript? loadTranscript() {
    final f = File(transcriptPath);
    if (!f.existsSync()) return null;
    return Transcript.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  }

  void saveTranscript(Transcript doc) {
    final tmp = File('$transcriptPath.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(doc.toJson()));
    tmp.renameSync(transcriptPath);
  }

  Map<String, String> loadAliases() {
    final f = File(aliasesPath);
    if (!f.existsSync()) return {};
    return Map<String, String>.from(jsonDecode(f.readAsStringSync()) as Map);
  }

  void saveAliases(Map<String, String> mapping) =>
      File(aliasesPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(mapping));

  bool get hasAudio => File(micPath).existsSync() || File(systemPath).existsSync();

  void deleteAudio() {
    for (final f in [micPath, systemPath]) {
      final file = File(f);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

class MeetingStore {
  MeetingStore(this.root);
  final String root;

  List<Meeting> list() {
    final d = Directory(root);
    if (!d.existsSync()) return [];
    final out = <Meeting>[];
    for (final e in d.listSync().whereType<Directory>()) {
      final f = File(p.join(e.path, 'meeting.json'));
      if (!f.existsSync()) continue;
      try {
        out.add(Meeting.fromJson(e.path, jsonDecode(f.readAsStringSync()) as Map<String, dynamic>));
      } catch (_) {}
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Meeting create({required String title, String mode = 'presentiel', List<String>? languages, bool imported = false}) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final id = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dir = p.join(root, id);
    Directory(dir).createSync(recursive: true);
    final m = Meeting(
      id: id,
      dir: dir,
      title: title,
      createdAt: now.toIso8601String().substring(0, 19),
      mode: mode,
      languages: languages ?? const ['fr', 'en'],
      imported: imported,
    )..save();
    return m;
  }

  void delete(Meeting m) => Directory(m.dir).deleteSync(recursive: true);
}
