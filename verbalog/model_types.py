# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Plain data passed between pipeline stages."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Word:
    text: str
    start: float
    end: float
    confidence: float = 1.0
    lang: str = ""


@dataclass
class Segment:
    start: float
    end: float
    text: str
    lang: str
    words: list[Word] = field(default_factory=list)


@dataclass
class SpeakerTurn:
    start: float
    end: float
    label: str


@dataclass
class Diarization:
    turns: list[SpeakerTurn]
    embeddings: dict[str, np.ndarray] = field(default_factory=dict)
