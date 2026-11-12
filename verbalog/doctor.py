# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Readiness report for the app's setup screen, and model downloads."""

from __future__ import annotations

import importlib.util
import os
import subprocess
from pathlib import Path
from typing import Any

from . import cleanup, config
from .events import Emit
from .i18n import t
from .keychain import get_secret


def _hub_dir() -> Path:
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"]).expanduser()
    return Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser() / "hub"


def model_cached(repo: str) -> bool:
    if Path(repo).expanduser().is_dir():
        return True
    snapshots = _hub_dir() / f"models--{repo.replace('/', '--')}" / "snapshots"
    return snapshots.is_dir() and any(any(s.iterdir()) for s in snapshots.iterdir())


def _installed(module: str) -> bool:
    return importlib.util.find_spec(module) is not None


def _spacy_models() -> bool:
    from .pseudonymize import SPACY_MODELS

    return all(_installed(model) for model in SPACY_MODELS.values())


def _is_cloud_synced(path: Path) -> bool:
    resolved = path.expanduser().resolve()
    home = Path.home()
    cloud_roots = [home / "Library/Mobile Documents", home / "Library/CloudStorage", home / "Dropbox"]
    if any(resolved.is_relative_to(root) for root in cloud_roots):
        return True
    # "Desktop & Documents" sync leaves ~/Documents in place but gives it the iCloud file provider's attribute.
    documents = home / "Documents"
    if resolved.is_relative_to(documents):
        try:
            attributes = subprocess.run(["xattr", str(documents)], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return False
        return "com.apple.icloud.desktop" in attributes or "com.apple.file-provider-domain-id" in attributes
    return False


def report() -> dict[str, Any]:
    cfg = config.load()
    whisper, live, diarization = cfg["transcription"]["model"], cfg["transcription"]["live_model"], cfg["diarization"]["model"]
    output_dir = config.expand(cfg["general"]["output_dir"])
    return {
        "mlx_whisper": _installed("mlx_whisper"),
        "whisper_model": whisper,
        "whisper_cached": model_cached(whisper),
        "live_model": live,
        "live_cached": model_cached(live),
        "pyannote": _installed("pyannote.audio"),
        "diarization_model": diarization,
        "diarization_cached": model_cached(diarization),
        "hf_token": bool(get_secret("hf-token")),
        "ner": _installed("spacy") and _spacy_models(),
        "filevault": cleanup.filevault_enabled(),
        "output_dir": str(output_dir),
        "output_dir_cloud_synced": _is_cloud_synced(output_dir),
        "user_name_set": bool(cfg["general"]["user_name"]),
    }


def download_models(emit: Emit) -> dict[str, Any]:
    """The only step that talks to Hugging Face. Everything else runs with HF_HUB_OFFLINE=1."""
    from huggingface_hub import snapshot_download

    cfg = config.load()
    failures: dict[str, str] = {}
    whisper_models = list(dict.fromkeys([cfg["transcription"]["model"], cfg["transcription"]["live_model"]]))
    steps = len(whisper_models) + 1
    for index, repo in enumerate(whisper_models):
        emit("progress", stage="download", label=t("Downloading {repo}", repo=repo), fraction=index / steps)
        try:
            snapshot_download(repo)
        except Exception as exc:
            failures[repo] = str(exc)

    repo = cfg["diarization"]["model"]
    emit("progress", stage="download", label=t("Downloading {repo}", repo=repo), fraction=(steps - 1) / steps)
    token = get_secret("hf-token")
    if not _installed("pyannote.audio"):
        failures[repo] = t("pyannote.audio isn't installed")
    elif not token:
        failures[repo] = t("Hugging Face token missing")
    else:
        try:
            from pyannote.audio import Pipeline

            # Also fetches the sub-models that the pipeline's config points at.
            if Pipeline.from_pretrained(repo, token=token) is None:
                failures[repo] = t("access denied: accept the model's licence on huggingface.co")
        except Exception as exc:
            failures[repo] = t("{error} (have you accepted the model's licence on huggingface.co?)", error=exc)
    return {"failures": failures, **report()}
