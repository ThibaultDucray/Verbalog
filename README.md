# Verbalog

Local meeting notes for macOS. Verbalog records a meeting on your Mac, transcribes it, works out who said what, and lets you correct the result. **Audio never leaves the Mac.**

![Verbalog showing a finished meeting's transcript, with named speakers and a decision note](screenshots/Verbalog%20-%201%20-%20transcript.png)

- Records your mic and the call's audio (Teams, Zoom, Meet…), a room, or both, or imports an audio or video file recorded elsewhere
- Transcribes locally with Whisper, accelerated by Apple's MLX, in French, English, German, Dutch, Spanish, Italian and Portuguese, alone or mixed in one meeting
- Separates voices with pyannote, then lets you name each speaker from short audio extracts
- Timestamped notes while you listen: actions, decisions, questions, bookmarks, private notes
- Meeting details stay editable until processing: type, languages, number and names of participants, if someone joins or the meeting switches language
- Processes each meeting when it ends, or later if you prefer, to record several meetings in a row
- Exports Markdown and JSON, and prepares an optional summary through the LLM of your choice, pseudonymized first and previewed before anything is sent

Free and open source, with no account, no subscription and no tracking.

## How it works

1. **Record or import** the meeting: on your Mac.
2. **Transcribe** it: on your Mac.
3. **Identify the speakers**: on your Mac.
4. **Use the result** as you choose: read it, export it, or send it to an LLM or any other tool. This last step is yours: Verbalog only prepares the text, pseudonymized and shown to you first. Once it leaves your Mac, it's under the terms of whatever tool you send it to, and you're responsible for that choice.

## Requirements

- A Mac with Apple Silicon, running macOS 14 or later
- An internet connection for the first launch, and about 4 GB of disk space: Verbalog installs Python and its packages, then the models

## Install

Download `Verbalog-<version>.dmg` from the [latest release](../../releases/latest), open it and drag Verbalog to Applications. Releases are signed with a Developer ID and notarized by Apple.

To uninstall, see [Uninstalling](MANUAL.md#uninstalling) in the manual: Verbalog also installs Python and models outside the app.

To build it yourself instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

## First run

1. **Status & Models** opens by itself: click **Install** to set up Python (a few minutes, once), then **Download Missing Models**. Whisper needs no account. The speaker separation model needs a free Hugging Face token, once, before downloading:
   1. With a free [Hugging Face account](https://huggingface.co/join), open the [model page](https://huggingface.co/pyannote/speaker-diarization-community-1) and click **Agree and access repository**.
   2. In [Settings › Access Tokens](https://huggingface.co/settings/tokens), create a token of type **Read** and copy it (`hf_…`).
   3. Paste it into **Hugging Face token** on Status & Models and click **Save Token**. It's kept in your Keychain and used only for this download.

   Without it, transcription still works, but voices sharing an audio track aren't told apart. Details in the [manual](MANUAL.md#download-the-models).
2. **Settings** (⌘,): enter your name. The language can be changed there too (English or French; restart required).
3. **New Meeting**: macOS asks for the microphone and screen-recording permissions the first time. Screen recording is how macOS lets an app capture system audio, meaning the remote participants on a call.

Let participants know they're being recorded. Recording people without their knowledge may be illegal where you are.

## Using it

- **During a meeting**: type notes and press Return; ⌃⌥N opens the note field from any app. The timestamp is taken at the first keystroke.

  | Prefix | Meaning |
  |---|---|
  | `!` `#` `?` | action, decision, question |
  | `~` | private note, never exported |
  | `@Jim` / `ici c'est Jim` | the person speaking is Jim, across the whole meeting |
  | `@Jim+` | the next person to speak is Jim |
  | empty line | bookmark |
  | `/mute` `/unmute` | stop or resume recording your mic only (⌃⌥M from any app) |
  | `/pause` `/resume` `/stop` `/title …` `/participants …` `/details` | commands |

- **During a meeting, or before processing it**: **Edit Details…** (⇧⌘D, or `/details`) changes the meeting type, languages, and the number and names of participants. Processing uses them.
- **After a meeting**: processing starts by itself, unless you turn that off in Settings to process meetings later, one after the other. If speakers remain unnamed, a review screen shows their quotes and lets you replay them, name them or merge them. Validating it exports the files and deletes the audio.
- **Sending to an LLM**: *Send to LLM* shows the exact text that would leave the Mac, pseudonymized by default. Copy it, save it, or open Claude, ChatGPT, Gemini, Mistral or your own URL, then paste the response back to restore the real names. With an Anthropic API key, the app can also generate the summary directly.

The [user manual](MANUAL.md) covers everything else.

## Privacy

Audio, transcription, speaker separation and voiceprints stay on your Mac. The network is used only to install Python and its packages on first launch, to download the models from Hugging Face, and to send text to an LLM when you choose to. There is no analytics or telemetry, including from the libraries Verbalog uses.

Files go to `~/Verbalog`; working data is in `~/.verbalog`. The [privacy notice](PRIVACY.md) lists everything Verbalog stores, for how long, and what can leave your Mac.

## Supporting development

Verbalog is free and stays fully functional whether or not you contribute. If it saves you time, you can [support its development](https://buy.stripe.com/aFa3cx8dV4ht6uicYxaMU00) with a voluntary contribution of the amount you choose. It doesn't unlock anything; the app also offers it from **Help › Support Development**, and asks discreetly after a few meetings.

## Contributing

Bug reports and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Never attach real recordings or transcripts to an issue. To report a security or privacy problem, see [SECURITY.md](SECURITY.md).

## Licence

Verbalog is free software, released under the [GNU General Public License v3.0 or later](LICENSE). You may use, study, share and modify it; versions you distribute must stay under the same licence, with their source code available.

The app bundles [uv](https://github.com/astral-sh/uv) (MIT licence, notice in `Verbalog.app/Contents/Resources/Licenses`). The Python packages and models it installs are downloaded from their publishers, under their own licences.

## Credits

Verbalog builds on [Whisper](https://github.com/openai/whisper) by OpenAI, [MLX](https://github.com/ml-explore/mlx) and [mlx-whisper](https://github.com/ml-explore/mlx-examples) by Apple, and [pyannote.audio](https://github.com/pyannote/pyannote-audio) with the [speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) model by pyannote.
