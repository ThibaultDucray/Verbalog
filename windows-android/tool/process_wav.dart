// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Developer tool: run the whole pipeline on a WAV file from the command line.
// dart run tool/process_wav.dart <models-dir> <whisper-size> <audio.wav> [num-speakers]

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:verbalog/core/audio.dart' as au;
import 'package:verbalog/core/export.dart';
import 'package:verbalog/core/pipeline.dart';
import 'package:verbalog/core/session.dart';
import 'package:verbalog/engine/sherpa_engine.dart';

void main(List<String> args) {
  so.initBindings();
  final models = args[0], size = args[1], wav = args[2];
  final count = args.length > 3 ? int.parse(args[3]) : null;
  final store = MeetingStore(Directory.systemTemp.createTempSync('verbalog').path);
  final m = store.create(title: p.basenameWithoutExtension(wav), mode: 'presentiel', languages: ['en']);
  m.roomCount = count;
  au.writeWav(m.micPath, au.readWav(wav));
  final sw = Stopwatch()..start();
  final doc = process(
    m,
    SherpaTranscriber(modelDir: models, size: size, languages: m.languages),
    SherpaDiarizer(
      segmentationModel: p.join(models, 'segmentation.int8.onnx'),
      embeddingModel: p.join(models, '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx'),
    ),
    emit: (label, f) => stderr.writeln('${(f * 100).toStringAsFixed(0)}% $label'),
  );
  stderr.writeln('Done in ${sw.elapsed.inSeconds}s for ${doc.duration}s of audio');
  stdout.write(renderMarkdown(doc));
}
