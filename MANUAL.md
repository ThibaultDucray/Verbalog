# Verbalog User Manual

Verbalog records your meetings on your Mac, transcribes them, works out who said what, and lets you correct the result. Audio never leaves the Mac. Text only leaves if you choose to send it to an LLM, and you see exactly what would be sent first.

**How it works:**

1. **Record or import** the meeting: on your Mac.
2. **Transcribe** it: on your Mac.
3. **Identify the speakers**: on your Mac.
4. **Use the result** as you choose: read it, export it, or send it to an LLM or any other tool. This last step is yours: Verbalog only prepares the text, pseudonymized and shown to you first. Once it leaves your Mac, it's under the terms of whatever tool you send it to, and you're responsible for that choice.

**Contents**

1. [Installation](#1-installation)
2. [First-time setup](#2-first-time-setup)
3. [The main window](#3-the-main-window)
4. [Starting a meeting](#4-starting-a-meeting)
5. [During a meeting](#5-during-a-meeting)
6. [After a meeting](#6-after-a-meeting)
7. [Working with a finished meeting](#7-working-with-a-finished-meeting)
8. [Summaries and sending to an LLM](#8-summaries-and-sending-to-an-llm)
9. [Getting better transcripts](#9-getting-better-transcripts)
10. [Voiceprints](#10-voiceprints)
11. [Settings reference](#11-settings-reference)
12. [Privacy and your data](#12-privacy-and-your-data)
13. [Troubleshooting](#13-troubleshooting)
14. [Keyboard shortcuts](#14-keyboard-shortcuts)
15. [Known limitations](#15-known-limitations)
16. [Advanced use](#16-advanced-use)

---

## 1. Installation

**You need:**

- A Mac with Apple Silicon, running macOS 14 or later
- An internet connection for the first launch
- About 4 GB of disk space: about 2 GB for Python and its packages, and about 2 GB for the models

**Install:** download `Verbalog-<version>.dmg` from the [latest release](https://github.com/ThibaultDucray/Verbalog/releases/latest), open it and drag **Verbalog** to **Applications**. The first time you open it, macOS asks whether to open an app downloaded from the internet: click **Open**. Releases are signed and notarized by Apple, so there's no other warning.

**First launch:** Verbalog opens **Status & Models**. Click **Install** next to **Backend Python**: it downloads Python and the packages Verbalog needs, once, into `~/Library/Application Support/Verbalog`. This takes a few minutes. Then download the models (see [First-time setup](#2-first-time-setup)). After an update, if the new version needs different packages, the same place shows **Update needed**.

To build Verbalog yourself, see `CONTRIBUTING.md`.

### Uninstalling

Drag Verbalog from Applications to the Trash, then delete what it installed and downloaded:

| Location | Contents |
|---|---|
| `~/Library/Application Support/Verbalog` | Python and packages |
| `~/Library/Caches/Verbalog` | Download and bytecode caches |
| `~/Library/Preferences/app.verbalog.Verbalog.plist` | Interface preferences: language, remembered audio sources, your custom LLM site, support reminders |
| `~/.cache/huggingface/hub` | The models, in the `models--mlx-community--whisper-*` and `models--pyannote--*` folders. Other apps may share this cache |
| `~/.verbalog` | Your settings, lists, voiceprints and meetings not finished yet |
| `~/Verbalog`, or the folder chosen in Settings | Your exported transcripts: keep them if you want them |

The Hugging Face token, the Anthropic API key and the voiceprint key are in the Keychain, under the service name `verbalog`: delete them with **Keychain Access**. Deleting the voiceprint key makes saved voiceprints unreadable.

The same thing in Terminal, except your transcripts. The third line also deletes your meetings in progress:

```sh
rm -rf ~/Library/Application\ Support/Verbalog ~/Library/Caches/Verbalog
defaults delete app.verbalog.Verbalog
rm -rf ~/.verbalog
for item in hf-token anthropic-api-key voiceprint-key; do security delete-generic-password -s verbalog -a $item; done
tccutil reset All app.verbalog.Verbalog
```

The last line removes Verbalog from the Microphone and Screen & System Audio Recording lists in System Settings › Privacy & Security.

---

## 2. First-time setup

### Download the models

Click **Status & Models** at the bottom of the sidebar. This screen shows what's ready and what isn't. If something needs attention, the sidebar shows the number of items to fix.

| Model | What it does | Size | Needed? |
|---|---|---|---|
| Whisper large-v3-turbo | The final transcript | About 1.6 GB | Yes |
| Whisper small | The live preview during meetings | About 500 MB | No |
| pyannote community-1 | Separates voices on the same audio track | Downloaded with the models | Strongly recommended |

The Whisper models need no account. The speaker model is free, but its publisher asks you to accept its conditions first, so downloading it needs a Hugging Face account and token, once:

1. **Create a free account** at [huggingface.co](https://huggingface.co/join), or sign in.
2. **Accept the conditions:** open the [model page](https://huggingface.co/pyannote/speaker-diarization-community-1), fill in the short form and click **Agree and access repository**. Use the same account as for the token.
3. **Create a token:** go to [Settings › Access Tokens](https://huggingface.co/settings/tokens), click **Create new token**, choose the **Read** type, name it "Verbalog" and click **Create token**. Copy it right away: it starts with `hf_` and is shown only once.
4. **Save it in Verbalog:** on the Status & Models screen, paste it into **Hugging Face token** and click **Save Token**. It's stored in your macOS Keychain, never in a file.

Then click **Download Missing Models**.

- The token is only used to download the speaker model. Processing meetings works offline and never contacts Hugging Face.
- With a **Fine-grained** token instead of **Read**, tick **Read access to contents of all public gated repos you can access**, or the download is refused.
- If the download says access is denied, the conditions weren't accepted with the account the token belongs to.
- You can revoke the token on Hugging Face once the model is downloaded. You'd only need a new one to download the model again.

### Enter your name

Open Settings (⌘,) and fill in **Your Name** on the General tab. It replaces "Me" in transcripts.

### Grant permissions

The first time you open **New Meeting**, macOS asks for two permissions, because the form's level meters start listening right away:

- **Microphone**, to record your voice or the room
- **Screen recording**, which macOS requires for capturing system audio, meaning the remote participants on a call

If you refuse screen recording, video calls will only capture your microphone.

### Check your privacy status

The Status & Models screen also flags:

- **FileVault off:** on an SSD, only disk encryption really protects deleted audio.
- **Transcripts folder synced to the cloud:** transcripts would leave your Mac. Choose another folder in Settings.
- **Name detection missing:** the pseudonymizer has less to work with.

---

## 3. The main window

- **New Meeting**, at the top of the sidebar, starts a meeting. It's unavailable while one is recording.
- **Import Recording** (⌘I) turns an audio or video file recorded elsewhere into a meeting (see [Importing a recording](#importing-a-recording)).
- **Meetings** lists your meetings, newest first. The sidebar's search looks through titles only.
- **Status & Models** is at the bottom of the sidebar.

Each meeting shows an icon for its state:

| Icon | Meaning |
|---|---|
| Red circle | Recording now |
| Spinner | Being processed |
| Orange person with a question mark | Waiting for you to identify speakers |
| Hourglass | Recorded but not transcribed yet |
| Red triangle | Processing failed; the audio is kept |
| No icon | Finished |

The **Help** menu opens this manual on GitHub (**Verbalog Help**, ⌘?) and has the **Support Development** options (see [Supporting Verbalog](#supporting-verbalog)).

Verbalog also has a **menu bar icon**. During a meeting it shows the elapsed time and lets you take a note, pause or end the meeting. Otherwise it offers New Meeting and Open Verbalog, and shows the progress of any processing.

---

## 4. Starting a meeting

### Importing a recording

To transcribe a meeting recorded elsewhere, such as a call's recording, a voice memo or a dictaphone file, choose **Import Recording** in the sidebar or **File › Import Recording…** (⌘I), then drop the file or click **Choose a File…**.

- **Files:** WAV, M4A, MP3, AIFF, FLAC, or the sound of a video such as MP4 or MOV.
- **Title and date:** the title defaults to the file name, the date to the file's creation date. Change them if needed.
- **Languages spoken, people speaking, expected participants:** as for a new meeting. All the voices are on one track, so Verbalog separates them by sound alone: giving the number of people speaking helps a lot.
- **Import and Transcribe** copies the sound into a new meeting and processes it straight away, then the usual review follows.

Your file is only read, never changed or deleted. Verbalog deletes its own copy after transcription, like any recording. Imported meetings show **Imported recording** instead of a meeting type, and their notes are empty, since nobody took notes while they were recorded.

### Recording a meeting

Choose **New Meeting** (⌘N) and fill in the form. Only the meeting type really matters; everything else helps quality.

> Let participants know they're being recorded. Recording people without their knowledge may be illegal where you are.

### Meeting type

| Type | When to use it | What's recorded |
|---|---|---|
| **Video Call** | You're alone on your side of a call | Your mic and the system audio |
| **In Person** | Everyone is in the room | The mic only |
| **Hybrid** | Some people in the room, others remote | The mic and the system audio |

### Languages spoken

Tick the languages people will actually speak: French, English, German, Dutch, Spanish, Italian or Portuguese. They start as set in **Default meeting languages** in Settings.

- **One language:** everything is transcribed in it. A French voice can never come out as made-up English. But if someone does speak another language, their words are translated into the ticked one.
- **Several languages:** each stretch of speech is transcribed in its own language, chosen among those ticked. Each extra language makes that choice less sure, especially between close ones such as German and Dutch, so tick only what's needed. French and English together is the most common case.

### Participants

- **I'm wearing a headset** (Video Call and Hybrid): without a headset, your mic also picks up remote voices. Verbalog removes those duplicates after the meeting.
- **People in the room (including me)** and **Remote participants**: knowing the number of people makes voice separation much better. Leave them on **Unknown** if you aren't sure.
- **Expected participants**: names separated by commas, semicolons or line breaks. These names correct typos when you name speakers, help Whisper spell them, and fill the **Participants** menu on the review screen.

### Audio sources

- **Microphone input**: **System default** or a specific device.
- **System audio**: **All Mac audio**, or a single running app such as your video-call app. Choosing the app keeps other sounds out of the recording.
- **Level meters**: speak and check that **Mic** moves. On a call, check that **System** moves too.

While this form is open, Verbalog listens to your sources to drive the meters, but doesn't save anything.

Click **Start** to begin. Each new meeting starts with an empty form: the title, counts and names are blank, and the type is the **Default meeting type** from Settings. If **Reuse audio sources from the last meeting** is on in Settings, the microphone and system audio choices come back.

If you leave the title empty, the meeting is called "Meeting". You can rename it at any time.

---

## 5. During a meeting

The recording screen shows the timer, level meters, **Pause** and **End** at the top, with two columns below.

### Live column

This is a rough preview of what's being said, from the smaller Whisper model. It has no speaker names, and it doesn't use your glossary. It's replaced by the final transcript after the meeting, so don't worry about its mistakes.

You can turn it off in Settings. It's also skipped if its model isn't downloaded. Neither affects the final transcript.

### Taking notes

Type in the note field and press Return. The note is timestamped at your **first keystroke**, so it lines up with the moment you reacted to, not the moment you finished typing.

Press **⌃⌥N from any app** to open a floating note field without leaving your call. Return saves and closes it; Esc closes it. It only works during a meeting.

Start a note with a prefix to give it a type:

| You type | Result |
|---|---|
| `Budget looks tight` | A plain note |
| `! Send the proposal` | An action |
| `# We go with option B` | A decision |
| `? Who owns this` | A question |
| `~ Check his numbers` | A **private note**, never exported or sent |
| (empty line) | A bookmark |

Plain, action, decision and question notes and bookmarks all appear in your exports and in what's sent to an LLM, marked as your notes rather than as things said in the meeting. Use `~` for anything that should stay private.

A note still being typed when the meeting ends is kept.

### Naming speakers as you go

This is the most reliable way to name people, because you know who's talking.

| You type | Meaning |
|---|---|
| `@Jim` | The person speaking now is Jim |
| `@Jim+` | The next person to speak is Jim |
| `this is Jim` or `Jim speaking` | Same as `@Jim` |
| `ici c'est Jim`, `c'est Jim qui parle` or `Jim parle` | Same as `@Jim` |
| `hier ist Jim`, `hier spricht Jim`, `hier is Jim`, `Jim spreekt`, `soy Jim`, `aquí habla Jim`, `sono Jim`, `qui parla Jim`, `sou Jim` or `aqui fala Jim` | Same as `@Jim` |

Each hint names that voice **for the whole meeting**, including what they said before you typed it.

- If nobody is speaking when you start typing, the hint goes to whoever spoke in the last 5 seconds.
- Typos and first names are matched against your expected participants, so `@jmi` finds Jim.
- If you've listed participants, a phrase like "the client speaking" with an unknown name stays an ordinary note.
- On a video call, your own mic is already you, so hints only apply to the other voices.

### Commands

Type these in the note field:

| Command | Effect |
|---|---|
| `/mute` and `/unmute` | Stop and resume recording your mic only |
| `/pause` and `/resume` | Pause and resume recording |
| `/stop` | End the meeting |
| `/title New title` | Rename the meeting |
| `/participants Sophie, Marc` | Replace the expected participants |

Paused time becomes silence, so the timeline stays aligned with your notes.

### Changing the meeting type, languages and participants

Under the title, the recording screen shows the type, the languages, the counts and the expected names, for example "Hybrid · FR+EN · 4 in the room · 2 remote · Sophie, Marc". Click it to change any of them while recording: someone joins remotely, the meeting switches to English, the count was wrong, a name was missing.

- Processing reads these values after the meeting, so they apply to the whole recording, not from the moment you change them.
- **From In Person to Video Call or Hybrid**: system audio starts when you save. Remote voices from before that weren't recorded.
- **To In Person**: system audio keeps recording, but processing ignores it, including what was already recorded. Switch back if the remote part matters.
- The live preview keeps the tracks and languages it started with. The final transcript isn't affected.

### Muting your mic

Use this to keep an aside out of the transcript, such as a word to someone next to you while you're muted on the call. Click **Mute Mic**, press **⌃⌥M from any app**, use the menu bar, or type `/mute`. Do the same again, or type `/unmute`, to turn it back on.

- Only your mic stops being recorded. Remote voices on the system audio are still recorded, and the timeline stays aligned.
- **It doesn't mute you in the call.** Teams and other apps still hear your mic. Mute there too if they shouldn't hear you.
- In **In Person** meetings the mic is the only source, and in **Hybrid** meetings it's what records the room, so muting also drops everyone else in the room.

While muted, you get three reminders so you don't forget: an orange banner in the recording screen, a mic-off icon in the menu bar, and a **Muted** badge on the Dock icon. Ending the meeting turns the mute off.

### Ending

Click **End**, type `/stop`, or use the menu bar. Processing starts by itself.

---

## 6. After a meeting

### Processing

Verbalog separates the voices, transcribes, removes duplicates if needed, and merges everything. It all runs locally. An hour-long meeting takes a few minutes.

You can start a new meeting while another is being processed. Jobs aren't queued, so they run at the same time and the Mac may slow down.

**Cancel** stops processing and keeps the audio. The meeting then shows **Start Processing**, which you can use whenever you like. The same screen appears after a failure, or after a recording recovered from a crash.

### The review screen: Speakers to Identify

This screen appears only if a speaker is still unnamed, or if one of your hints needs checking. Otherwise Verbalog exports straight away.

Each speaker has a card showing their speaking time and up to three of their longest quotes.

- **Listen:** click the play button by a quote to hear 5 seconds from that point. Click again to stop.
- **Name:** type a name, or choose from the **Participants** menu. Leave it empty to keep "Speaker 1" and so on.
- **Merge:** if one person was split into two speakers, use **Merge › Same person as…** on the card. **Undo Merge** reverses it before you confirm.
- **Hints to check** lists your `@Jim` hints that couldn't be applied. Typically nobody was speaking, two voices were active at once, or a voice already had another name.

When you're done, click **Confirm and Export**.

> **Confirming deletes the audio.** This is your last chance to listen to it. You can still rename speakers and fix the text afterwards, but not listen or transcribe again.

### When the audio is deleted

Once the export is written, Verbalog checks that the transcript covers at least 90% of the audible audio.

- **If it does,** the audio is deleted, unless **Keep audio after transcription** is on.
- **If it doesn't,** the audio is kept and the meeting shows a warning. Check the transcript, then remove the audio with **Delete Audio** at the top of the meeting.

If every speaker is already named, no review screen appears and this check runs immediately.

---

## 7. Working with a finished meeting

A finished meeting has three views, chosen in the toolbar: **Transcript**, **Notes** and **Summary**.

The header shows the date, meeting type, duration and languages, plus any warnings. Click the title to rename the meeting; its exported files are renamed too.

### Finding things

**Search transcript** in the toolbar filters the blocks to those containing your text, matching what was said, speaker names and notes.

### Correcting speakers

| To change | Do this |
|---|---|
| A speaker's name everywhere | Click their name chip in the header, or choose **…› Rename This Speaker…** on a block |
| Who said a whole block | Click the speaker's name on the block and pick someone, or **New Speaker…** |
| Who said part of a block | Select the words, right-click, then **Assign Selection To** |

When you reassign a selection, the block is split at those words. Selections extend to whole words. Neighbouring blocks by the same speaker join up if they're within 2 seconds of each other.

### Correcting text

Use **…› Edit Text…**, or right-click the block. **Save** (⌘Return) applies the change and **Cancel** (Esc) discards it. Words you didn't change keep their timing.

**Delete Block** removes a block from the transcript, in the same **…** menu or by right-clicking.

### Undo

**Undo** (⌘Z) in the toolbar reverses your last transcript change, up to 20 per meeting, including renames and even after closing the app. Renaming the meeting isn't covered.

Every correction immediately updates the exported Markdown and JSON files.

### Notes view

This lists your notes in time order, including private ones. Speaker hints like `@Jim` aren't shown.

### Export menu

| Item | Result |
|---|---|
| **Markdown (.md)** | Save a copy of the transcript with your notes; private notes left out |
| **Plain Text (.txt)** | Simple text; private notes left out |
| **Full JSON (.json) — includes private notes** | Everything, including word timings and private notes. Don't share it |
| **Copy Transcript** | Copy the Markdown to the clipboard |
| **Show in Finder** | Reveal the Markdown file |
| **Share…** | The macOS share menu |
| **Delete Meeting…** | Erase the meeting: transcript, notes, summary, audio and its exported files. This can't be undone |

---

## 8. Summaries and sending to an LLM

Click **Send to LLM** in the toolbar. Nothing is sent when the window opens. The left side shows the **exact text that will be sent**: your summary prompt, then the transcript.

### Pseudonymizing

**Pseudonymize** is on by default. It replaces sensitive items with stand-ins like `PERSONNE_1` or `CLIENT_A`, and the table linking them to the real values never leaves your Mac.

| What gets replaced | How it's found |
|---|---|
| Speakers, participants and your own name, whole or in parts | Automatically |
| Your **Sensitive Terms** list | Settings › Privacy, including near-misspellings of words of 5 letters or more |
| Emails, phone numbers and amounts | Automatically |
| Other people and organizations | Local name detection, if installed |

**Read the preview before sending.** Detection isn't perfect: it can miss a name or replace an ordinary word. The line above the preview lists what was replaced. If something was missed, add it to Sensitive Terms and reopen the window.

Your private `~` notes are never included, whether this is on or off.

### Option 1: through any LLM website

1. Click **Copy Prompt + Transcript**, or one of the **Copy and open** buttons (Claude, ChatGPT, Gemini, Mistral, or your own), which also opens the site.
2. Paste with ⌘V and send it there.
3. Copy the response and paste it under **2. Get the Response**.
4. Click **Save as Summary**.

**Copy Transcript Only** skips the prompt, and **Save As…** writes the text to a file.

> Leave the **Pseudonymize** switch as it was when you copied the text until you've saved. Real names are only restored if it's still on when you click **Save as Summary**.

### Option 2: directly through the Claude API

Add an API key in Settings › LLM, then click **Generate Summary** in the send window. The summary appears as it's written and is saved when finished. **Stop** cancels it.

Before sending work material to any service, check its retention policy and any data processing agreement with your account administrator.

### Reading the summary

The saved summary appears in the **Summary** view, with **Copy** and **Show in Finder**, and as a `_synthese.md` file next to the transcript. Saving a new one replaces the old one.

Summaries aren't updated when you correct the transcript. Generate a new one if your changes matter.

### Changing the summary

The default report has an executive summary, decisions, actions, open points and commitments. To change it, edit the prompt in Settings › LLM and click **Save**; **Reset** brings back the default. `{{output_language}}` in the prompt is replaced by the chosen language.

> **Summaries are written in French by default**, whatever language the app or the meeting uses. Change **Output language** in Settings › LLM for another language.

---

## 9. Getting better transcripts

### Before the meeting

- **Give the number of people.** This helps voice separation more than anything else.
- **List expected participants.** It helps Whisper spell their names and helps match your hints.
- **Pick the right meeting type**, and tick the headset option accurately.
- **Use a good microphone in a room.** The Mac's built-in mic is poor at a distance; a USB conference mic in the middle of the table helps a lot.

### Glossary: company, product and client names

Add the proper nouns that Whisper gets wrong under **Business Glossary** in Settings › Privacy, one per line or separated by commas. Lines starting with `#` are ignored.

```
Acme
Kerguelen Energy
smart metering
```

It applies to every meeting processed after you save it.

- **It's a hint, not a guarantee.** Whisper becomes more likely to use your spelling. A name that sounds exactly like an ordinary spelling can still come out differently. Fix these with **Edit Text…**.
- **Keep it short.** Whisper can only take a limited amount of hint text, so keep it to the words it actually gets wrong. Participants come first, then the glossary, then sensitive terms. If the list is too long, the last terms are dropped and the meeting shows a warning.
- **Don't list confidential names here.** Glossary terms are written into the exported Markdown's header, so they can reach an LLM. Put them under **Sensitive Terms** instead: Whisper still gets them as hints, and they're pseudonymized and left out of that list.

### During the meeting

Use `@Name` when you first hear someone speak. It's quick and takes priority over everything else.

### Languages

Verbalog transcribes French, English, German, Dutch, Spanish, Italian and Portuguese, alone or mixed in one meeting. Tick only the languages actually spoken (see [Languages spoken](#languages-spoken)): with French alone, French voices can't be mistaken for English. Other languages aren't supported.

French and English are the most tested. The other languages rely on the same Whisper model, which handles them well, but they've been checked on synthesized speech only so far.

**Italian and pseudonymization:** the automatic name detection that helps pseudonymize text sent to an LLM isn't available in Italian, because the only Italian model forbids commercial use. In Italian meetings, list people and companies in **Expected participants** and in your sensitive terms: those are always pseudonymized.

---

## 10. Voiceprints

A voiceprint lets Verbalog recognize a person's voice automatically in later meetings. It's optional: live hints and the review screen work without one.

To record one, go to Settings › Voiceprints and choose **Record a Voiceprint…**, which requires the speaker model:

1. Enter the name.
2. Leave **This is my own voice** on, or turn it off and confirm **This person has given explicit consent**.
3. Click **Start** and read the displayed text aloud for 30 seconds.

The recording is deleted as soon as the voiceprint is computed.

If several names are available for one voice, your `@Jim` hints win over voiceprints, and voiceprints come before the review screen. Each voiceprint can name only one speaker per meeting.

> Voiceprints are biometric data (GDPR, article 9). They're encrypted on this Mac with a key in your Keychain, and **Delete** removes one at any time. Recording a colleague's voice requires their explicit consent.

---

## 11. Settings reference

Open with ⌘,.

### General

| Setting | Effect |
|---|---|
| **Language** | Interface, messages and export headings: English or French. Requires a restart |
| **Your Name** | Used for your own mic track, and in pseudonymizing |
| **Transcripts Folder** | Where exports go. Default `~/Verbalog`. Warns if the folder syncs to the cloud |
| **Default meeting type** | Preselected in the New Meeting form |
| **Default meeting languages** | Ticked in the New Meeting form. French and English at first |
| **Reuse audio sources from the last meeting** | Preselects the last microphone and system audio. Everything else starts empty |
| **Live transcript during meetings** | The preview column |
| **Note timestamps** | **At first keystroke** (default) or **When saved** |
| **Keep audio after transcription** | Not recommended; keeps recordings on disk |
| **Whisper model**, **Diarization model** | Model names. Download any new one from Status & Models |

### LLM

| Setting | Effect |
|---|---|
| **Your LLM** | A name and address, added to the **Copy and open** buttons |
| **Summary Prompt** | The instructions sent with the transcript. **Save** applies, **Reset** restores |
| **Output language** | French (default), English, German, Dutch, Spanish, Italian or Portuguese |
| **API key**, **Model** | For direct summaries. The key is kept in your Keychain |

### Privacy

| Setting | Effect |
|---|---|
| **Pseudonymize by default before sending** | The initial position of the switch in the send window |
| **Sensitive Terms** | One per line, optionally with a category: `CLIENT: Acme`, `PROJET: Phoenix` |
| **Business Glossary** | See [Getting better transcripts](#9-getting-better-transcripts) |

### Voiceprints

See [Voiceprints](#10-voiceprints).

---

## 12. Privacy and your data

**What stays on your Mac:** all audio, all transcription and speaker processing, voiceprints, and the pseudonym tables.

**What uses the network:**

- Installing Python and its packages, on first launch and after an update that needs new ones, from the Python Package Index and GitHub
- Downloading models, once, from Hugging Face
- Sending to an LLM, only when you choose to and only the text you've previewed
- Opening the LLM site in your browser, if you use those buttons
- Opening the support page or this manual in your browser, from the Help menu or the support invitation

**Where things are:**

| Location | Contents |
|---|---|
| `~/Verbalog` | Exports: `<date>_<title>.md`, `.json` and `_synthese.md` |
| `~/.verbalog/sessions/<id>/` | Working data per meeting, private to your user: audio until deleted, notes, transcript, pseudonym table, undo history |
| `~/.verbalog/config.toml` | Your settings |
| `~/.verbalog/glossary.txt`, `sensitive.txt` | Your lists |
| `~/.verbalog/voiceprints/` | Encrypted voiceprints |
| `~/.verbalog/backend.log` | Technical log of the backend |
| macOS Keychain | Hugging Face token, API key, voiceprint key |
| `~/Library/Application Support/Verbalog` | Python and packages, no personal data |

**Good practice:**

- Turn on FileVault. On an SSD, deleted audio can only be reliably protected by disk encryption.
- Keep the transcripts folder out of iCloud, Dropbox and similar. `~/Documents` is often synced to iCloud.
- Don't send the `.json` file anywhere: it contains your private notes.

---

### Supporting Verbalog

Verbalog is free and open source, and stays fully functional whether or not you contribute. If it saves you time, you can support its development with a voluntary contribution: **Help › ☕ Support Development…** opens a Stripe payment page in your browser, where you choose the amount. A contribution doesn't unlock anything.

After 10 finished meetings, Verbalog shows a discreet invitation above the meeting, never during a recording or processing:

- **Support Development** opens the payment page.
- **Maybe Later** waits for 20 more meetings or 60 days, whichever comes first.
- **I've Already Supported** and **Don't Show This Again** stop the invitations for good.

Verbalog never checks whether you paid and sends nothing anywhere: the choice is stored only in its preferences on this Mac. **I've Already Supported** is also in the Help menu.

---

## 13. Troubleshooting

**The app says the Whisper model isn't downloaded, or Start Processing is disabled.**
Open Status & Models and click **Download Missing Models**.

**Voices aren't separated.**
The speaker model is probably missing, or the meeting shows a warning that diarization was unavailable. Check Status & Models. If the download failed, make sure you've accepted the licence on the model page and saved your token.

**"System audio not captured" or the System meter doesn't move.**
Check Screen Recording for Verbalog in System Settings › Privacy & Security, then restart the app. Without it, only the mic is recorded. If you chose a single app as the source, check it's the one producing the sound.

**The Mic meter doesn't move.**
Check Microphone in System Settings › Privacy & Security, and the selected input in the form.

**No sound when playing extracts on Bluetooth headphones.**
This has been seen on a Sony WH-CH520 after a call: macOS reports normal playback, but the headphones stay silent. Verbalog now tells the headphones that playback has started, which is intended to fix this. If it's still silent, play a few seconds of music in another app and try again, or switch the output to the Mac's speakers in the Sound menu. Do this before confirming the review screen, since confirming deletes the audio.

**People were merged into one speaker, or one person was split into two.**
Give the number of people next time. To fix it now, use **Merge** on the review screen. In a finished meeting, reassign the blocks to the right speaker.

**A passage has rough punctuation or an approximate speaker.**
Verbalog recovers speech that the speaker model mistook for silence, and these passages can be less polished. Fix them with the editing tools.

**A proper noun keeps coming out wrong.**
Add it to the glossary for future meetings, and fix this meeting with **Edit Text…**.

**The live preview says it's falling behind.**
The Mac couldn't keep up, so part of the preview was skipped. The final transcript isn't affected.

**"Audio kept" warning on a finished meeting.**
The transcript covered less than 90% of the audible audio. Check the transcript, then click **Delete Audio** when you're satisfied.

**The app crashed or was quit during a meeting.**
The audio captured so far is kept. Open the meeting and click **Start Processing**. If you quit during processing, it also restarts this way.

**A processing error appears.**
The audio is kept, and the error is shown on the meeting. `~/.verbalog/backend.log` has the technical details.

---

## 14. Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New meeting |
| ⌘, | Settings |
| ⌃⌥N | Quick note from any app, during a meeting |
| ⌃⌥M | Mute or unmute your mic from any app, during a meeting |
| Return | Save a note; an empty line creates a bookmark |
| Esc | Close the quick note, or cancel text editing |
| ⌘Z | Undo the last transcript change |
| ⌘Return | Save when editing a block |

---

## 15. Known limitations

- Editing tools only work on finished meetings, not on the review screen.
- Once the audio is deleted, a meeting can't be replayed or transcribed again.
- Audio that's been kept can't be reprocessed from a finished meeting's screen. See [Advanced use](#16-advanced-use).
- Summaries don't update when you correct the transcript.
- ⌘Z pressed while typing in the search box may undo a transcript change instead.
- The glossary doesn't apply to the live preview, and it's a hint rather than a guarantee.
- Only French, English, German, Dutch, Spanish, Italian and Portuguese are supported for transcription.
- Name detection for pseudonymization doesn't cover Italian.
- Processing jobs run at the same time rather than in a queue.

---

## 16. Advanced use

### Settings only available in the file

Edit `~/.verbalog/config.toml`. Values you leave out use their defaults.

| Section and key | Default | Effect |
|---|---|---|
| `speakers.naming_patterns` | See below | Phrases recognized as naming a speaker. `{nom}` stands for the name |
| `speakers.lookback_seconds` | `5` | How far back a hint looks when nobody is speaking |
| `speakers.voiceprint_threshold` | `0.75` | How close a voice must be to match a voiceprint |
| `speakers.voiceprints_dir` | `~/.verbalog/voiceprints` | Voiceprint location |
| `transcription.live_model` | `mlx-community/whisper-small-mlx` | Live preview model |
| `transcription.glossary_file` | `~/.verbalog/glossary.txt` | Glossary location |
| `privacy.sensitive_file` | `~/.verbalog/sensitive.txt` | Sensitive terms location |
| `capture.mic_device` | `default` | Initial microphone in the form |
| `capture.system_source` | `all` | Initial system audio source in the form |
| `diarization.device` | `mps` | Where the speaker model runs |

Default naming patterns:

```toml
naming_patterns = ["ici c'est {nom}", "c'est {nom} qui parle", "{nom} parle", "this is {nom}", "{nom} speaking"]
```

### Command line

`<id>` is the meeting's folder name in `~/.verbalog/sessions`. With the downloaded app:

```sh
PYTHONPATH=/Applications/Verbalog.app/Contents/Resources/backend \
  ~/Library/Application\ Support/Verbalog/venv/bin/python -m verbalog <command>
```

From a copy of the source code, run `.venv/bin/python -m verbalog <command>` in the project folder.

| Command | Effect |
|---|---|
| `doctor` | Readiness report |
| `setup` | Download models |
| `process <id>` | Transcribe a meeting whose audio still exists. This replaces the transcript and clears its undo history |
| `finalize <id>` | Export and validate |
| `rename <file> <speaker> <name>` | Rename a speaker |
| `edit <id> --op <json>` | Apply a transcript correction |
| `retitle <id> <title>` | Rename a meeting |
| `prepare <id>` | Print what would be sent to an LLM |
| `summarize <id>` | Summarize through the Claude API |
| `save-summary <id>` | Save a summary read from standard input |
| `live <id>` | Run the live preview on a meeting |
| `enroll` | Manage voiceprints: `--list`, `--delete <name>`, or `--name`, `--wav` with `--self` or `--consent` |
| `purge-audio <id>` | Delete a meeting's audio |
| `delete <id>` | Erase a meeting and its exports |
| `config` | Show settings, or change them with `--set <json>` |

Every command writes JSON events to standard output, one per line.

### Environment variables

| Variable | Effect |
|---|---|
| `VERBALOG_HOME` | Use another folder instead of `~/.verbalog` |
| `VERBALOG_ROOT` | Make the app run the backend from a copy of the source code, with its `.venv` |
