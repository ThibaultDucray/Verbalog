# Privacy notice

*Last updated: 13 November 2026, for Verbalog 0.4.1.*

Verbalog records meetings, so it handles some of the most sensitive data there is: voices, conversations, names. This notice says exactly what the app stores, where, for how long, and what can leave your Mac.

## In short

- **The developer collects nothing.** No account, no analytics, no telemetry, no crash reporting, no advertising, no update check. Verbalog doesn't know who uses it, how often, or for what.
- **Verbalog stores a lot, but only on your Mac:** audio while a meeting is processed, transcripts, notes, speaker names, and voiceprints if you create them.
- **Text leaves your Mac only when you send it**, to the LLM or tool of your choice, after you've seen it, with names pseudonymized by default.
- **You control deletion:** audio is deleted after each meeting is validated, and everything else can be deleted from the app or by hand.

## What the developer receives

Nothing from the app. The only data the developer can receive comes from outside it, and only if you choose to:

- **A contribution**, through **Help › Support Development**. Payment is handled by Stripe on its own page, under [Stripe's privacy policy](https://stripe.com/privacy). The developer receives what Stripe gives every merchant: typically your name, email address, country and the amount. It's used only to keep accounts, and deleted automatically from the developer's records after 12 months. Stripe keeps its own records under its policy. The app never knows whether you contributed: **I've Already Supported** is only stored on your Mac.
- **An issue, a discussion or a security report on GitHub.** What you write there is under [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement), and issues are public. Never attach real recordings or transcripts.

Downloading Verbalog from GitHub is subject to GitHub's own logging. The developer only sees aggregate download counts.

## What Verbalog stores on your Mac

All of this stays on your Mac. Folders under `~/.verbalog` are readable only by your macOS user.

### For each meeting

| Data | Where | Kept until |
|---|---|---|
| Audio: your microphone (`mic.wav`) and the call's sound (`system.wav`) | `~/.verbalog/sessions/<meeting>/` | The transcript is validated, then deleted automatically. Kept longer only if you turn on **Keep audio after transcription**, or if Verbalog warns that something may be missing: you then delete it with **Delete Audio** |
| Meeting details: title, date, type, languages, expected participants' names, audio sources | Same folder, `session.json` | The meeting is deleted |
| Your notes, including private `~` notes | Same folder, `notes.jsonl` | The meeting is deleted |
| The provisional live transcript | Same folder, `live.jsonl` | The meeting is deleted |
| The transcript, with word timings, speaker names, and a few short quotes per speaker for the review screen | Same folder, `transcript.json` | The meeting is deleted |
| The pseudonym table (real name ↔ pseudonym) used when sending to an LLM | Same folder, `.mapping.json` | The meeting is deleted |
| Undo history of your edits | Same folder, `undo/` | The meeting is deleted |
| Exports: Markdown, JSON (which contains your private notes) and the summary | `~/Verbalog`, or the folder chosen in Settings | You delete them, or delete the meeting in Verbalog |

**Deleting a meeting** in Verbalog deletes its folder and its exported files.

### Voiceprints

A voiceprint lets Verbalog recognize someone's voice in later meetings. It's optional, created only when you record or save one, and it's **biometric data**.

- Stored in `~/.verbalog/voiceprints/`, encrypted (Fernet: AES-128 and HMAC-SHA256) with a key kept in your macOS Keychain.
- Never leaves your Mac and is never sent to an LLM.
- Kept until you delete it in **Settings › Voiceprints**. Deleting the Keychain key makes all voiceprints unreadable.

### Settings and app data

| Data | Where |
|---|---|
| Settings, including your name | `~/.verbalog/config.toml` |
| Your glossary and sensitive terms lists | `~/.verbalog/glossary.txt`, `sensitive.txt` |
| Technical log of the last processing run: progress and error messages, which may include a meeting's title or file paths, but no audio | `~/.verbalog/backend.log` |
| Interface preferences: language, remembered audio sources, your custom LLM site, and for the support invitation, the identifiers of finished meetings (their date and title), used only to count them | `~/Library/Preferences/app.verbalog.Verbalog.plist` |
| Hugging Face token, Anthropic API key, voiceprint key | macOS Keychain, service `verbalog` |
| Python, its packages and caches: no personal data | `~/Library/Application Support/Verbalog`, `~/Library/Caches/Verbalog` |
| Speech models: no personal data | `~/.cache/huggingface/hub` |

### macOS permissions

- **Microphone**: to record your voice, or the room.
- **Screen & System Audio Recording**: macOS grants system audio only through this permission, to hear remote participants. Verbalog uses the sound only: it never records, keeps or looks at the screen.

## What can leave your Mac

| When | What is sent | To whom |
|---|---|---|
| First launch, and updates that need new packages | Standard download requests | The Python Package Index and GitHub, to install Python and its packages |
| Downloading the models, once | Standard download requests, and your Hugging Face token for the speaker separation model | Hugging Face |
| **Only when you choose to send a meeting to an LLM** | Exactly the text shown in the preview: your prompt, then the meeting's title, date, participants, transcript and exported notes, pseudonymized by default. Never your private notes, voiceprints or the audio | The provider you pick: copied for you to paste, opened in your browser (Claude, ChatGPT, Gemini, Mistral, or your own site), or sent to Anthropic's API with your own key |
| Links you click | Nothing from the app; your browser opens the page | GitHub (the manual), Stripe (support), the LLM site |

Nothing else. Recording, transcription, speaker separation, voice recognition and pseudonymization run on your Mac. Processing runs with Hugging Face offline mode on and pyannote's usage statistics turned off, so the libraries Verbalog relies on don't report anything either.

Once text has been sent to an LLM or another tool, it's under that provider's terms, not Verbalog's. Choosing what to send, and where, is your decision and your responsibility.

## Recording other people

Verbalog records the people you meet, not just you. You decide why and when to record, so you, or your organization, are responsible for that recording under data protection laws such as the GDPR:

- **Tell participants** they're being recorded, before recording. Recording people without their knowledge may be illegal where you are.
- **Voiceprints** are biometric data: create one only with the person's explicit consent, and delete it if they ask.
- **Answer requests**: if a participant asks for their data to be deleted, delete the meeting, or edit the transcript and exports.

This is general information, not legal advice. The developer has no access to your recordings, so can't answer these requests for you.

## Protecting your data

- **Turn on FileVault.** On an SSD, deleted audio can only be reliably protected by disk encryption.
- **Keep the transcripts folder out of cloud sync** (iCloud Drive, Dropbox…): `~/Documents` is often synced to iCloud, which would copy your transcripts off your Mac. Verbalog warns you in Settings when the chosen folder is synced.
- **Don't share the exported `.json`**: it contains your private notes.

## Deleting everything

- **One meeting's audio**: **Delete Audio** on the meeting.
- **One meeting**: delete it in Verbalog. Its folder and exports are removed.
- **One voiceprint**: **Settings › Voiceprints**.
- **Everything**: follow [Uninstalling](MANUAL.md#uninstalling) in the manual. It lists every location and the Keychain items.

## Changes and contact

Changes to this notice are tracked in this repository's history. For a question, open an issue. For anything sensitive, use **Report a vulnerability** in the repository's **Security** tab, which is private.

Verbalog is developed by Thibault Ducray.
