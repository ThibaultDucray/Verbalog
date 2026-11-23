// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../core/audio.dart' as au;
import '../core/export.dart';
import '../core/i18n.dart';
import '../core/llm.dart';
import '../core/models.dart';
import '../core/naming.dart' as naming;
import '../core/pseudonymize.dart';
import '../core/session.dart';
import '../engine/downloader.dart';
import '../engine/models_catalog.dart';
import 'engine_runner.dart';
import 'settings.dart';

class AppState extends ChangeNotifier {
  late final Paths paths;
  late final Settings settings;
  late final MeetingStore store;
  late final ModelDownloader downloader;
  List<Meeting> meetings = [];
  bool ready = false;

  // Model download state
  String? downloadLabel;
  double? downloadFraction;
  String? downloadError;

  final _queue = <Meeting>[];
  bool _processing = false;

  Future<void> init() async {
    paths = await Paths.resolve();
    settings = await Settings.load();
    appLanguage = settings.language;
    store = MeetingStore(paths.meetings);
    downloader = ModelDownloader(paths.models);
    meetings = store.list();
    // A crash or a closed app mid-processing: those meetings go back to "recorded".
    for (final m in meetings.where((m) => m.status == 'processing' || m.status == 'recording')) {
      m.status = m.hasAudio ? 'recorded' : 'failed';
      m.save();
    }
    ready = true;
    notifyListeners();
  }

  void refresh() {
    final live = {for (final m in meetings) m.id: m};
    meetings = [for (final m in store.list()) live[m.id]?.status == 'processing' ? live[m.id]! : m];
    notifyListeners();
  }

  // ---------- Models ----------

  ModelSpec get whisperSpec => whisperById(settings.whisperModel);
  List<ModelSpec> get requiredModels => [whisperSpec, segmentationModel, embeddingModel];
  bool get modelsReady => requiredModels.every(downloader.isInstalled);
  bool get downloading => downloadFraction != null;

  Future<void> downloadModels() async {
    if (downloading) return;
    downloadError = null;
    downloadFraction = 0;
    notifyListeners();
    try {
      final specs = requiredModels.where((s) => !downloader.isInstalled(s)).toList();
      final total = specs.fold<int>(0, (s, m) => s + m.approxMb);
      var done = 0;
      for (final spec in specs) {
        await downloader.install(spec, onProgress: (label, f) {
          downloadLabel = label;
          downloadFraction = (done + spec.approxMb * f) / (total == 0 ? 1 : total);
          notifyListeners();
        });
        done += spec.approxMb;
      }
      downloader.cleanArchives();
    } catch (e) {
      downloadError = '$e';
    } finally {
      downloadFraction = null;
      downloadLabel = null;
      notifyListeners();
    }
  }

  // ---------- Meetings ----------

  Meeting newMeeting({
    required String title,
    required String mode,
    required List<String> languages,
    required List<String> participants,
    int? roomCount,
    int? remoteCount,
  }) {
    final m = store.create(title: title, mode: mode, languages: languages)
      ..participants = participants
      ..roomCount = roomCount
      ..remoteCount = remoteCount
      ..status = 'recording';
    m.save();
    settings.lastMode = mode;
    settings.defaultLanguages = languages;
    meetings.insert(0, m);
    notifyListeners();
    return m;
  }

  /// Imported files are one mixed track, processed like an in-person meeting.
  Future<Meeting> importAudio(String path, {required List<String> languages, int? speakers}) async {
    final title = p.basenameWithoutExtension(path);
    final m = store.create(title: title, mode: 'presentiel', languages: languages, imported: true)
      ..roomCount = speakers
      ..status = 'recorded';
    final audio = await compute(au.readWav, path);
    au.writeWav(m.micPath, audio);
    m.durationSeconds = au.duration(audio);
    m.save();
    meetings.insert(0, m);
    notifyListeners();
    if (settings.autoProcess) enqueue(m);
    return m;
  }

  void deleteMeeting(Meeting m) {
    store.delete(m);
    meetings.remove(m);
    notifyListeners();
  }

  void saveDetails(Meeting m) {
    m.save();
    notifyListeners();
  }

  // ---------- Processing ----------

  void enqueue(Meeting m) {
    if (_queue.contains(m) || m.status == 'processing') return;
    m.status = 'queued';
    m.progress = 0;
    m.progressLabel = null;
    _queue.add(m);
    notifyListeners();
    _pump();
  }

