# Security and privacy

Verbalog records conversations, so a privacy flaw is a security flaw here.

## Reporting a problem

Please report privately, not in a public issue: use **Report a vulnerability** in this repository's **Security** tab.

Describe the problem and how to reproduce it. Don't include real recordings or transcripts; synthesized audio and made-up names are enough.

## What counts

- Audio, text or metadata leaving the Mac without the user asking, including through a dependency
- Pseudonymization missing a name in what's sent to an LLM
- Voiceprints readable without the Keychain key, or session folders readable by other users
- Audio surviving after Verbalog says it was deleted, beyond what the manual already explains about SSDs
- Anything that weakens the signed releases or the update mechanism

## Supported versions

Only the latest release receives fixes.
