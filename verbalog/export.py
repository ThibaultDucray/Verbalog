# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""The Markdown meant for the LLM, and the JSON kept for reprocessing."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import config
from .i18n import language, t
from .merge import note_positions
from .notes import EXPORT_LABELS
from .session import Session, write_json_atomic


def hms(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def _yaml_str(value: str, in_flow: bool = False) -> str:
    # JSON strings are valid YAML; quote only when a bare value would be misread.
    # A comma only matters inside a [flow, list].
    specials = ':#[]{}&*!|>\'"%@`\n' + ("," if in_flow else "")
    if value == "" or any(c in value for c in specials) or value != value.strip():
        return json.dumps(value, ensure_ascii=False)
    return value


def _participants(doc: dict[str, Any], user_name: str) -> list[str]:
    lines = []
    for speaker in doc["speakers"].values():
        details = []
        if user_name and speaker["display"] == user_name:
            details.append(t("organizer"))
        # An imported file is one mixed track: nobody is "in the room" or "remote" there.
        if speaker.get("origin") in ("salle", "distant") and not doc.get("imported"):
            details.append(t({"salle": "room", "distant": "remote"}[speaker["origin"]]))
        if not speaker.get("name"):
            details.append(t("unidentified"))
        lines.append(speaker["display"] + (f" ({', '.join(details)})" if details else ""))
    return list(dict.fromkeys(lines))


def _note_block(note: dict[str, Any]) -> str:
    head = f"> **{t(EXPORT_LABELS[note['type']])} [{hms(note['t'])}]**"
    return f"{head} {note['text']}" if note.get("text") else head


def render_markdown(doc: dict[str, Any], user_name: str = "") -> str:
    lines = ["---", f"title: {_yaml_str(doc['title'])}", f"date: {doc['date']}", f"duration: {hms(doc['duration'])}"]
    lines.append(f"context: {'import' if doc.get('imported') else doc['context']}")
    lines.append(f"languages: [{', '.join(doc.get('languages', []))}]")
    participants = _participants(doc, user_name)
    if participants:
        lines.append("participants:")
        lines.extend(f"  - {_yaml_str(p)}" for p in participants)
    if doc.get("expected_participants"):
        lines.append(f"expected_participants: [{', '.join(_yaml_str(p, True) for p in doc['expected_participants'])}]")
    if doc.get("glossary"):
        lines.append(f"glossary: [{', '.join(_yaml_str(g, True) for g in doc['glossary'])}]")
    lines += ["---", "", f"# {doc['title']}", ""]

    # Private notes stop here: they exist only in the JSON, which is never sent anywhere.
    notes = [n for n in doc.get("notes", []) if n["type"] in EXPORT_LABELS]

    summary = [n for n in notes if n["type"] in ("action", "decision", "question")]
    if summary:
        lines += [f"## {t('Organizer notes (summary)')}"]
        lines += [f"- {t(EXPORT_LABELS[n['type']])} [{hms(n['t'])}] {n['text']}" for n in summary]
        lines.append("")

    lines += [f"## {t('Transcript')}", ""]
    colon = " :" if language() == "fr" else ":"  # French typography
    turns = doc["turns"]
    positions = note_positions(turns, [n["t"] for n in notes])
    after: dict[int, list[dict[str, Any]]] = {}
    for note, position in zip(notes, positions):
        after.setdefault(position, []).append(note)

    for note in after.get(-1, []):
        lines += [_note_block(note), ""]
    for index, turn in enumerate(turns):
        speaker = doc["speakers"][turn["label"]]["display"]
        lines += [f"**[{hms(turn['start'])}] {speaker}{colon}** {turn['text']}", ""]
        for note in after.get(index, []):
            lines += [_note_block(note), ""]
    return "\n".join(lines).rstrip() + "\n"


def output_paths(session: Session, cfg: dict[str, Any]) -> tuple[Path, Path]:
    directory = config.expand(cfg["general"]["output_dir"])
    directory.mkdir(parents=True, exist_ok=True)
    return directory / f"{session.stem}.md", directory / f"{session.stem}.json"


def save_outputs(session: Session, doc: dict[str, Any], cfg: dict[str, Any]) -> dict[str, str]:
    doc["title"] = session.data["title"]
    md_path, json_path = output_paths(session, cfg)
    md_path.write_text(render_markdown(doc, cfg["general"]["user_name"]), encoding="utf-8")
    write_json_atomic(json_path, doc)
    session.save_transcript(doc)

    previous = session.data.get("outputs") or {}
    outputs = dict(previous, md=str(md_path), json=str(json_path))
    # The title sets the file name: don't leave copies under the old one.
    for key in ("md", "json"):
        old = previous.get(key)
        if old and old != outputs[key] and Path(old).exists():
            Path(old).unlink()
    session.set(outputs=outputs)
    return outputs
