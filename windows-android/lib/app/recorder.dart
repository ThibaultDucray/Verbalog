// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Records a meeting: the microphone, and on Windows the computer's own sound
// (WASAPI loopback), which is how the remote participants of a Teams, Zoom or Meet
// call are heard. The two tracks are kept apart, as in Verbalog.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../core/session.dart';

/// Native loopback capture, implemented in windows/runner/loopback_capture.cpp.
class LoopbackRecorder {
  static const _channel = MethodChannel('verbalog/loopback');
  static bool get supported => Platform.isWindows;

  Future<void> start(String path) => _channel.invokeMethod('start', {'path': path});
  Future<void> pause() => _channel.invokeMethod('pause');
  Future<void> resume() => _channel.invokeMethod('resume');
  Future<void> stop() => _channel.invokeMethod('stop');
  Future<double> level() async => ((await _channel.invokeMethod<double>('level')) ?? -160.0);
}

class MeetingRecorder {
  MeetingRecorder(this.meeting);
  final Meeting meeting;
  final _mic = AudioRecorder();
  final _loopback = LoopbackRecorder();
  final _clock = Stopwatch();
  bool _paused = false;
  bool _systemActive = false;
  bool _stopped = false;
  String? systemError;

  bool get paused => _paused;
  bool get capturesSystem => _systemActive;
  Duration get elapsed => _clock.elapsed;

  Future<void> start() async {
    if (!await _mic.hasPermission()) {
      throw StateError('Microphone access was refused.');
    }
    await _mic.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
      ),
      path: meeting.micPath,
    );
    if (meeting.mode != 'presentiel' && LoopbackRecorder.supported) {
      try {
        await _loopback.start(meeting.systemPath);
        _systemActive = true;
      } catch (e) {
        systemError = '$e';
      }
    }
    _clock.start();
  }

  Stream<double> micLevel() => _mic.onAmplitudeChanged(const Duration(milliseconds: 120)).map((a) => a.current);

  Future<double> systemLevel() async => _systemActive ? await _loopback.level() : -160.0;

  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    _clock.stop();
    await _mic.pause();
    if (_systemActive) await _loopback.pause();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    await _mic.resume();
    if (_systemActive) await _loopback.resume();
    _clock.start();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _clock.stop();
    await _mic.stop();
    if (_systemActive) await _loopback.stop();
    await _mic.dispose();
    meeting.durationSeconds = elapsed.inMilliseconds / 1000;
    meeting.status = 'recorded';
    meeting.save();
  }
}
