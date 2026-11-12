# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""The adapter against pyannote's real data types. The gated model itself needs a Hugging Face token."""

from types import SimpleNamespace

import numpy as np
import pytest

from verbalog.diarize import _to_diarization, relabel
from verbalog.model_types import Diarization, SpeakerTurn

core = pytest.importorskip("pyannote.core")


def annotation(*rows):
    result = core.Annotation()
    for start, end, label in rows:
        result[core.Segment(start, end)] = label
    return result


def test_structured_output_prefers_exclusive_diarization_and_maps_embeddings():
    output = SimpleNamespace(
        speaker_diarization=annotation((0, 5, "SPEAKER_00"), (4, 8, "SPEAKER_01")),
        exclusive_speaker_diarization=annotation((0, 4, "SPEAKER_00"), (4, 8, "SPEAKER_01")),
        speaker_embeddings=np.array([[1.0, 0.0], [0.0, 1.0]]),
    )
    result = _to_diarization(output)
    assert [(t.start, t.end, t.label) for t in result.turns] == [(0, 4, "SPEAKER_00"), (4, 8, "SPEAKER_01")]
    assert list(result.embeddings["SPEAKER_01"]) == [0.0, 1.0]


def test_plain_annotation_from_older_pipelines():
    result = _to_diarization(annotation((1, 2, "A")))
    assert [t.label for t in result.turns] == ["A"]
    assert result.embeddings == {}


def test_speaker_without_usable_embedding_is_skipped():
    output = SimpleNamespace(
        exclusive_speaker_diarization=annotation((0, 1, "A"), (1, 2, "B")),
        speaker_embeddings=np.array([[np.nan, np.nan], [0.0, 1.0]]),
    )
    assert set(_to_diarization(output).embeddings) == {"B"}


def test_relabel_numbers_by_first_appearance():
    result = relabel(Diarization([SpeakerTurn(0, 1, "Z"), SpeakerTurn(1, 2, "A"), SpeakerTurn(2, 3, "Z")], {"A": np.ones(2)}), "SALLE")
    assert [t.label for t in result.turns] == ["SALLE_1", "SALLE_2", "SALLE_1"]
    assert list(result.embeddings) == ["SALLE_2"]
