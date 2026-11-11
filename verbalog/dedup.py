"""Remove from the mic track what the room mic picked up from the loudspeakers.

A mic segment is an echo when it matches the system track at the same moment,
judged on both signal correlation and transcribed text (±1 s).
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass

import numpy as np

from . import audio as au
from .model_types import Segment

WINDOW = 1.0
STRONG_CORRELATION = 0.6
WEAK_CORRELATION = 0.2
TEXT_WITH_WEAK_CORRELATION = 0.6
TEXT_ALONE = 0.85
MIN_WORDS_TEXT_ALONE = 3


@dataclass
class Removed:
    start: float
    end: float
    text: str
    correlation: float
    text_similarity: float


def max_normalized_correlation(needle: np.ndarray, haystack: np.ndarray) -> float:
    """Peak normalized cross-correlation of `needle` at any offset inside `haystack`."""
    if needle.size == 0 or haystack.size < needle.size:
        return 0.0
    needle = needle - needle.mean()
    norm = np.linalg.norm(needle)
    if norm < 1e-6:
        return 0.0
    n = haystack.size + needle.size
    spectrum = np.fft.rfft(haystack, n) * np.conj(np.fft.rfft(needle, n))
    corr = np.fft.irfft(spectrum, n)[: haystack.size - needle.size + 1]
    energy = np.concatenate(([0.0], np.cumsum(np.square(haystack))))
    local = np.sqrt(np.maximum(energy[needle.size :] - energy[: -needle.size], 1e-12))
    # Ignore near-silent stretches of the reference, which would divide by almost nothing.
    valid = local > 1e-3
    if not valid.any():
        return 0.0
    return float(np.max(np.abs(corr[valid]) / (local[valid] * norm)))


def _normalize(text: str) -> str:
    return re.sub(r"[^\w ]", "", text.casefold()).strip()


def text_similarity(mic_text: str, system_text: str) -> float:
    """Share of the mic text found in the system text (which may hold neighbouring segments too)."""
    a, b = _normalize(mic_text), _normalize(system_text)
    if not a or not b:
        return 0.0
    matcher = difflib.SequenceMatcher(None, a, b, autojunk=False)
    matched = sum(block.size for block in matcher.get_matching_blocks())
    return matched / len(a)


def is_echo(correlation: float, similarity: float, word_count: int) -> bool:
    if correlation >= STRONG_CORRELATION:
        return True
    if correlation >= WEAK_CORRELATION and similarity >= TEXT_WITH_WEAK_CORRELATION:
        return True
    return similarity >= TEXT_ALONE and word_count >= MIN_WORDS_TEXT_ALONE


def remove_echoes(
    mic_segments: list[Segment],
    mic_audio: np.ndarray,
    system_segments: list[Segment],
    system_audio: np.ndarray,
) -> tuple[list[Segment], np.ndarray, list[Removed]]:
    """Returns kept segments, the mic audio with echoes silenced (ready for
    diarization, which must only see voices from the room), and what was removed."""
    kept: list[Segment] = []
    removed: list[Removed] = []
    cleaned = mic_audio.copy()
    for seg in mic_segments:
        reference = au.slice_seconds(system_audio, seg.start - WINDOW, seg.end + WINDOW)
        correlation = 0.0
        if au.rms_db(reference) > -60:
            correlation = max_normalized_correlation(au.slice_seconds(mic_audio, seg.start, seg.end), reference)
        nearby = " ".join(
            other.text for other in system_segments
            if other.start <= seg.end + WINDOW and other.end >= seg.start - WINDOW
        )
        similarity = text_similarity(seg.text, nearby)
        if is_echo(correlation, similarity, len(seg.text.split())):
            removed.append(Removed(seg.start, seg.end, seg.text, round(correlation, 3), round(similarity, 3)))
            cleaned[int(seg.start * au.SR) : int(seg.end * au.SR)] = 0.0
        else:
            kept.append(seg)
    return kept, cleaned, removed