  Future<void> _pump() async {
    if (_processing || _queue.isEmpty) return;
    if (!modelsReady) {
      for (final m in _queue) {
        m.status = 'recorded';
      }
      _queue.clear();
      notifyListeners();
      return;
    }
    _processing = true;
    final m = _queue.removeAt(0);
    m.status = 'processing';
    m.error = null;
    m.save();
    notifyListeners();
    try {
      final doc = await processInBackground(
        meeting: m,
        modelDir: paths.models,
        whisperModelId: settings.whisperModel,
        userName: settings.userName,
        glossary: settings.glossary,
        onProgress: (label, f) {
          m.progress = f;
          m.progressLabel = label;
          notifyListeners();
        },
      );
      m.warnings = doc.warnings;
      if (doc.needsReview) {
        m.status = 'review';
        _writeMarkdown(m, doc);
        m.save();
      } else {
        finalize(m, doc);
      }
    } catch (e) {
      m.status = 'failed';
      m.error = '$e';
      m.save();
    } finally {
      m.progress = null;
      m.progressLabel = null;
      _processing = false;
      notifyListeners();
      unawaited(_pump());
    }
  }

  void _writeMarkdown(Meeting m, Transcript doc) {
    doc.title = m.title;
    File(m.markdownPath).writeAsStringSync(renderMarkdown(doc, userName: settings.userName));
  }

  /// Validating the review exports the files and deletes the audio, unless asked to keep it.
  void finalize(Meeting m, Transcript doc, {Map<String, String>? names, List<(String, String)> merges = const []}) {
    if (names != null || merges.isNotEmpty || doc.needsReview) {
      naming.applyReview(doc, names: names, merges: merges);
    }
    m.saveTranscript(doc);
    _writeMarkdown(m, doc);
    // Never delete audio if the transcript is empty: something went wrong and the audio is the only copy.
    if (!settings.keepAudio && doc.turns.isNotEmpty && !doc.micSilent) m.deleteAudio();
    m.status = 'done';
    m.save();
    notifyListeners();
  }

  void renameSpeaker(Meeting m, Transcript doc, String label, String name) {
    doc.speakers[label]
      ?..name = name.trim()
      ..source = 'review';
    naming.rebuildSpeakers(doc);
    m.saveTranscript(doc);
    _writeMarkdown(m, doc);
    notifyListeners();
  }

  void renameMeeting(Meeting m, String title) {
    m.title = title;
    m.save();
    final doc = m.loadTranscript();
    if (doc != null) {
      doc.title = title;
      m.saveTranscript(doc);
      _writeMarkdown(m, doc);
    }
    notifyListeners();
  }

  // ---------- Minutes, agenda, email ----------

  Future<String> minutesPrompt() =>
      rootBundle.loadString(appLanguage == 'fr' ? 'assets/prompts/synthese.md' : 'assets/prompts/synthese.en.md');

  List<(String, String)> sensitiveTerms() {
    final f = File(paths.sensitiveFile);
    return f.existsSync() ? parseSensitive(f.readAsStringSync()) : const [];
  }

  String get sensitiveText => File(paths.sensitiveFile).existsSync() ? File(paths.sensitiveFile).readAsStringSync() : '';
  set sensitiveText(String v) => File(paths.sensitiveFile).writeAsStringSync(v);

  /// What would leave the device: the prompt and the (pseudonymized) transcript.
  Future<({String prompt, String transcript, bool pseudonymized, int aliases})> prepare(
      Meeting m, Deliverable d, {bool? pseudonymize}) async {
    final doc = m.loadTranscript();
    if (doc == null) throw StateError('The transcript is missing: process the meeting first.');
    var text = renderMarkdown(doc, userName: settings.userName);
    final use = pseudonymize ?? settings.pseudonymize;
    var aliases = 0;
    if (use) {
      final engine = Pseudonymizer(m.loadAliases());
      final people = [
        for (final s in doc.speakers.values)
          if (s.name != null) s.name!,
        ...doc.expectedParticipants,
        settings.userName,
      ];
      text = pseudonymizeText(text, engine, sensitiveTerms(), people);
      m.saveAliases(engine.mapping);
      aliases = engine.mapping.length;
    }
    final prompt = promptFor(d, minutesPrompt: await minutesPrompt(), outputLanguage: settings.outputLanguage);
    return (prompt: prompt, transcript: text, pseudonymized: use, aliases: aliases);
  }

  Future<String> generateWithApi(Meeting m, Deliverable d, {required String prompt, required String transcript}) async {
    final client = AnthropicClient(await settings.apiKey(), model: settings.llmModel);
    return client.complete(prompt, transcript);
  }

  /// Store a response with the real names restored.
  String saveResult(Meeting m, Deliverable d, String text, {required bool pseudonymized}) {
    if (pseudonymized) text = Pseudonymizer(m.loadAliases()).reidentify(text);
    File(m.path('${d.name}.md')).writeAsStringSync('${text.trimRight()}\n');
    notifyListeners();
    return text;
  }

  String? savedResult(Meeting m, Deliverable d) {
    final f = File(m.path('${d.name}.md'));
    return f.existsSync() ? f.readAsStringSync() : null;
  }
}

final app = AppState();
