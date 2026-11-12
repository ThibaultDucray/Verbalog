# Contributing to Verbalog

Thanks for helping. Verbalog handles recordings of real conversations, so a few rules come before anything else.

## Ground rules

- **No real meeting data, ever.** Don't attach recordings, transcripts, notes or logs from real meetings to issues or pull requests. Tests use synthesized audio and made-up names; keep it that way.
- **Nothing leaves the Mac without the user asking.** Every network connection is listed in the manual's [privacy section](MANUAL.md#12-privacy-and-your-data). A change that adds one must be opt-in, and must update that list. The same goes for dependencies: turn off any telemetry they ship (see `verbalog/cli.py` for pyannote).
- **Licence header.** Every source file starts with these two lines, after any `#!` line (`#` instead of `//` in Python and shell). A test checks it.
  ```swift
  // SPDX-FileCopyrightText: 2026 Thibault Ducray
  // SPDX-License-Identifier: GPL-3.0-or-later
  ```
- **English first.** Interface strings, messages and docs are written in English, then translated to French (see [Languages](#languages)).

## Building from source

You need a Mac with Apple Silicon on macOS 14 or later, [Homebrew](https://brew.sh), and Xcode.

```sh
brew install uv
scripts/bootstrap.sh     # Python backend into .venv
scripts/build-app.sh     # build/Verbalog.app
open build/Verbalog.app
```

A development build runs its backend from the project folder: if you move the folder, rebuild the app. Release builds work differently, see [RELEASING.md](RELEASING.md).

macOS ties the microphone and screen-recording permissions to the app's signature. `build-app.sh` uses the first Apple Development or Developer ID identity in your keychain, or signs ad hoc without one, in which case permissions must be granted again after every rebuild.

To work in Xcode, open `Verbalog.xcodeproj`: the `Verbalog` scheme builds and runs the app (⌘R) and runs the Swift tests (⌘U). Set `DEVELOPMENT_TEAM` to your own team first. Its source folders are synchronized and `app/Package.swift` covers the same folders, so a file added to an existing target needs no project change. A new target has to be added to both.

## Tests

```sh
.venv/bin/python -m pytest          # backend, with fake models
.venv/bin/python -m pytest -m e2e   # real Whisper on synthesized speech (needs the model)
swift test --package-path app       # capture and core
```

GitHub Actions runs the first and the last on every push and pull request.

## Architecture

```
SwiftUI app (app/)                            Python backend (verbalog/)
  VerbalogApp          the interface
  VerbalogCaptureKit   mic + system audio ──▶ mic.wav, system.wav ─┐
                       notes ───────────────▶ notes.jsonl ─────────┤
  VerbalogCore         runs one process      `python -m verbalog`  ├▶ transcript.json
                       per job, reads ◀───── NDJSON events ◀───────┘  .md, .json
```

- **One process per job.** Exiting is what frees the models' memory. stdout carries only NDJSON events: `init_protocol` in `verbalog/events.py` sends everything libraries print there to stderr (kept in `~/.verbalog/backend.log`).
- **The session directory is the interface.** `~/.verbalog/sessions/<id>/` (mode 700) holds `session.json`, the audio, notes and transcript, so a crash loses nothing: the session reopens ready to process.
- **One clock.** Each audio buffer is written where its host timestamp says it belongs (`AlignedTrack`). Late starts, stalls and pauses become silence, so tracks and notes stay aligned.

Backend commands, also usable from a terminal with `.venv/bin/python -m verbalog`: `doctor`, `setup`, `process`, `finalize`, `rename`, `retitle`, `prepare`, `summarize`, `save-summary`, `live`, `enroll`, `purge-audio`, `delete`, `config`.

## Languages

English is the source language; French is a translation. The setting covers the interface, backend messages, the summary prompt and the Markdown export's headings and speaker placeholders. The summary's own language is a separate setting (Settings › LLM).

To change or add text: `app/Resources/fr.lproj/Localizable.strings` for the app (keys are the English strings), `FR` in `verbalog/i18n.py` for the backend, and `verbalog/prompts/` for the prompt. `tests/test_i18n.py` catches missing translations.

## Pull requests

- Keep each pull request to one change, with tests where the behaviour can be tested.
- Run both test suites before opening it.
- Describe what you checked by hand for anything the tests can't reach, such as capture, permissions or the interface.
