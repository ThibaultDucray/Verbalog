// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs the speech pipeline in a background isolate, so the interface stays fluid
// while a meeting is transcribed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../core/i18n.dart';
import '../core/models.dart';
import '../core/pipeline.dart' as pipeline;
import '../core/session.dart';
import '../engine/models_catalog.dart';
import '../engine/sherpa_engine.dart';

class ProcessRequest {
  ProcessRequest({
    required this.meetingDir,
    required this.modelDir,
    required this.whisperSize,
    required this.userName,
    required this.language,
    required this.glossary,
    required this.port,
  });
  final String meetingDir;
  final String modelDir;
  final String whisperSize;
  final String userName;
  final String language;
  final List<String> glossary;
  final SendPort port;
}

Future<Transcript> processInBackground({
  required Meeting meeting,
  required String modelDir,
  required String whisperModelId,
  required String userName,
  required List<String> glossary,
  required void Function(String label, double fraction) onProgress,
}) async {
  final receive = ReceivePort();
  final sub = receive.listen((msg) {
    if (msg is List && msg.length == 2) onProgress(msg[0] as String, (msg[1] as num).toDouble());
  });
  try {
    // Build the request first: the closure must capture only sendable values.
    final request = ProcessRequest(
      meetingDir: meeting.dir,
      modelDir: modelDir,
      whisperSize: whisperById(whisperModelId).id.replaceFirst('whisper-', ''),
      userName: userName,
      language: appLanguage,
      glossary: glossary,
      port: receive.sendPort,
    );
    final json = await _spawn(request);
    return Transcript.fromJson(jsonDecode(json) as Map<String, dynamic>);
  } finally {
    await sub.cancel();
    receive.close();
  }
}

// A top-level function, so the closure captures nothing but the request.
Future<String> _spawn(ProcessRequest r) => Isolate.run(() => _run(r));

String _run(ProcessRequest r) {
  so.initBindings();
  appLanguage = r.language;
  final meeting = Meeting.fromJson(
      r.meetingDir, jsonDecode(File(p.join(r.meetingDir, 'meeting.json')).readAsStringSync()) as Map<String, dynamic>);
  final transcriber = SherpaTranscriber(modelDir: r.modelDir, size: r.whisperSize, languages: meeting.languages);
  final seg = p.join(r.modelDir, segmentationModel.files.single.name);
  final emb = p.join(r.modelDir, embeddingModel.files.single.name);
  final diarizer = File(seg).existsSync() && File(emb).existsSync()
      ? SherpaDiarizer(segmentationModel: seg, embeddingModel: emb)
      : null;
  try {
    final doc = pipeline.process(
      meeting,
      transcriber,
      diarizer,
      options: pipeline.PipelineOptions(userName: r.userName, glossary: r.glossary),
      emit: (label, f) => r.port.send([label, f]),
    );
    return jsonEncode(doc.toJson());
  } finally {
    transcriber.free();
  }
}
