"""NDJSON event stream consumed by the SwiftUI app.

ML libraries print progress bars and logs to stdout. `init_protocol` keeps a
private copy of the real stdout for events and points fd 1 at stderr, so nothing
except events can ever reach the app's parser.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Callable, TextIO

Emit = Callable[..., None]

_stream: TextIO | None = None


def init_protocol() -> None:
    global _stream
    if _stream is not None:
        return
    sys.stdout.flush()
    _stream = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr


def emit(event: str, **fields: Any) -> None:
    out = _stream or sys.stdout
    out.write(json.dumps({"event": event, **fields}, ensure_ascii=False) + "\n")
    out.flush()


def null_emit(event: str, **fields: Any) -> None:
    pass
