"""mlx-whisper transcription of speech regions, each detected in its own language."""

from __future__ import annotations

import re
import unicodedata
from typing import Callable, Protocol, Sequence

import numpy as np

from . import audio as au
from .model_types import Segment, SpeakerTurn, Word

Progress = Callable[[float], None]

# Stock phrases Whisper invents on silence or music: they come from its subtitle training data.
HALLUCINATIONS = (
    "sous-titres realises par",
    "sous-titrage",
    "amara.org",
    "merci d'avoir regarde",
    "thanks for watching",
    "thank you for watching",
    "subtitles by",
    "untertitel im auftrag",
    "untertitelung",
    "vielen dank furs zuschauen",
    "ondertiteld door",
    "ondertiteling",
    "bedankt voor het kijken",
    "subtitulos realizados por",
    "subtitulado por",
    "gracias por ver el video",
    "sottotitoli creati dalla comunita",
    "sottotitoli a cura di",
    "grazie per la visione",
    "legendas pela comunidade",
    "legendas por",
    "obrigado por assistir",
)
MIN_AVG_LOGPROB = -1.0  # below this, a segment is noise rather than speech
SUPPORTED_LANGUAGES = ("fr", "en", "de", "nl", "es", "it", "pt")
DEFAULT_LANGUAGES = ("fr", "en")
MAX_PROMPT_TOKENS = 223  # Whisper keeps only the last ones, so an overlong prompt loses its start


class Transcriber(Protocol):
    def transcribe_regions(
        self, audio: np.ndarray, regions: Sequence[tuple[float, float]], progress: Progress | None = None
    ) -> list[Segment]: ...


def build_prompt(glossary: Sequence[str]) -> str:
    prompt = "Réunion en français et en anglais. Meeting in French and English."
    if glossary:
        prompt += " Glossaire / glossary : " + ", ".join(glossary) + "."
    return prompt


def fit_glossary(glossary: Sequence[str]) -> tuple[list[str], list[str]]:
    """Split terms into those that fit in the prompt and those that don't, keeping order."""
    from mlx_whisper.tokenizer import get_tokenizer

    tokenizer = get_tokenizer(multilingual=True, num_languages=100, task="transcribe")
    for count in range(len(glossary), 0, -1):
        if len(tokenizer.encode(" " + build_prompt(glossary[:count]))) <= MAX_PROMPT_TOKENS:
            return list(glossary[:count]), list(glossary[count:])
    return [], list(glossary)


def regions_from_turns(audio: np.ndarray, turns: Sequence[SpeakerTurn]) -> list[tuple[float, float]]:
    """Speaker turns to transcription chunks: join same-speaker neighbours, absorb
    fragments too short for language detection, split anything over Whisper's window."""
    joined: list[list] = []
    for turn in sorted(turns, key=lambda t: t.start):
        if joined and (
            (turn.label == joined[-1][2] and turn.start - joined[-1][1] < 0.5)
            or (turn.end - turn.start < 0.6 and turn.start - joined[-1][1] < 0.5)
        ):
            joined[-1][1] = max(joined[-1][1], turn.end)
        else:
            joined.append([turn.start, turn.end, turn.label])
    regions = [(s, e) for s, e, _ in joined]
    # Diarization can mark clear speech as silence: energy VAD recovers what it missed.
    return regions_from_vad(audio, sorted(regions + _uncovered(au.energy_vad(audio), regions)))


def _uncovered(
    candidates: Sequence[tuple[float, float]], covered: Sequence[tuple[float, float]], min_len: float = 1.0
) -> list[tuple[float, float]]:
    """Parts of `candidates` outside `covered`, ignoring remainders too short to transcribe."""
    out: list[tuple[float, float]] = []
    for start, end in candidates:
        cursor = start
        for cover_start, cover_end in sorted(covered):
            if cover_end <= cursor or cover_start >= end:
                continue
            if cover_start - cursor >= min_len:
                out.append((cursor, cover_start))
            cursor = max(cursor, cover_end)
        if end - cursor >= min_len:
            out.append((cursor, end))
    return out


def regions_from_vad(audio: np.ndarray, regions: Sequence[tuple[float, float]], pad: float = 0.1) -> list[tuple[float, float]]:
    total = au.duration(audio)
    out: list[tuple[float, float]] = []
    for start, end in regions:
        out.extend(au.split_long_region(audio, max(0.0, start - pad), min(total, end + pad)))
    return out


def _normalize(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text)
    plain = "".join(c for c in decomposed if not unicodedata.combining(c)).casefold().replace("’", "'")
    return re.sub(r"\s+", " ", plain).strip()


