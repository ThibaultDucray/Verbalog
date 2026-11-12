# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""On-disk session: one private directory per meeting, shared with the app."""

from __future__ import annotations

import json
import os
import re
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from . import config
from .i18n import t

MODES = ("visio", "presentiel", "hybride")


def sessions_dir() -> Path:
    return config.home() / "sessions"


def slugify(title: str) -> str:
    ascii_title = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-zA-Z0-9]+", "-", ascii_title).strip("-").lower()[:60] or "reunion"


def write_json_atomic(path: Path, data: Any) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


@dataclass
class Session:
    path: Path
    data: dict[str, Any]

    @classmethod
    def load(cls, ref: str | Path) -> "Session":
        path = Path(ref).expanduser()
        if not (path / "session.json").exists():
            path = sessions_dir() / str(ref)
        file = path / "session.json"
        if not file.exists():
            raise FileNotFoundError(t("Session not found: {ref}", ref=ref))
        return cls(path, json.loads(file.read_text(encoding="utf-8")))

    @classmethod
    def create(cls, title: str, mode: str = "visio", **fields: Any) -> "Session":
        """Used by tests and the CLI; the app writes the same layout from Swift."""
        now = datetime.now().astimezone()
        base = f"{now:%Y-%m-%d_%H%M}_{slugify(title)}"
        root = sessions_dir()
        root.mkdir(parents=True, exist_ok=True)
        os.chmod(root, 0o700)
        path, n = root / base, 1
        while path.exists():
            n += 1
            path = root / f"{base}-{n}"
        path.mkdir(mode=0o700)
        data = {
            "id": path.name,
            "title": title,
            "created_at": now.isoformat(timespec="seconds"),
            "mode": mode,
            "headset": True,
            "room_count": None,
            "remote_count": None,
            "participants": [],
            "status": "recorded",
            "warnings": [],
            "outputs": {},
        }
        data.update(fields)
        session = cls(path, data)
        session.save()
        return session

    def save(self) -> None:
        write_json_atomic(self.path / "session.json", self.data)

    def set(self, **fields: Any) -> None:
        # Re-read first: the app may have changed title/participants meanwhile.
        current = json.loads((self.path / "session.json").read_text(encoding="utf-8"))
        current.update(fields)
        self.data = current
        self.save()

    @property
    def id(self) -> str:
        return self.data["id"]

    @property
    def mode(self) -> str:
        return self.data.get("mode", "visio")

    @property
    def mic_path(self) -> Path:
        return self.path / "mic.wav"

    @property
    def system_path(self) -> Path:
        return self.path / "system.wav"

    @property
    def notes_path(self) -> Path:
        return self.path / "notes.jsonl"

    @property
    def transcript_path(self) -> Path:
        return self.path / "transcript.json"

    @property
    def mapping_path(self) -> Path:
        return self.path / ".mapping.json"

    @property
    def stem(self) -> str:
        created = datetime.fromisoformat(self.data["created_at"])
        return f"{created:%Y-%m-%d_%H%M}_{slugify(self.data['title'])}"

    def load_transcript(self) -> dict[str, Any]:
        if not self.transcript_path.exists():
            raise FileNotFoundError(t("Transcript missing: run processing first."))
        return json.loads(self.transcript_path.read_text(encoding="utf-8"))

    def save_transcript(self, doc: dict[str, Any]) -> None:
        write_json_atomic(self.transcript_path, doc)
