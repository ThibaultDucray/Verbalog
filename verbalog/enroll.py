"""Voiceprints: biometric data, encrypted at rest and always deletable (GDPR art. 9)."""

from __future__ import annotations

import base64
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np

from . import config, keychain
from .i18n import t


def _dir(cfg: dict[str, Any]) -> Path:
    path = config.expand(cfg["speakers"]["voiceprints_dir"])
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def _fernet():
    from cryptography.fernet import Fernet

    key = keychain.get_secret("voiceprint-key")
    if not key:
        key = Fernet.generate_key().decode()
        keychain.set_secret("voiceprint-key", key)
    return Fernet(key.encode())


def _file_for(cfg: dict[str, Any], name: str) -> Path:
    return _dir(cfg) / (re.sub(r"[^\w-]+", "_", name, flags=re.UNICODE).strip("_").lower() + ".vp")


def save(cfg: dict[str, Any], name: str, embedding: np.ndarray, is_self: bool, consent: bool) -> Path:
    if not is_self and not consent:
        raise PermissionError(t("The person's explicit consent is required to record their voiceprint."))
    payload = {
        "name": name,
        "embedding": base64.b64encode(np.asarray(embedding, dtype=np.float32).tobytes()).decode(),
        "self": is_self,
        "consent": consent,
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    path = _file_for(cfg, name)
    path.write_bytes(_fernet().encrypt(json.dumps(payload).encode()))
    path.chmod(0o600)
    return path


def _load_all(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    files = sorted(_dir(cfg).glob("*.vp"))
    if not files:
        return []  # no Keychain access just to find nothing
    fernet = _fernet()
    prints = []
    for path in files:
        payload = json.loads(fernet.decrypt(path.read_bytes()))
        payload["embedding"] = np.frombuffer(base64.b64decode(payload["embedding"]), dtype=np.float32)
        prints.append(payload)
    return prints


def list_names(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    return [{k: p[k] for k in ("name", "self", "consent", "created_at")} for p in _load_all(cfg)]


def delete(cfg: dict[str, Any], name: str) -> bool:
    path = _file_for(cfg, name)
    if path.exists():
        path.unlink()
        return True
    return False


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    if a.shape != b.shape:
        return -1.0  # produced by a different embedding model
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b) / denominator) if denominator else -1.0


def identify(
    embeddings: dict[str, np.ndarray], prints: list[dict[str, Any]], threshold: float
) -> dict[str, tuple[str, float]]:
    """Match speakers to voiceprints. Each print goes to its single best speaker, so
    two speakers in the same meeting can't both be named after one person."""
    scored = sorted(
        ((cosine(embedding, p["embedding"]), label, p["name"])
         for label, embedding in embeddings.items() for p in prints),
        reverse=True,
    )
    result: dict[str, tuple[str, float]] = {}
    used: set[str] = set()
    for score, label, name in scored:
        if score >= threshold and label not in result and name not in used:
            result[label] = (name, score)
            used.add(name)
    return result


def identify_from_store(cfg: dict[str, Any], embeddings: dict[str, np.ndarray]) -> dict[str, tuple[str, float]]:
    if not embeddings:
        return {}
    return identify(embeddings, _load_all(cfg), float(cfg["speakers"]["voiceprint_threshold"]))
