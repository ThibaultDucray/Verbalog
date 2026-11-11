"""Validate the transcript, then delete the audio."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from . import audio as au
from .i18n import t
from .session import Session

MIN_COVERAGE = 0.90
PADDING = 1.0


@dataclass
class Validation:
    ok: bool
    coverage: float
    reason: str = ""


def _covered_seconds(regions, intervals) -> tuple[float, float]:
    voiced = covered = 0.0
    for start, end in regions:
        voiced += end - start
        for other_start, other_end in intervals:
            covered += max(0.0, min(end, other_end) - max(start, other_start))
    return voiced, covered


def _merge(intervals: list[tuple[float, float]]) -> list[tuple[float, float]]:
    merged: list[list[float]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(a, b) for a, b in merged]


def coverage(session: Session, doc: dict[str, Any]) -> float:
    """Share of audible audio accounted for by the transcript. The spec's "duration
    covered" can't be literal: meetings contain silences, and a long one must not
    block deletion. Echoes removed on purpose count as accounted for."""
    voiced = covered = 0.0
    tracks = [("mic", session.mic_path), ("system", session.system_path)]
    removed = [(r["start"], r["end"]) for r in doc.get("dedup_removed", [])]
    for track, path in tracks:
        if not path.exists():
            continue
        audio = au.read_wav(path)
        intervals = [(turn["start"] - PADDING, turn["end"] + PADDING) for turn in doc["turns"] if turn["track"] == track]
        if track == "mic":
            intervals += removed
        v, c = _covered_seconds(au.energy_vad(audio), _merge(intervals))
        voiced += v
        covered += c
    return covered / voiced if voiced else 1.0


def validate(session: Session, doc: dict[str, Any], md_path: Path) -> Validation:
    if not md_path.exists() or not md_path.read_text(encoding="utf-8").strip():
        return Validation(False, 0.0, t("the transcript file is missing or empty"))
    value = coverage(session, doc)
    if not doc["turns"]:
        if value >= 1.0:  # nothing audible was recorded: nothing was lost either
            return Validation(True, value)
        return Validation(False, 0.0, t("no speech transcribed although the audio isn't silent"))
    if value < MIN_COVERAGE:
        return Validation(False, value, t("the transcript only covers {value:.0%} of the audible audio (minimum {minimum:.0%})", value=value, minimum=MIN_COVERAGE))
    return Validation(True, value)


def delete_audio(session: Session) -> list[str]:
    deleted = []
    for path in (session.mic_path, session.system_path):
        if path.exists():
            path.unlink()
            deleted.append(path.name)
    return deleted


def filevault_enabled() -> bool | None:
    try:
        out = subprocess.run(["fdesetup", "status"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    if "On" in out:
        return True
    return False if "Off" in out else None
