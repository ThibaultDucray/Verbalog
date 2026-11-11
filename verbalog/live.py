"""Rolling transcript of the recording in progress, for display only.

It tails the growing WAVs and sends each utterance through a small Whisper model.
The real transcript comes from the post-meeting pipeline, which replaces this one.
"""

from __future__ import annotations

import json
import signal
import time
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from . import audio as au
from .events import Emit
from .i18n import t
from .session import Session
from .transcribe import is_hallucination, meeting_languages

POLL_SECONDS = 1.0
MIN_UTTERANCE = 0.8
TRAILING_SILENCE = 0.6
MAX_UTTERANCE = 15.0
MAX_BACKLOG = 45.0
SILENCE_DB = -48.0


@dataclass
class TrackTail:
    name: str
    path: Any
    offset: int = au.HEADER_SIZE
    buffer: np.ndarray = field(default_factory=lambda: np.empty(0, dtype=np.float32))
    buffer_start: float = 0.0

    def read_new(self) -> None:
        if not self.path.exists():
            return
        with open(self.path, "rb") as fh:
            fh.seek(self.offset)
            raw = fh.read()
        raw = raw[: len(raw) // 2 * 2]
        self.offset += len(raw)
        if raw:
            chunk = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            self.buffer = np.concatenate((self.buffer, chunk))

    def advance(self, samples: int) -> None:
        self.buffer = self.buffer[samples:]
        self.buffer_start += samples / au.SR


def next_utterance(tail: TrackTail) -> tuple[float, np.ndarray] | None:
    """Pop the next utterance, once it's finished (followed by silence) or too long to wait for."""
    frame = int(0.03 * au.SR)
    count = len(tail.buffer) // frame
    if count == 0:
        return None
    frames = tail.buffer[: count * frame].reshape(count, frame)
    db = 20 * np.log10(np.sqrt(np.mean(np.square(frames), axis=1)) + 1e-6)
    voiced = np.nonzero(db > SILENCE_DB)[0]
    if voiced.size == 0:
        tail.advance(max(0, count - 1) * frame)  # all silence: drop it
        return None

    first = max(0, int(voiced[0]) - 5)
    if first:
        tail.advance(first * frame)
        return next_utterance(tail)

    silence_frames = int(TRAILING_SILENCE / 0.03)
    end = None
    run = 0
    for index in range(int(voiced[0]), count):
        run = run + 1 if db[index] <= SILENCE_DB else 0
        if run >= silence_frames:
            end = index - run + 1
            break
    max_frames = int(MAX_UTTERANCE / 0.03)
    if end is None and count >= max_frames:
        end = max_frames
    if end is None:
        return None
    samples = (end + 3) * frame
    utterance = tail.buffer[:samples].copy()
    start = tail.buffer_start
    tail.advance(samples)
    if len(utterance) < MIN_UTTERANCE * au.SR:
        return None
    return start, utterance


def run(session: Session, cfg: dict[str, Any], emit: Emit) -> None:
    import mlx_whisper

    stop = {"flag": False}

    def request_stop(*_: Any) -> None:
        stop["flag"] = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    tails = [TrackTail("mic", session.mic_path)]
    if session.mode != "presentiel":
        tails.append(TrackTail("system", session.system_path))
    live_file = session.path / "live.jsonl"
    model = cfg["transcription"]["live_model"]
    # Read once: languages changed during the meeting apply to the final transcript.
    languages = meeting_languages(session.data.get("languages") or cfg["transcription"]["languages"])
    only = languages[0] if len(languages) == 1 else None
    emit("ready", model=model)

    with live_file.open("a", encoding="utf-8") as out:
        while not stop["flag"]:
            worked = False
            for tail in tails:
                tail.read_new()
                backlog = len(tail.buffer) / au.SR
                if backlog > MAX_BACKLOG:
                    # Falling behind real time: a current view beats a complete one here.
                    tail.advance(int((backlog - MAX_UTTERANCE) * au.SR))
                    emit("warning", message=t("Live transcript falling behind: a passage was skipped."))
                popped = next_utterance(tail)
                if popped is None:
                    continue
                worked = True
                start, utterance = popped
                result = mlx_whisper.transcribe(
                    utterance, path_or_hf_repo=model, language=only, task="transcribe", temperature=0.0,
                    condition_on_previous_text=False, verbose=None,
                )
                if result.get("language") not in languages:
                    continue  # a preview can skip what the final transcript will decode properly
                for seg in result.get("segments", []):
                    text = seg.get("text", "").strip()
                    if is_hallucination(text, seg):
                        continue
                    row = {
                        "track": tail.name,
                        "start": round(start + float(seg["start"]), 2),
                        "end": round(start + float(seg["end"]), 2),
                        "text": text,
                        "lang": result.get("language") or "",
                    }
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    emit("live", **row)
            if not worked:
                time.sleep(POLL_SECONDS)
