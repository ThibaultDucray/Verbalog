"""pyannote speaker diarization, run from the local cache once the model is downloaded."""

from __future__ import annotations

from typing import Protocol

import numpy as np

from . import audio as au
from .i18n import t
from .model_types import Diarization, SpeakerTurn


class DiarizationUnavailable(RuntimeError):
    """pyannote is missing or its model is not downloaded: the pipeline degrades and says so."""


class Diarizer(Protocol):
    def __call__(self, audio: np.ndarray, num_speakers: int | None = None) -> Diarization: ...


class PyannoteDiarizer:
    def __init__(self, model: str, device: str = "mps", token: str | None = None):
        self.model = model
        self.device = device
        self.token = token
        self._pipeline = None

    def _load(self):
        if self._pipeline is not None:
            return self._pipeline
        try:
            import torch
            from pyannote.audio import Pipeline
        except ImportError as exc:
            raise DiarizationUnavailable(t("pyannote.audio isn't installed")) from exc
        try:
            pipeline = Pipeline.from_pretrained(self.model, token=self.token)
        except Exception as exc:
            raise DiarizationUnavailable(t("model {model} not available locally ({error})", model=self.model, error=exc)) from exc
        if pipeline is None:
            raise DiarizationUnavailable(t("model {model} not available locally", model=self.model))
        if self.device == "mps" and torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
        self._pipeline = pipeline
        return pipeline

    def _run(self, pipeline, audio: np.ndarray, num_speakers: int | None):
        import torch

        # In-memory waveform: skips pyannote's file decoding entirely.
        inputs = {"waveform": torch.from_numpy(audio.copy()).unsqueeze(0), "sample_rate": au.SR}
        kwargs = {"num_speakers": num_speakers} if num_speakers else {}
        return pipeline(inputs, **kwargs)

    def __call__(self, audio, num_speakers=None):
        pipeline = self._load()
        try:
            output = self._run(pipeline, audio, num_speakers)
        except Exception:
            if self.device != "mps":
                raise
            # MPS still lacks a few operators on some torch builds: the fallback is CPU.
            import torch

            pipeline.to(torch.device("cpu"))
            output = self._run(pipeline, audio, num_speakers)
        return _to_diarization(output)


def _to_diarization(output) -> Diarization:
    # pyannote 4 returns a structured output. Prefer its exclusive diarization (one
    # speaker at a time), which is the right one for attributing words.
    annotation = getattr(output, "exclusive_speaker_diarization", None)
    if annotation is None:
        annotation = getattr(output, "speaker_diarization", output)
    labels = list(annotation.labels())
    turns = [
        SpeakerTurn(float(segment.start), float(segment.end), str(label))
        for segment, _, label in annotation.itertracks(yield_label=True)
    ]
    embeddings: dict[str, np.ndarray] = {}
    raw = getattr(output, "speaker_embeddings", None)
    if raw is not None:
        # One row per speaker, ordered as annotation.labels().
        for index, label in enumerate(labels):
            if index < len(raw) and not np.isnan(raw[index]).any():
                embeddings[str(label)] = np.asarray(raw[index], dtype=np.float32)
    return Diarization(sorted(turns, key=lambda t: t.start), embeddings)


def relabel(diarization: Diarization, prefix: str) -> Diarization:
    """SPEAKER_00 -> SALLE_1 / DISTANT_1, numbered by first appearance."""
    mapping: dict[str, str] = {}
    turns = []
    for turn in diarization.turns:
        if turn.label not in mapping:
            mapping[turn.label] = f"{prefix}_{len(mapping) + 1}"
        turns.append(SpeakerTurn(turn.start, turn.end, mapping[turn.label]))
    embeddings = {mapping[k]: v for k, v in diarization.embeddings.items() if k in mapping}
    return Diarization(turns, embeddings)
