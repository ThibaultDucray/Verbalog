# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Claude API mode: `verbalog summarize`."""

from __future__ import annotations

from typing import Any

from .events import Emit
from .i18n import t
from .keychain import get_secret

FALLBACK_BETA = "server-side-fallback-2026-07-01"
# Models that accept the server-side `fallbacks` parameter.
FALLBACK_MODELS = ("claude-fable-5", "claude-opus-5", "claude-sonnet-5-5")


class SummaryError(RuntimeError):
    pass


def summarize_text(system_prompt: str, transcript: str, cfg: dict[str, Any], emit: Emit) -> str:
    import anthropic

    api_key = get_secret("anthropic-api-key")
    if not api_key:
        raise SummaryError(t("No Anthropic API key: add one in Settings."))
    model = cfg["claude"]["model"]
    extra: dict[str, Any] = {}
    if model.startswith(FALLBACK_MODELS):
        # A classifier false positive on a meeting shouldn't cost the summary:
        # the API re-runs a declined request on Anthropic's recommended model.
        extra = {"betas": [FALLBACK_BETA], "fallbacks": "default"}

    client = anthropic.Anthropic(api_key=api_key)
    try:
        # Streaming: a long meeting can take minutes, which a plain request would time out on.
        with client.beta.messages.stream(
            model=model,
            max_tokens=64000,
            thinking={"type": "adaptive"},
            output_config={"effort": "high"},
            system=system_prompt,
            messages=[{"role": "user", "content": f"<transcription>\n{transcript}\n</transcription>"}],
            **extra,
        ) as stream:
            for delta in stream.text_stream:
                emit("delta", text=delta)
            final = stream.get_final_message()
    except anthropic.AuthenticationError as exc:
        raise SummaryError(t("Anthropic API key rejected.")) from exc
    except anthropic.NotFoundError as exc:
        raise SummaryError(t("Unknown or unauthorized model: {model}", model=model)) from exc
    except anthropic.RateLimitError as exc:
        raise SummaryError(t("API rate limit reached: try again shortly.")) from exc
    except anthropic.APIStatusError as exc:
        raise SummaryError(t("Anthropic API error ({status}): {message}", status=exc.status_code, message=exc.message)) from exc
    except anthropic.APIConnectionError as exc:
        raise SummaryError(t("Can't connect to the Anthropic API.")) from exc

    if final.stop_reason == "refusal":
        raise SummaryError(t("The model declined to process this transcript."))
    text = "".join(block.text for block in final.content if block.type == "text").strip()
    if not text:
        raise SummaryError(t("Empty response from the model."))
    if final.stop_reason == "max_tokens":
        emit("warning", message=t("The summary reached the maximum length and may be cut off."))
    return text
