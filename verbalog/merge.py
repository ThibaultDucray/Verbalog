"""Words + speaker turns -> chronological speaking turns."""

from __future__ import annotations

from collections import Counter
from typing import Any, Sequence

from .model_types import Segment, SpeakerTurn, Word

NEW_TURN_PAUSE = 2.0
NEAREST_TURN_TOLERANCE = 1.0


def speaker_for_word(word: Word, turns: Sequence[SpeakerTurn], fallback: str) -> str:
    """Speaker whose turn overlaps the word most; else the nearest turn close by; else the previous word's speaker."""
    best, best_overlap = None, 0.0
    nearest, nearest_gap = None, NEAREST_TURN_TOLERANCE
    for turn in turns:
        overlap = min(word.end, turn.end) - max(word.start, turn.start)
        if overlap > best_overlap:
            best, best_overlap = turn.label, overlap
        gap = max(turn.start - word.end, word.start - turn.end, 0.0)
        if gap < nearest_gap:
            nearest, nearest_gap = turn.label, gap
    return best or nearest or fallback


def build_turns(
    segments: Sequence[Segment],
    track: str,
    speaker_turns: Sequence[SpeakerTurn] | None = None,
    label: str | None = None,
) -> list[dict[str, Any]]:
    """Group a track's words. Pass `label` for a track with one known speaker, or
    `speaker_turns` to attribute each word from diarization."""
    turns: list[dict[str, Any]] = []
    current_label = label or (speaker_turns[0].label if speaker_turns else "INCONNU")
    current: dict[str, Any] | None = None

    for segment in sorted(segments, key=lambda s: s.start):
        words = segment.words or [Word(segment.text, segment.start, segment.end, 1.0, segment.lang)]
        for word in words:
            if not label and speaker_turns:
                current_label = speaker_for_word(word, speaker_turns, current_label)
            if (
                current is None
                or current["label"] != current_label
                or word.start - current["end"] > NEW_TURN_PAUSE
            ):
                current = {"start": word.start, "end": word.end, "label": current_label, "track": track, "words": []}
                turns.append(current)
            current["end"] = max(current["end"], word.end)
            current["words"].append(
                {"w": word.text, "start": round(word.start, 3), "end": round(word.end, 3),
                 "conf": round(word.confidence, 3), "lang": word.lang}
            )

    for turn in turns:
        finish_turn(turn)
    return [turn for turn in turns if turn["text"]]


def finish_turn(turn: dict[str, Any]) -> None:
    """Derive a turn's text and statistics from its words."""
    turn["text"] = "".join(w["w"] for w in turn["words"]).strip()
    turn["start"], turn["end"] = round(turn["start"], 3), round(turn["end"], 3)
    langs = Counter(w["lang"] for w in turn["words"] if w["lang"])
    turn["lang"] = langs.most_common(1)[0][0] if langs else ""
    confs = [w["conf"] for w in turn["words"]]
    turn["confidence"] = round(sum(confs) / len(confs), 3) if confs else 0.0


def merge_tracks(*tracks: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Overlapping speech from different tracks stays, ordered by start of speech."""
    merged = [turn for track in tracks for turn in track]
    return sorted(merged, key=lambda t: (t["start"], t["end"]))


def note_positions(turns: Sequence[dict[str, Any]], note_times: Sequence[float]) -> list[int]:
    """Index of the turn each note follows (-1 = before the first). A note goes at
    the end of the turn in progress at its timestamp, never mid-sentence."""
    positions = []
    for t in note_times:
        index = -1
        for i, turn in enumerate(turns):
            if turn["start"] <= t:
                index = i
            else:
                break
        positions.append(index)
    return positions
