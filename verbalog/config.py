"""~/.verbalog/config.toml, merged over defaults."""

from __future__ import annotations

import copy
import fcntl
import os
import tomllib
from pathlib import Path
from typing import Any

import tomli_w

DEFAULTS: dict[str, Any] = {
    "general": {
        # Not ~/Documents: "Desktop & Documents" sync would upload every transcript to iCloud.
        "output_dir": "~/Verbalog",
        "user_name": "",
        "keep_audio": False,
        "language": "en",  # interface, messages and exports: "en" | "fr"
    },
    "session": {"default_mode": "visio", "remember_last": True},
    "speakers": {
        "naming_patterns": [
            "ici c'est {nom}",
            "c'est {nom} qui parle",
            "{nom} parle",
            "this is {nom}",
            "{nom} speaking",
        ],
        "lookback_seconds": 5,
        "voiceprints_dir": "~/.verbalog/voiceprints",
        "voiceprint_threshold": 0.75,
    },
    "capture": {"mic_device": "default", "system_source": "all"},
    "transcription": {
        "model": "mlx-community/whisper-large-v3-turbo",
        "live_enabled": True,
        "live_model": "mlx-community/whisper-small-mlx",
        "glossary_file": "~/.verbalog/glossary.txt",
    },
    "diarization": {"model": "pyannote/speaker-diarization-community-1", "device": "mps"},
    "notes": {"anchor": "first_keystroke"},
    "privacy": {
        "pseudonymize": True,
        "sensitive_file": "~/.verbalog/sensitive.txt",
        "preview_before_send": True,
    },
    "claude": {"mode": "manual", "model": "claude-opus-5-5", "output_language": "fr"},
}


def home() -> Path:
    return Path(os.environ.get("VERBALOG_HOME", "~/.verbalog")).expanduser()


def config_path() -> Path:
    return home() / "config.toml"


def expand(path: str) -> Path:
    # Default paths live under the home, wherever VERBALOG_HOME puts it.
    if path == "~/.verbalog" or path.startswith("~/.verbalog/"):
        return home() / path.removeprefix("~/.verbalog").lstrip("/")
    return Path(path).expanduser()


def deep_merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load() -> dict[str, Any]:
    path = config_path()
    if not path.exists():
        return copy.deepcopy(DEFAULTS)
    with path.open("rb") as fh:
        return deep_merge(DEFAULTS, tomllib.load(fh))


def update(changes: dict[str, Any]) -> dict[str, Any]:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # Each save is its own process. The lock spans read to replace, or one save erases another.
    with path.with_suffix(".lock").open("wb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        merged = deep_merge(load(), changes)
        tmp = path.with_suffix(".tmp")
        with tmp.open("wb") as fh:
            tomli_w.dump(merged, fh)
        tmp.replace(path)
    return merged


def read_glossary(cfg: dict[str, Any]) -> list[str]:
    path = expand(cfg["transcription"]["glossary_file"])
    if not path.exists():
        return []
    terms: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            terms.extend(t.strip() for t in line.split(",") if t.strip())
    return terms
