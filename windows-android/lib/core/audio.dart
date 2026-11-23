// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// WAV I/O and energy-based speech detection. Tracks are 16-bit, mono, 16 kHz.
// Ported from Verbalog's audio.py.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const sampleRate = 16000;
const headerSize = 44;

Uint8List wavHeader(int numBytes, {int rate = sampleRate, int channels = 1}) {
  final b = ByteData(44);
  void s(int o, String v) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, v.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  b.setUint32(4, 36 + numBytes, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2 * channels, Endian.little);
  b.setUint16(32, 2 * channels, Endian.little);
  b.setUint16(34, 16, Endian.little);
  s(36, 'data');
  b.setUint32(40, numBytes, Endian.little);
  return b.buffer.asUint8List();
}

void writeWav(String path, Float32List audio) {
  final pcm = ByteData(audio.length * 2);
  for (var i = 0; i < audio.length; i++) {
    pcm.setInt16(i * 2, (audio[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  File(path).writeAsBytesSync([...wavHeader(pcm.lengthInBytes), ...pcm.buffer.asUint8List()]);
}

/// Read any PCM16 WAV, mixing to mono and resampling to 16 kHz. The data chunk is
/// trusted to the end of the file, so a recording cut by a crash still reads.
Float32List readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length < headerSize || String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') {
    throw FormatException('Invalid WAV file: $path');
  }
  final data = ByteData.sublistView(bytes);
  var channels = 1, rate = sampleRate, bits = 16, format = 1;
  var offset = 12, dataStart = -1, dataLen = 0;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'fmt ') {
      format = data.getUint16(offset + 8, Endian.little);
      channels = data.getUint16(offset + 10, Endian.little);
      rate = data.getUint32(offset + 12, Endian.little);
      bits = data.getUint16(offset + 22, Endian.little);
    } else if (id == 'data') {
      dataStart = offset + 8;
      dataLen = bytes.length - dataStart; // ignore a header left unfinalized
      break;
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (dataStart < 0) throw FormatException('No audio data: $path');
  final bytesPerSample = bits ~/ 8;
  final frames = dataLen ~/ (bytesPerSample * channels);
  final mono = Float32List(frames);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final o = dataStart + (f * channels + c) * bytesPerSample;
      if (format == 3 && bits == 32) {
        sum += data.getFloat32(o, Endian.little);
      } else if (bits == 16) {
        sum += data.getInt16(o, Endian.little) / 32768.0;
      } else if (bits == 32) {
        sum += data.getInt32(o, Endian.little) / 2147483648.0;
      } else if (bits == 24) {
        var v = data.getUint8(o) | (data.getUint8(o + 1) << 8) | (data.getInt8(o + 2) << 16);
        sum += v / 8388608.0;
      } else {
        sum += (data.getUint8(o) - 128) / 128.0;
      }
    }
    mono[f] = sum / channels;
  }
  return rate == sampleRate ? mono : resample(mono, rate, sampleRate);
}

/// Linear resampling; enough for speech going into Whisper.
Float32List resample(Float32List input, int from, int to) {
  if (from == to || input.isEmpty) return input;
  final n = (input.length * to / from).floor();
  final out = Float32List(n);
  final ratio = from / to;
  for (var i = 0; i < n; i++) {
    final pos = i * ratio;
    final j = pos.floor();
    final frac = pos - j;
    final a = input[math.min(j, input.length - 1)];
    final b = input[math.min(j + 1, input.length - 1)];
    out[i] = a + (b - a) * frac;
  }
  return out;
}

double duration(Float32List audio) => audio.length / sampleRate;

double rmsDb(Float32List audio) {
  if (audio.isEmpty) return -120.0;
  var sum = 0.0;
  for (final v in audio) {
    sum += v * v;
  }
  return 20 * math.log(math.sqrt(sum / audio.length) + 1e-6) / math.ln10;
}

Float32List sliceSeconds(Float32List audio, double start, double end) {
  final a = math.max(0, (start * sampleRate).floor()).clamp(0, audio.length);
  final b = math.max(0, (end * sampleRate).floor()).clamp(0, audio.length);
  return Float32List.sublistView(audio, a, math.max(a, b));
}

List<double> _frameDb(Float32List audio, int frame) {
  final count = audio.length ~/ frame;
  return [
    for (var i = 0; i < count; i++) rmsDb(Float32List.sublistView(audio, i * frame, (i + 1) * frame)),
  ];
}

typedef Region = (double, double);

/// Speech regions as (start, end) seconds. The threshold adapts to the noise
/// floor, so a noisy room is not treated as continuous speech.
List<Region> energyVad(Float32List audio,
    {double minSpeech = 0.25, double mergeGap = 0.5, double pad = 0.2, double floorDb = -50.0}) {
  const hop = 0.03;
  final frame = (sampleRate * hop).floor();
  final db = _frameDb(audio, frame);
  if (db.isEmpty) return [];
  final audible = db.where((d) => d > -90).toList()..sort();
  final noise = audible.isEmpty ? -120.0 : audible[((audible.length - 1) * 0.1).floor()];
  final threshold = math.max(noise + 10, floorDb);

  final regions = <List<double>>[];
  int? start;
  for (var i = 0; i < db.length; i++) {
    final on = db[i] > threshold;
    if (on && start == null) {
      start = i;
    } else if (!on && start != null) {
      regions.add([start * hop, i * hop]);
      start = null;
    }
  }
  if (start != null) regions.add([start * hop, db.length * hop]);

  final merged = <List<double>>[];
  for (final r in regions) {
    if (merged.isNotEmpty && r[0] - merged.last[1] <= mergeGap) {
      merged.last[1] = r[1];
    } else {
      merged.add(r);
    }
  }
  final total = duration(audio);
  return [
    for (final r in merged)
      if (r[1] - r[0] >= minSpeech) (math.max(0.0, r[0] - pad), math.min(total, r[1] + pad))
  ];
}

/// Cut at the quietest point before maxLen so that a chunk never spans
/// Whisper's 30 s window (language detection only looks at the first window).
List<Region> splitLongRegion(Float32List audio, double start, double end, {double maxLen = 28.0}) {
  final pieces = <Region>[];
  var cursor = start;
  while (end - cursor > maxLen) {
    final window = sliceSeconds(audio, cursor + maxLen * 0.6, cursor + maxLen);
    final db = _frameDb(window, (sampleRate * 0.05).floor());
    var offset = maxLen * 0.4;
    if (db.isNotEmpty) {
      var minI = 0;
      for (var i = 1; i < db.length; i++) {
        if (db[i] < db[minI]) minI = i;
      }
      offset = minI * 0.05;
    }
    final cut = cursor + maxLen * 0.6 + offset;
    pieces.add((cursor, cut));
    cursor = cut;
  }
  pieces.add((cursor, end));
  return pieces;
}
