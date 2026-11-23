// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// On-device speech engine: Whisper transcription and pyannote-style speaker
// separation through sherpa-onnx (ONNX Runtime), on Windows, Android and Linux.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../core/audio.dart' as au;
import '../core/models.dart';
import '../core/pipeline.dart';

int defaultThreads() => math.max(1, math.min(8, Platform.numberOfProcessors - 1));

class SherpaTranscriber implements Transcriber {
  SherpaTranscriber({required this.modelDir, required this.size, required List<String> languages, int? threads})
      : languages = meetingLanguages(languages),
        threads = threads ?? defaultThreads();

  final String modelDir;
  final String size; // turbo, small, base
  final List<String> languages;
  final int threads;
  final Map<String, so.OfflineRecognizer> _byLanguage = {};

  so.OfflineRecognizer _recognizer(String language) => _byLanguage.putIfAbsent(language, () {
        final config = so.OfflineRecognizerConfig(
          model: so.OfflineModelConfig(
            whisper: so.OfflineWhisperModelConfig(
              encoder: p.join(modelDir, '$size-encoder.int8.onnx'),
              decoder: p.join(modelDir, '$size-decoder.int8.onnx'),
              language: language,
              task: 'transcribe',
              tailPaddings: -1,
            ),
            tokens: p.join(modelDir, '$size-tokens.txt'),
            numThreads: threads,
            debug: false,
          ),
        );
        return so.OfflineRecognizer(config);
      });

  ({String text, String lang}) _decode(Float32List chunk, String language) {
    final recognizer = _recognizer(language);
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: chunk, sampleRate: au.sampleRate);
      recognizer.decode(stream);
      final r = recognizer.getResult(stream);
      return (text: r.text.trim(), lang: _code(r.lang.isNotEmpty ? r.lang : language));
    } finally {
      stream.free();
    }
  }

  static String _code(String lang) {
    final l = lang.replaceAll(RegExp(r'[<>|]'), '').toLowerCase();
    return l.length > 2 ? l.substring(0, 2) : l;
  }

  ({String text, String lang}) transcribeChunk(Float32List chunk) {
    // A meeting in one language is decoded in it: a French voice never comes out as
    // invented English. With several, Whisper detects; outside the meeting's languages
    // (near-silence, or a voice mistaken for a close language) we decode again in the
    // first one ticked.
    if (languages.length == 1) return _decode(chunk, languages.first);
    final auto = _decode(chunk, '');
    if (auto.lang.isEmpty || languages.contains(auto.lang)) return auto;
    return _decode(chunk, languages.first);
  }

  @override
  List<Segment> transcribeRegions(Float32List audio, List<au.Region> regions, {Progress? progress}) {
    final segments = <Segment>[];
    for (var i = 0; i < regions.length; i++) {
      final (start, end) = regions[i];
      final chunk = au.sliceSeconds(audio, start, end);
      if (chunk.length >= au.sampleRate ~/ 10) {
        final r = transcribeChunk(Float32List.fromList(chunk));
        if (!isHallucination(r.text)) segments.add(_withWords(start, end, r.text, r.lang));
      }
      progress?.call((i + 1) / math.max(1, regions.length));
    }
    return segments;
  }

  /// Whisper here gives no word timings: spread the words over the chunk in
  /// proportion to their length, so turns and notes still land in the right place.
  Segment _withWords(double start, double end, String text, String lang) {
    final tokens = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final total = tokens.fold(0, (s, w) => s + w.length + 1);
    var cursor = start;
    final words = <Word>[];
    for (final w in tokens) {
      final d = (end - start) * (w.length + 1) / total;
      words.add(Word(' $w', cursor, cursor + d, 1.0, lang));
      cursor += d;
    }
    return Segment(start, end, text, lang, words);
  }

  void free() {
    for (final r in _byLanguage.values) {
      r.free();
    }
    _byLanguage.clear();
  }
}

class SherpaDiarizer implements Diarizer {
  SherpaDiarizer({required this.segmentationModel, required this.embeddingModel, int? threads, this.threshold = 0.5})
      : threads = threads ?? defaultThreads();

  final String segmentationModel;
  final String embeddingModel;
  final int threads;
  final double threshold;

  @override
  List<SpeakerTurn> diarize(Float32List audio, {int? numSpeakers, Progress? progress}) {
    final sd = so.OfflineSpeakerDiarization(so.OfflineSpeakerDiarizationConfig(
      segmentation: so.OfflineSpeakerSegmentationModelConfig(
        pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(model: segmentationModel),
        numThreads: threads,
        debug: false,
      ),
      embedding: so.SpeakerEmbeddingExtractorConfig(model: embeddingModel, numThreads: threads, debug: false),
      clustering: so.FastClusteringConfig(numClusters: numSpeakers ?? -1, threshold: threshold),
      minDurationOn: 0.3,
      minDurationOff: 0.5,
    ));
    try {
      final segments = progress == null
          ? sd.process(samples: audio)
          : sd.processWithCallback(
              samples: audio,
              callback: (done, total) {
                progress(total == 0 ? 1 : done / total);
                return 0;
              });
      return [for (final s in segments) SpeakerTurn(s.start, s.end, 'SPEAKER_${s.speaker}')]
        ..sort((a, b) => a.start.compareTo(b.start));
    } finally {
      sd.free();
    }
  }
}
