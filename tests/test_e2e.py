# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Real Whisper on real speech (macOS `say` voices). Run with: pytest -m e2e"""

import json
import subprocess
from pathlib import Path

import numpy as np
import pytest

from verbalog import audio as au
from verbalog import config, pipeline
from verbalog.doctor import model_cached
from verbalog.model_types import Diarization, SpeakerTurn
from verbalog.session import Session

pytestmark = pytest.mark.e2e

MODEL = "mlx-community/whisper-large-v3-turbo"
FR = "On a validé l'enveloppe en interne, donc on peut partir sur la phase deux du projet."
EN = "Right, but the rollout timeline depends on the integration with the meter data system."
FR2 = "D'accord, on regarde ça avec l'équipe d'ici jeudi prochain."


def say(tmp: Path, voice: str, text: str) -> np.ndarray:
    aiff, wav = tmp / "s.aiff", tmp / "s.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff), "-ar", "16000", "-ac", "1", str(wav)], check=True)
    return au.read_wav(wav)


def place(length: float, *clips) -> np.ndarray:
    out = np.zeros(int(length * au.SR), np.float32)
    for at, clip in clips:
        out[int(at * au.SR):int(at * au.SR) + len(clip)] += clip
    return out


@pytest.fixture(autouse=True)
def real_models():
    if not model_cached(MODEL):
        pytest.skip("Whisper model not downloaded")


def test_hybrid_real_speech_no_translation_no_duplicate(tmp_path):
    fr = say(tmp_path, "Thomas", FR)
    en = say(tmp_path, "Samantha", EN)
    fr2 = say(tmp_path, "Jacques", FR2)
    end_en = 1 + len(en) / au.SR

    system = place(end_en + 12, (1.0, en))
    # The room mic hears the loudspeaker: delayed, attenuated, with a bit of room reverb and noise.
    delay = int(0.15 * au.SR)
    echo = np.zeros_like(system)
    echo[delay:] += system[:-delay] * 0.35
    echo[delay * 2:] += system[:-delay * 2] * 0.12
    room = place(end_en + 12, (end_en + 1, fr), (end_en + 1 + len(fr) / au.SR + 0.5, fr2))[: len(system)]
    noise = np.random.default_rng(0).standard_normal(len(system)).astype(np.float32) * 0.003
    mic = echo + room + noise

    session = Session.create("Réel", "hybride", remote_count=1, room_count=2, participants=["Marc", "Sophie"])
    au.write_wav(session.mic_path, mic)
    au.write_wav(session.system_path, system)

    fr_at = end_en + 1
    cut = fr_at + len(fr) / au.SR + 0.25

    def diarizer(audio, n=None):
        if n == 1:
            return Diarization([SpeakerTurn(1.0, end_en, "S0")], {})
        return Diarization([SpeakerTurn(fr_at, cut, "A"), SpeakerTurn(cut, len(audio) / au.SR, "B")], {})

    cfg = config.load()
    transcriber = pipeline.default_transcriber(cfg)
    result = pipeline.process(session, diarizer=diarizer, transcriber=transcriber)
    doc = session.load_transcript()
    print(json.dumps([{k: t[k] for k in ("label", "start", "lang", "text")} for t in doc["turns"]], ensure_ascii=False, indent=1))
    print(doc["dedup_removed"])

    all_text = " ".join(t["text"] for t in doc["turns"]).lower()
    assert all_text.count("rollout") == 1, "remote sentence must appear once"
    assert "enveloppe" in all_text and "jeudi" in all_text, "French stays French"
    assert "envelope" not in all_text
    assert {t["lang"] for t in doc["turns"]} == {"fr", "en"}
    labels = {t["label"]: t["lang"] for t in doc["turns"]}
    assert labels["DISTANT_1"] == "en" and labels["SALLE_1"] == "fr"
    assert labels["SALLE_2"] == "fr"
    assert result["status"] == "review"

    final = pipeline.finalize(Session.load(session.id), names={"DISTANT_1": "Marc", "SALLE_1": "Sophie"})
    print(Path(final["outputs"]["md"]).read_text(encoding="utf-8"))
    assert final["coverage"] >= 0.9, final
    assert final["audio_deleted"], final


@pytest.mark.parametrize(
    ("lang", "voice", "text", "words"),
    [
        ("de", "Anna", "Wir haben das Budget intern freigegeben, also können wir mit der zweiten Phase des Projekts beginnen.", ["budget", "phase", "projekts"]),
        ("nl", "Xander", "We hebben het budget intern goedgekeurd, dus we kunnen beginnen aan de tweede fase van het project.", ["budget", "fase", "project"]),
        ("es", "Mónica", "Hemos aprobado el presupuesto internamente, así que podemos empezar la segunda fase del proyecto.", ["presupuesto", "fase", "proyecto"]),
        ("it", "Alice", "Abbiamo approvato il budget internamente, quindi possiamo iniziare la seconda fase del progetto.", ["budget", "fase", "progetto"]),
        ("pt", "Joana", "Aprovámos o orçamento internamente, por isso podemos começar a segunda fase do projeto.", ["orçamento", "fase", "projeto"]),
    ],
)
def test_other_languages_real_speech(tmp_path, lang, voice, text, words):
    from verbalog.transcribe import MlxTranscriber

    clip = say(tmp_path, voice, text)
    audio = place(len(clip) / au.SR + 1.5, (0.5, clip))
    # As ticked for a mixed meeting: the language is detected among three.
    segments = MlxTranscriber(MODEL, languages=["fr", "en", lang]).transcribe_regions(audio, [(0.0, len(audio) / au.SR)])
    heard = " ".join(s.text for s in segments).lower()
    print(lang, heard)
    assert {s.lang for s in segments} == {lang}, heard
    assert all(word in heard for word in words), heard


def test_single_language_meeting_never_turns_french_into_english(tmp_path):
    from verbalog.transcribe import MlxTranscriber

    clip = say(tmp_path, "Thomas", FR)
    audio = place(len(clip) / au.SR + 1.5, (0.5, clip))
    segments = MlxTranscriber(MODEL, languages=["fr"]).transcribe_regions(audio, [(0.0, len(audio) / au.SR)])
    heard = " ".join(s.text for s in segments).lower()
    assert {s.lang for s in segments} == {"fr"} and "enveloppe" in heard, heard
