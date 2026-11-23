// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "loopback_capture.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <audioclient.h>

#include <chrono>
#include <cmath>
#include <vector>

namespace {

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

void WriteLe32(FILE* f, unsigned int v) { fwrite(&v, 4, 1, f); }
void WriteLe16(FILE* f, unsigned short v) { fwrite(&v, 2, 1, f); }

void WriteHeader(FILE* f, unsigned int rate, unsigned int data_bytes) {
  fseek(f, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, f);
  WriteLe32(f, 36 + data_bytes);
  fwrite("WAVEfmt ", 1, 8, f);
  WriteLe32(f, 16);
  WriteLe16(f, 1);  // PCM
  WriteLe16(f, 1);  // mono
  WriteLe32(f, rate);
  WriteLe32(f, rate * 2);
  WriteLe16(f, 2);
  WriteLe16(f, 16);
  fwrite("data", 1, 4, f);
  WriteLe32(f, data_bytes);
}

}  // namespace

LoopbackCapture::~LoopbackCapture() { Stop(); }

std::string LoopbackCapture::Start(const std::wstring& path) {
  if (running_) return "already recording";
  if (_wfopen_s(&file_, path.c_str(), L"wb") != 0 || !file_) {
    file_ = nullptr;
    return "cannot create the audio file";
  }
  frames_written_ = 0;
  paused_ = false;
  ready_ = false;
  start_error_.clear();
  running_ = true;
  thread_ = std::thread(&LoopbackCapture::Run, this);
  // Wait for the device to open, so errors reach the app.
  for (int i = 0; i < 300 && !ready_ && running_; ++i) Sleep(10);
  if (!running_) {
    if (thread_.joinable()) thread_.join();
    if (file_) {
      fclose(file_);
      file_ = nullptr;
    }
    return start_error_.empty() ? "cannot start capturing the PC's sound" : start_error_;
  }
  return "";
}

void LoopbackCapture::Stop() {
  if (!running_ && !thread_.joinable()) return;
  running_ = false;
  if (thread_.joinable()) thread_.join();
  if (file_) {
    FinalizeHeader();
    fclose(file_);
    file_ = nullptr;
  }
}

void LoopbackCapture::FinalizeHeader() {
  long end = ftell(file_);
  WriteHeader(file_, sample_rate_, static_cast<unsigned int>(frames_written_ * 2));
  fseek(file_, end, SEEK_SET);
  fflush(file_);
}

void LoopbackCapture::WriteSamples(const float* mono, size_t frames) {
  std::vector<short> pcm(frames);
  double sum = 0;
  for (size_t i = 0; i < frames; ++i) {
    float v = mono[i];
    sum += static_cast<double>(v) * v;
    if (v > 1.f) v = 1.f;
    if (v < -1.f) v = -1.f;
    pcm[i] = static_cast<short>(std::lround(v * 32767.f));
  }
  fwrite(pcm.data(), sizeof(short), frames, file_);
  frames_written_ += frames;
  if (frames > 0) {
    level_db_ = 20.0 * std::log10(std::sqrt(sum / frames) + 1e-6);
  }
}

void LoopbackCapture::WriteSilence(size_t frames) {
  std::vector<short> zeros(frames, 0);
  fwrite(zeros.data(), sizeof(short), frames, file_);
  frames_written_ += frames;
  level_db_ = -160.0;
}

void LoopbackCapture::Run() {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool com = SUCCEEDED(hr);
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* format = nullptr;

  auto fail = [&](const char* message) {
    start_error_ = message;
    running_ = false;
  };

  do {
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                          reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) { fail("no audio device enumerator"); break; }
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) { fail("no audio output device"); break; }
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client));
    if (FAILED(hr)) { fail("cannot open the audio output device"); break; }
    hr = client->GetMixFormat(&format);
    if (FAILED(hr)) { fail("cannot read the audio format"); break; }
    // 200 ms buffer, shared mode, loopback of the render stream.
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000, 0, format, nullptr);
    if (FAILED(hr)) { fail("cannot start loopback capture"); break; }
    hr = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&capture));
    if (FAILED(hr)) { fail("cannot get the capture service"); break; }

    sample_rate_ = format->nSamplesPerSec;
    const int channels = format->nChannels;
    bool is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format);
      // The subtype GUIDs carry the format tag in Data1 (3 = IEEE float).
      is_float = ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
    }
    const int bits = format->wBitsPerSample;

    WriteHeader(file_, sample_rate_, 0);
    hr = client->Start();
    if (FAILED(hr)) { fail("cannot start the audio client"); break; }
    ready_ = true;

    // Loopback delivers nothing while the PC is silent: fill those gaps with
    // silence against the clock, so this track stays aligned with the mic.
    using clock = std::chrono::steady_clock;
    auto last = clock::now();
    double expected = 0;  // frames that should have been written while not paused
    std::vector<float> mono;

    while (running_) {
      Sleep(10);
      auto now = clock::now();
      double elapsed = std::chrono::duration<double>(now - last).count();
      last = now;
      if (!paused_) expected += elapsed * sample_rate_;

      UINT32 packet = 0;
      while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
        if (!paused_) {
          mono.assign(frames, 0.f);
          if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
            for (UINT32 f = 0; f < frames; ++f) {
              float sum = 0.f;
              for (int c = 0; c < channels; ++c) {
                size_t i = static_cast<size_t>(f) * channels + c;
                if (is_float && bits == 32) {
                  sum += reinterpret_cast<float*>(data)[i];
                } else if (bits == 16) {
                  sum += reinterpret_cast<short*>(data)[i] / 32768.f;
                } else if (bits == 32) {
                  sum += reinterpret_cast<int*>(data)[i] / 2147483648.f;
                }
              }
              mono[f] = sum / channels;
            }
          }
          WriteSamples(mono.data(), frames);
        }
        capture->ReleaseBuffer(frames);
      }

      if (!paused_ && expected - static_cast<double>(frames_written_) > sample_rate_ * 0.1) {
        WriteSilence(static_cast<size_t>(expected - frames_written_));
      }
      // Never run ahead of the clock either: drift between the two clocks stays small.
      if (static_cast<double>(frames_written_) > expected) expected = static_cast<double>(frames_written_);
    }
    client->Stop();
  } while (false);

  if (format) CoTaskMemFree(format);
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (com) CoUninitialize();
  running_ = false;
}
