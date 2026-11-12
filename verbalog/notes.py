# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Parse notes.jsonl: typed prefixes, live speaker naming hints, name matching."""

from __future__ import annotations

import difflib
import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

PREFIXES = {"!": "action", "#": "decision", "?": "question", "~": "private"}
EXPORT_LABELS = {"note": "NOTE", "action": "ACTION", "decision": "DECISION", "question": "QUESTION", "bookmark": "BOOKMARK"}


@dataclass
class Note:
    t: float
    type: str
    text: str = ""
    speaker: str | None = None  # naming hints only
    announce: bool = False  # "@Jim+": the next person to speak


def _fold(name: str) -> str:
    decomposed = unicodedata.normalize("NFKD", name)
    return "".join(c for c in decomposed if not unicodedata.combining(c)).casefold().strip()


def match_participant(name: str, expected: list[str]) -> str | None:
    """Closest expected participant, tolerating typos ("jmi" -> "Jim") and first-name-only input."""
    folded = {_fold(p): p for p in expected}
    target = _fold(name)
    if target in folded:
        return folded[target]
    for key, value in folded.items():
        if target and target in key.split():
            return value
    close = difflib.get_close_matches(target, list(folded), n=1, cutoff=0.6)
    if close:
        return folded[close[0]]
    # Compare against first names too, for a typo on "Sophie" when "Sophie Martin" is expected.
    firsts = {key.split()[0]: value for key, value in folded.items() if key}
    close = difflib.get_close_matches(target, list(firsts), n=1, cutoff=0.6)
    return firsts[close[0]] if close else None


def _pattern_regexes(patterns: list[str]) -> list[re.Pattern[str]]:
    regexes = []
    for pattern in patterns:
        body = re.escape(pattern.replace("’", "'")).replace(r"\{nom\}", r"(?P<nom>[^\W\d_][\w'\- ]{0,39})")
        regexes.append(re.compile(rf"^{body}[.!]?$", re.IGNORECASE))
    return regexes


def parse_note(t: float, raw: str, patterns: list[str], expected: list[str]) -> Note:
    text = raw.strip()
    if not text:
        return Note(t, "bookmark")

    if text.startswith("@"):
        name = text[1:].strip()
        announce = name.endswith("+")
        name = name.rstrip("+").strip()
        if name:
            return Note(t, "speaker", speaker=match_participant(name, expected) or name, announce=announce)

    if text[0] in PREFIXES:
        return Note(t, PREFIXES[text[0]], text[1:].strip())

    normalized = text.replace("’", "'")
    for regex in _pattern_regexes(patterns):
        match = regex.match(normalized)
        if not match:
            continue
        name = match.group("nom").strip()
        known = match_participant(name, expected)
        # "le client parle" fits "{nom} parle": with a participant list, an unknown
        # name means an ordinary note, and a note must never be silently consumed.
        if known or not expected:
            return Note(t, "speaker", speaker=known or name)

    return Note(t, "note", text)


def load_notes(path: Path, patterns: list[str], expected: list[str]) -> list[Note]:
    if not path.exists():
        return []
    notes = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue  # a line cut by a crash; the others are intact
        notes.append(parse_note(float(row["t"]), row.get("text", ""), patterns, expected))
    return sorted(notes, key=lambda n: n.t)
