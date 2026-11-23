# VerbaLog for PC & Android

A light meeting recorder for **Windows** and **Android** that transcribes on your device, tells speakers apart, and turns your notes into minutes, an agenda or a follow-up email.

This is the Windows and Android version of [Verbalog](../README.md) by **Thibault Ducray**, which started on macOS. The ideas, the note syntax, the speaker-naming rules, the pseudonymization and the minutes prompt all come from his work. Thank you, Thibault.

## What it does

- **Records** your microphone. On Windows it can also record what the PC plays, so the remote people on a Teams, Zoom or Meet call get their own track.
- **Transcribes locally** with Whisper (via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)). The audio never leaves the device.
- **Separates speakers** (pyannote segmentation + speaker embeddings), then names them from your notes.
- **Notes while you record**, timestamped at your first keystroke:
  - `! text` action, `# text` decision, `? text` question, `~ text` private (never exported)
  - `@Maria` (or "Maria speaking", "c'est Maria qui parle") tells the app Maria is speaking now.
  - An empty note is a bookmark.
- **Review speakers**: listen to a sample, rename, merge.
- **Writes the follow-up**: minutes, next agenda, email. Either send it to Claude with your own Anthropic API key, or copy it into any assistant (Claude, ChatGPT, Gemini, Mistral) and paste the answer back. You see the exact text before it leaves the device, and names and sensitive terms can be replaced by aliases first.
- **Exports** Markdown, with a transcript JSON compatible with Verbalog's.
- Interface in English and French.

## Install

Download the latest build from the [releases](../../../releases) tagged `windows-android-v…`, or the artifacts of the latest [Windows & Android](../../../actions/workflows/windows-android.yml) run:

- **Windows**: unzip `VerbaLog-windows.zip` and run `VerbaLog.exe`.
- **Android**: install `app-release.apk` (allow installs from this source).

On first launch, pick a quality level. The app downloads the speech models once (about 160 MB to 1 GB depending on quality), then works offline.

| Quality | Model | Good for |
|---|---|---|
| Fast | Whisper base, ~160 MB | older phones |
| Balanced | Whisper small, ~360 MB | most phones (default on Android) |
| Best | Whisper large-v3 turbo, ~1 GB | PCs (default on Windows) |

## Meeting modes (Windows)

- **Video call**: your mic is you; the PC sound is the remote people, separated by voice.
- **In person**: one mic for everyone, separated by voice.
- **Hybrid**: both.

Android records the microphone only (Android does not let apps record call audio).

## Privacy

- Recording, transcription and speaker separation run on your device.
- Nothing is sent anywhere unless you press a button to send it, and the preview shows exactly what would be sent.
- The API key is stored in the system's secure storage.
- Audio is deleted after processing unless you choose to keep it.

## Known limits of this first version

- Import accepts WAV files only.
- On Android, keep the app open during a recording (the screen stays on).
- No live transcript while recording; transcription runs when you stop.
- Whisper glossary hints are not supported by the engine yet; the glossary is still used to fix names afterwards.
- Verbalog's spaCy name detection is not ported; pseudonymization uses your participants, your sensitive-terms list and patterns (emails, phone numbers, amounts).

## Build from source

Requires Flutter 3.50 or later. Run these from this folder.

```sh
flutter pub get
flutter test
flutter run -d windows        # on Windows, with Visual Studio's C++ workload
flutter build apk --release   # Android
```

The Windows call-audio capture is native code in `windows/runner/loopback_capture.cpp` (WASAPI loopback).

Developer tool, to run the pipeline on a WAV file with downloaded models:

```sh
dart run tool/process_wav.dart <models-dir> <small|base|turbo> meeting.wav [speakers]
```

## License

GPL-3.0-or-later, like the rest of Verbalog. See [LICENSE](../LICENSE).
