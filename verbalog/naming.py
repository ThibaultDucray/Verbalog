"""Attach names to speaker labels.

Priority: live hints, then voiceprints, then the review screen. Unnamed speakers get a numbered placeholder.
"""

from __future__ import annotations

from typing import Any, Callable, Sequence

from .notes import Note
from .i18n import t

AMBIGUOUS_DB = 3.0
ORIGINS = {"SALLE": "salle", "DISTANT": "distant", "MOI": "moi"}


def origin_of(label: str) -> str:
    return ORIGINS.get(label.split("_")[0], "")


def _active_at(turns: Sequence[dict[str, Any]], t: float, lookback: float) -> list[dict[str, Any]]:
    """Latest speaker at t on each track; if nobody speaks, whoever spoke in the last `lookback` seconds."""
    active: dict[str, dict[str, Any]] = {}
    for turn in turns:
        if turn["start"] <= t <= turn["end"]:
            active[turn["track"]] = turn
    if active:
        return list(active.values())
    recent = [turn for turn in turns if t - lookback <= turn["end"] < t]
    return [max(recent, key=lambda turn: turn["end"])] if recent else []


def resolve_hints(
    notes: Sequence[Note],
    turns: Sequence[dict[str, Any]],
    lookback: float,
    fixed_labels: set[str],
    track_energy: Callable[[str, float], float] | None = None,
) -> tuple[dict[str, str], list[dict[str, Any]]]:
    """Returns (label -> name, conflicts). `fixed_labels` are speakers whose identity
    is already certain, such as the user's own track in a video call."""
    assigned: dict[str, str] = {}
    conflicts: list[dict[str, Any]] = []
    candidates = [turn for turn in turns if turn["label"] not in fixed_labels]

    for note in notes:
        if note.type != "speaker" or not note.speaker:
            continue
        if note.announce:
            upcoming = [turn for turn in candidates if turn["start"] > note.t]
            chosen = min(upcoming, key=lambda turn: turn["start"]) if upcoming else None
        else:
            active = _active_at(candidates, note.t, lookback)
            chosen = active[0] if active else None
            if len(active) > 1 and track_energy:
                # Voices on both tracks: the louder one wins, unless too close to call.
                ranked = sorted(active, key=lambda turn: track_energy(turn["track"], note.t), reverse=True)
                chosen = ranked[0]
                gap = track_energy(ranked[0]["track"], note.t) - track_energy(ranked[1]["track"], note.t)
                if gap < AMBIGUOUS_DB:
                    conflicts.append({
                        "kind": "ambiguous", "t": note.t, "name": note.speaker,
                        "labels": [turn["label"] for turn in ranked],
                    })
                    continue

        if chosen is None:
            conflicts.append({"kind": "no_speaker", "t": note.t, "name": note.speaker, "labels": []})
            continue

        label = chosen["label"]
        previous = assigned.get(label)
        if previous and previous != note.speaker:
            conflicts.append({"kind": "contradiction", "t": note.t, "name": note.speaker, "labels": [label], "previous": previous})
        else:
            assigned[label] = note.speaker
    return assigned, conflicts


def summarize_speakers(turns: Sequence[dict[str, Any]], names: dict[str, tuple[str, str]], mode: str) -> dict[str, dict[str, Any]]:
    """Build the speakers table. `names`: label -> (name, source)."""
    speakers: dict[str, dict[str, Any]] = {}
    for turn in turns:
        entry = speakers.setdefault(turn["label"], {
            "track": turn["track"], "origin": origin_of(turn["label"]), "talk_seconds": 0.0, "_turns": [],
        })
        entry["talk_seconds"] += turn["end"] - turn["start"]
        entry["_turns"].append(turn)

    counters: dict[str, int] = {}
    for label, entry in speakers.items():
        name, source = names.get(label, (None, None))
        entry["name"], entry["source"] = name, source
        if not name:
            origin = entry["origin"] if mode == "hybride" else ""
            counters[origin] = counters.get(origin, 0) + 1
            placeholder = {"salle": "Room speaker {n}", "distant": "Remote speaker {n}"}.get(origin, "Speaker {n}")
            entry["display"] = t(placeholder, n=counters[origin])
        else:
            entry["display"] = name
        longest = sorted(entry.pop("_turns"), key=lambda turn: len(turn["text"]), reverse=True)[:3]
        entry["samples"] = [
            {"t": turn["start"], "end": turn["end"], "track": turn["track"], "text": turn["text"][:200]}
            for turn in sorted(longest, key=lambda turn: turn["start"])
        ]
        entry["talk_seconds"] = round(entry["talk_seconds"], 1)
    return speakers


def rebuild_speakers(doc: dict[str, Any]) -> None:
    """Recompute the speakers table from the turns, keeping the names already given."""
    names = {
        label: (entry["name"], entry.get("source") or "review")
        for label, entry in doc["speakers"].items() if entry.get("name")
    }
    doc["speakers"] = summarize_speakers(doc["turns"], names, doc["context"])
    doc["needs_review"] = False
