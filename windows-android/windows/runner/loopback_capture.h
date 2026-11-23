// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Records what the PC plays (WASAPI loopback on the default output device): the
// remote participants of a Teams, Zoom or Meet call. Written as 16-bit mono WAV at
// the device's own rate; the app resamples to 16 kHz when it reads it.

#ifndef RUNNER_LOOPBACK_CAPTURE_H_
#define RUNNER_LOOPBACK_CAPTURE_H_

#include <atomic>
#include <cstdio>
#include <string>
#include <thread>

class LoopbackCapture {
 public:
  LoopbackCapture() = default;
  ~LoopbackCapture();

  // Returns an empty string on success, else an error message.
  std::string Start(const std::wstring& path);
  void Pause() { paused_ = true; }
  void Resume() { paused_ = false; }
  void Stop();
  double LevelDb() const { return level_db_.load(); }
  bool running() const { return running_.load(); }

 private:
  void Run();
  void WriteSamples(const float* mono, size_t frames);
  void WriteSilence(size_t frames);
  void FinalizeHeader();

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> paused_{false};
  std::atomic<double> level_db_{-160.0};
  std::atomic<bool> ready_{false};
  std::string start_error_;
  FILE* file_ = nullptr;
  unsigned int sample_rate_ = 48000;
  unsigned long long frames_written_ = 0;
};

#endif  // RUNNER_LOOPBACK_CAPTURE_H_
