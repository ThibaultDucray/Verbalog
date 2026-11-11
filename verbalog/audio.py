"""WAV I/O and energy-based speech detection. Tracks are always 16-bit, mono, 16 kHz."""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

from .i18n import t

SR = 16_000
HEADER_SIZE = 44


def wav_header(num_bytes: int) -> bytes:
    return (
        b"RIFF" + struct.pack("<I", 36 + num_bytes) + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16)
        + b"data" + struct.pack("<I", num_bytes)
    )


def write_wav(path: Path, audio: np.ndarray) -> None:
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    Path(path).write_bytes(wav_header(len(pcm)) + pcm)


def read_wav(path: Path) -> np.ndarray:
    """Read a track, trusting file length over the header so that a file left
    behind by a crash (header not finalized) is still fully readable."""
    with open(path, "rb") as fh:
        head = fh.read(HEADER_SIZE)
        if len(head) < HEADER_SIZE or head[:4] != b"RIFF":
            raise ValueError(t("Invalid WAV file: {path}", path=path))
        channels, rate, bits = struct.unpack("<H I 6x H", head[22:36])
        if (channels, rate, bits) != (1, SR, 16):
            raise ValueError(t("Unexpected format ({channels} channels, {rate} Hz, {bits} bits): {path}", channels=channels, rate=rate, bits=bits, path=path))
        raw = fh.read()
    raw = raw[: len(raw) // 2 * 2]
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def duration(audio: np.ndarray) -> float:
    return len(audio) / SR


def rms_db(audio: np.ndarray) -> float:
    if audio.size == 0:
        return -120.0
    return float(20 * np.log10(np.sqrt(np.mean(np.square(audio))) + 1e-6))


def slice_seconds(audio: np.ndarray, start: float, end: float) -> np.ndarray:
    return audio[max(0, int(start * SR)) : max(0, int(end * SR))]


def _frame_db(audio: np.ndarray, frame: int) -> np.ndarray:
    count = len(audio) // frame
    if count == 0:
        return np.empty(0)
    frames = audio[: count * frame].reshape(count, frame)
    return 20 * np.log10(np.sqrt(np.mean(np.square(frames), axis=1)) + 1e-6)


def energy_vad(
    audio: np.ndarray,
    min_speech: float = 0.25,
    merge_gap: float = 0.5,
    pad: float = 0.2,
    floor_db: float = -50.0,
) -> list[tuple[float, float]]:
    """Speech regions as (start, end) seconds. The threshold adapts to the noise
    floor, so a noisy room is not treated as continuous speech."""
    hop = 0.03
    frame = int(SR * hop)
    db = _frame_db(audio, frame)
    if db.size == 0:
        return []
    audible = db[db > -90]
    noise = np.percentile(audible, 10) if audible.size else -120.0
    threshold = max(noise + 10, floor_db)
    active = db > threshold

    regions: list[list[float]] = []
    start: int | None = None
    for i, on in enumerate(active):
        if on and start is None:
            start = i
        elif not on and start is not None:
            regions.append([start * hop, i * hop])
            start = None
    if start is not None:
        regions.append([start * hop, len(active) * hop])

    merged: list[list[float]] = []
    for region in regions:
        if merged and region[0] - merged[-1][1] <= merge_gap:
            merged[-1][1] = region[1]
        else:
            merged.append(region)

    total = duration(audio)
    return [
        (max(0.0, s - pad), min(total, e + pad))
        for s, e in merged
        if e - s >= min_speech
    ]


def split_long_region(audio: np.ndarray, start: float, end: float, max_len: float = 28.0) -> list[tuple[float, float]]:
    """Cut at the quietest point before max_len so that a chunk never spans
    Whisper's 30 s window (language detection only looks at the first window)."""
    pieces: list[tuple[float, float]] = []
    cursor = start
    while end - cursor > max_len:
        window = slice_seconds(audio, cursor + max_len * 0.6, cursor + max_len)
        db = _frame_db(window, int(SR * 0.05))
        offset = float(np.argmin(db)) * 0.05 if db.size else max_len * 0.4
        cut = cursor + max_len * 0.6 + offset
        pieces.append((cursor, cut))
        cursor = cut
    pieces.append((cursor, end))
    return pieces
