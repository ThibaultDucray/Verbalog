import numpy as np
import pytest

from verbalog import config


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("VERBALOG_HOME", str(home))
    monkeypatch.setenv("VERBALOG_VOICEPRINT_KEY", "gtIdkRBWk5zyCmIL3W9OLsvx8CYqrM54FAN2N_E0sEs=")
    config.update({
        "general": {"output_dir": str(tmp_path / "out"), "user_name": "Camille", "language": "fr"},
        "speakers": {"voiceprints_dir": str(home / "voiceprints")},
        "privacy": {"sensitive_file": str(home / "sensitive.txt")},
        "transcription": {"glossary_file": str(home / "glossary.txt")},
    })
    return home


def speech(seconds: float, freq: float = 180.0, seed: int = 0, level: float = 0.3) -> np.ndarray:
    """Noise modulated like syllables: looks like speech to energy VAD, and uncorrelated between seeds."""
    rng = np.random.default_rng(seed)
    n = int(seconds * 16000)
    t = np.arange(n) / 16000
    envelope = 0.6 + 0.4 * np.sin(2 * np.pi * 4 * t)
    return (rng.standard_normal(n) * 0.3 + np.sin(2 * np.pi * freq * t)).astype(np.float32) * envelope.astype(np.float32) * level
