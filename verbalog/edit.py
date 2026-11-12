# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Corrections after processing: reattribute, rewrite or delete speech, with undo.

Every edit regenerates the exports from the JSON, without transcribing again.
Character offsets are Unicode code points in the turn's text.
"""

from __future__ import annotations

import difflib
import json
import re
from typing import Any

from . import export, merge, naming, config
from .i18n import t
from .session import Session, write_json_atomic

MAX_UNDO = 20
NEW_LABEL_PREFIX = {"mic": "SALLE", "system": "DISTANT"}


# Undo: one snapshot of the transcript per edit, in the session's private directory.

def _undo_files(session: Session) -> list:
    directory = session.path / "undo"
    return sorted(directory.glob("*.json")) if directory.exists() else []


def snapshot(session: Session, doc: dict[str, Any]) -> None:
    directory = session.path / "undo"
    directory.mkdir(mode=0o700, exist_ok=True)
    files = _undo_files(session)
    number = int(files[-1].stem) + 1 if files else 1
    write_json_atomic(directory / f"{number:06d}.json", doc)
    for old in files[: max(0, len(files) + 1 - MAX_UNDO)]:
        old.unlink()


def clear_undo(session: Session) -> None:
    for file in _undo_files(session):
        file.unlink()


def _undo(session: Session) -> dict[str, Any]:
    files = _undo_files(session)
    if not files:
        raise ValueError(t("Nothing to undo."))
    doc = json.loads(files[-1].read_text(encoding="utf-8"))
    outputs = export.save_outputs(session, doc, config.load())
    files[-1].unlink()
    return {"session": session.id, "outputs": outputs}


# Turns

def _turn_index(doc: dict[str, Any], op: dict[str, Any]) -> int:
    """The app sends the turn's start too: an index alone could hit the wrong turn on a stale view."""
    index = op["turn"]
    turns = doc["turns"]
    if not 0 <= index < len(turns) or abs(turns[index]["start"] - op["start"]) > 0.001:
        raise ValueError(t("The transcript has changed: try again."))
    return index


def _from_words(template: dict[str, Any], words: list[dict[str, Any]], label: str | None = None) -> dict[str, Any]:
    turn = {
        "start": words[0]["start"],
        "end": max(w["end"] for w in words),
        "label": label or template["label"],
        "track": template["track"],
        "words": words,
    }
    merge.finish_turn(turn)
    return turn


def _join_neighbours(turns: list[dict[str, Any]], first: int, last: int) -> None:
    """Close the seams an edit opened in [first, last], as processing would have grouped them."""
    for index in range(min(last + 1, len(turns) - 1), max(first, 1) - 1, -1):
        before, after = turns[index - 1], turns[index]
        if (
            before["label"] == after["label"]
            and before["track"] == after["track"]
            and after["start"] - before["end"] <= merge.NEW_TURN_PAUSE
        ):
            turns[index - 1 : index + 1] = [_from_words(before, before["words"] + after["words"])]


def _selected_words(turn: dict[str, Any], first: int, last: int) -> tuple[int, int]:
    """Word range touched by the characters [first, last), whole words only."""
    offset = -(len(turn["words"][0]["w"]) - len(turn["words"][0]["w"].lstrip())) if turn["words"] else 0
    selected: list[int] = []
    for index, word in enumerate(turn["words"]):
        lead = len(word["w"]) - len(word["w"].lstrip())
        begin, end = offset + lead, offset + len(word["w"].rstrip())
        if begin < last and first < end:
            selected.append(index)
        offset += len(word["w"])
    if not selected:
        raise ValueError(t("This selection contains no words."))
    return selected[0], selected[-1] + 1


def _label_for(doc: dict[str, Any], op: dict[str, Any], track: str) -> str:
    if op.get("label"):
        if op["label"] not in doc["speakers"]:
            raise KeyError(t("Unknown speaker: {speaker}", speaker=op["label"]))
        return op["label"]
    name = op["name"].strip()
    for label, entry in doc["speakers"].items():  # typing an existing name means that person
        if entry.get("display", "").casefold() == name.casefold():
            return label
    prefix = NEW_LABEL_PREFIX.get(track, "SALLE")
    number = 1
    while f"{prefix}_{number}" in doc["speakers"]:
        number += 1
    label = f"{prefix}_{number}"
    doc["speakers"][label] = {"name": name, "source": "review"}
    return label


def _assign(doc: dict[str, Any], op: dict[str, Any]) -> None:
    index = _turn_index(doc, op)
    turn = doc["turns"][index]
    label = _label_for(doc, op, turn["track"])
    words = turn["words"]
    first, last = (0, len(words)) if op.get("from") is None else _selected_words(turn, op["from"], op["to"])
    pieces = [
        _from_words(turn, part, piece_label)
        for part, piece_label in ((words[:first], None), (words[first:last], label), (words[last:], None))
        if part
    ]
    doc["turns"][index : index + 1] = pieces
    _join_neighbours(doc["turns"], index, index + len(pieces) - 1)


def _retimed(words: list[dict[str, Any]], tokens: list[str], turn: dict[str, Any]) -> list[dict[str, Any]]:
    """New tokens on the old timeline: unchanged words keep their timing, changed ones share the time they replace."""
    old = [w["w"].strip() for w in words]
    new = [token.strip() for token in tokens]
    result: list[dict[str, Any]] = []

    def human(token: str, start: float, end: float) -> dict[str, Any]:
        return {"w": token, "start": round(start, 3), "end": round(end, 3), "conf": 1.0, "lang": turn.get("lang", "")}

    for kind, a, b, c, d in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if kind == "equal":
            result.extend({**words[a + i], "w": tokens[c + i]} for i in range(d - c))
        elif kind in ("replace", "insert"):
            if kind == "replace":
                begin, end = words[a]["start"], words[b - 1]["end"]
            else:
                begin = end = result[-1]["end"] if result else turn["start"]
            step = (end - begin) / (d - c)
            result.extend(human(tokens[c + i], begin + i * step, begin + (i + 1) * step) for i in range(d - c))
    return result


def _set_text(doc: dict[str, Any], op: dict[str, Any]) -> None:
    index = _turn_index(doc, op)
    turn = doc["turns"][index]
    tokens = [" " + token for token in re.findall(r"\S+", op["text"])]
    if not tokens:
        del doc["turns"][index]
        return
    doc["turns"][index] = _from_words(turn, _retimed(turn["words"], tokens, turn))


def _delete(doc: dict[str, Any], op: dict[str, Any]) -> None:
    del doc["turns"][_turn_index(doc, op)]


OPERATIONS = {"assign": _assign, "set_text": _set_text, "delete": _delete}


def apply(session: Session, op: dict[str, Any]) -> dict[str, Any]:
    """op: {"op": "assign", "turn", "start", "label" | "name", "from"?, "to"?},
    {"op": "set_text", "turn", "start", "text"}, {"op": "delete", "turn", "start"} or {"op": "undo"}."""
    kind = op.get("op")
    if kind == "undo":
        return _undo(session)
    if kind not in OPERATIONS:
        raise ValueError(t("Unknown edit: {op}", op=kind))
    doc = session.load_transcript()
    before = json.loads(json.dumps(doc))
    OPERATIONS[kind](doc, op)
    naming.rebuild_speakers(doc)
    doc["languages"] = sorted({turn["lang"] for turn in doc["turns"] if turn["lang"]})
    snapshot(session, before)
    return {"session": session.id, "outputs": export.save_outputs(session, doc, config.load())}