def _recites(text: str, prompt: str, terms: Sequence[str]) -> bool:
    """Whisper sometimes recites its own initial prompt on near-silence."""
    normalized = _normalize(text)
    if normalized.rstrip(" .,;:!?") in {_normalize(term) for term in terms}:
        return False  # one term alone is someone really saying that name
    return len(normalized) > 8 and normalized in _normalize(prompt)


def is_hallucination(text: str, seg: dict, prompt: str = "", terms: Sequence[str] = ()) -> bool:
    normalized = _normalize(text)
    if not normalized:
        return True
    if any(marker in normalized for marker in HALLUCINATIONS):
        return True
    if _recites(text, prompt, terms):
        return True
    if not any(c.isalnum() for c in normalized):  # "...": nothing was understood
        return True
    if seg.get("avg_logprob", 0) < MIN_AVG_LOGPROB:
        return True
    return seg.get("compression_ratio", 0) > 2.6  # repetition loop


def _needs_retry(result: dict, prompt: str = "", terms: Sequence[str] = ()) -> bool:
    segments = result.get("segments", [])
    return not segments or any(
        seg.get("avg_logprob", 0) < MIN_AVG_LOGPROB
        or seg.get("compression_ratio", 0) > 2.4
        or not any(c.isalnum() for c in seg.get("text", ""))
        or _recites(seg.get("text", ""), prompt, terms)
        for seg in segments
    )


def _mean_logprob(result: dict) -> float:
    scores = [seg.get("avg_logprob", 0) for seg in result.get("segments", [])]
    return sum(scores) / len(scores) if scores else float("-inf")


def meeting_languages(chosen: Sequence[str] | None) -> tuple[str, ...]:
    """The languages ticked for a meeting, among the supported ones; French and English if none."""
    return tuple(code for code in SUPPORTED_LANGUAGES if code in (chosen or ())) or DEFAULT_LANGUAGES


class MlxTranscriber:
    def __init__(self, model: str, glossary: Sequence[str] = (), languages: Sequence[str] = DEFAULT_LANGUAGES):
        self.model = model
        self.languages = meeting_languages(languages)
        self.terms, self.dropped_terms = fit_glossary(list(glossary))
        self.prompt = build_prompt(self.terms)

    def _decode(self, chunk: np.ndarray, prompt: str | None, language: str | None = None) -> dict:
        import mlx_whisper

        return mlx_whisper.transcribe(
            chunk,
            path_or_hf_repo=self.model,
            language=language,  # None by default: forcing it would translate instead of transcribe
            task="transcribe",
            temperature=0.0,  # its default fallback up to 1.0 samples random multilingual tokens
            word_timestamps=True,
            initial_prompt=prompt,
            condition_on_previous_text=False,
            verbose=None,
        )

    def _transcribe(self, chunk: np.ndarray) -> dict:
        # A meeting in one language is decoded in it: a French voice never comes out as
        # invented English. Anyone speaking another language gets translated, which is the
        # trade-off the person makes by ticking a single language.
        only = self.languages[0] if len(self.languages) == 1 else None
        # On hard chunks the prompt can yield "..." or be recited back, losing real speech.
        result = self._decode(chunk, self.prompt, only)
        if result.get("language") not in self.languages:
            # Detected outside the meeting's languages: near-silence ("ありがとうございました"), or a
            # voice mistaken for a close language. Decoding in each of the meeting's languages and
            # keeping the likelier one can't translate real speech: its own language wins.
            return max((self._retry(chunk, lang) for lang in self.languages), key=_mean_logprob)
        return self._retry(chunk, only) if _needs_retry(result, self.prompt, self.terms) else result

    def _retry(self, chunk: np.ndarray, language: str | None = None) -> dict:
        # Hard chunks are where names go wrong, so try the bare terms before giving up the hint.
        if self.terms:
            terms_prompt = ", ".join(self.terms) + "."
            result = self._decode(chunk, terms_prompt, language)
            if not _needs_retry(result, terms_prompt, self.terms):
                return result
        return self._decode(chunk, None, language)

    def transcribe_regions(self, audio, regions, progress=None):
        segments: list[Segment] = []
        for index, (start, end) in enumerate(regions):
            chunk = au.slice_seconds(audio, start, end)
            if chunk.size < au.SR // 10:
                continue
            result = self._transcribe(chunk.astype(np.float32))
            lang = result.get("language") or ""
            for seg in result.get("segments", []):
                text = seg.get("text", "").strip()
                if is_hallucination(text, seg, self.prompt, self.terms):
                    continue
                words = [
                    Word(w["word"], start + float(w["start"]), start + float(w["end"]), float(w.get("probability", 1.0)), lang)
                    for w in seg.get("words", [])
                ]
                segments.append(Segment(start + float(seg["start"]), start + float(seg["end"]), text, lang, words))
            if progress:
                progress((index + 1) / max(1, len(regions)))
        return segments
