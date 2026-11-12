# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Secrets: passed by the app through the environment, or read from the Keychain for CLI use."""

from __future__ import annotations

import os

SERVICE = "verbalog"
ENV_NAMES = {
    "anthropic-api-key": "ANTHROPIC_API_KEY",
    "hf-token": "HF_TOKEN",
    "voiceprint-key": "VERBALOG_VOICEPRINT_KEY",
}


def get_secret(name: str) -> str | None:
    value = os.environ.get(ENV_NAMES[name])
    if value:
        return value
    try:
        import keyring

        return keyring.get_password(SERVICE, name)
    except Exception:
        return None


def set_secret(name: str, value: str) -> None:
    import keyring

    keyring.set_password(SERVICE, name, value)
