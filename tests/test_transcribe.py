import numpy as np
import pytest

from verbalog import audio as au
from verbalog.model_types import SpeakerTurn
from verbalog.transcribe import (
    MAX_PROMPT_TOKENS,
    MlxTranscriber,
    _uncovered,
    build_prompt,
    fit_glossary,
    is_hallucination,
    meeting_languages,
    regions_from_turns,
)

GOOD = {"text": " Hello everyone.", "avg_logprob": -0.2, "compression_ratio": 1.2, "no_speech_prob": 0.0}


def seg(**overrides):
    return {**GOOD, **overrides}


@pytest.mark.parametrize(
    "text, fields",
    [
        ("...", {"avg_logprob": -0.3}),
        ("Spasibo", {"avg_logprob": -3.5, "no_speech_prob": 0.0}),  # no_speech_prob stays near 0 on noise
        ("hello hello hello", {"compression_ratio": 2.7}),
    ],
)
def test_unusable_segments_are_dropped(text, fields):
    assert is_hallucination(text, seg(**fields))


def test_ordinary_speech_is_kept():
    assert not is_hallucination("Hello everyone.", GOOD)


def _transcriber(monkeypatch, by_prompt):
    tr = MlxTranscriber("model", ["Enedis"])
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append(prompt)
        return {"language": "en", "segments": by_prompt[prompt is not None]}

    monkeypatch.setattr(tr, "_decode", decode)
    return tr, calls


def test_good_decode_keeps_the_prompt_and_is_not_retried(monkeypatch):
    tr, calls = _transcriber(monkeypatch, {True: [GOOD]})
    assert tr._transcribe(np.zeros(16000))["segments"] == [GOOD]
    assert calls == [tr.prompt]


@pytest.mark.parametrize(
    "bad",
    [[], [seg(text="...")], [GOOD, seg(avg_logprob=-1.5)], [seg(compression_ratio=2.5)]],
)
def test_bad_decode_falls_back_to_no_prompt_rather_than_lose_speech(monkeypatch, bad):
    recovered = [seg(text=" Recovered speech.")]
    tr, calls = _transcriber(monkeypatch, {True: bad, False: recovered})
    assert tr._transcribe(np.zeros(16000))["segments"] == recovered
    assert calls == [tr.prompt, "Enedis.", None]


def _scripted(monkeypatch, glossary, script):
    tr = MlxTranscriber("model", glossary)
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append((prompt, language))
        return {"language": language or "en", "segments": script[prompt]}

    monkeypatch.setattr(tr, "_decode", decode)
    return tr, calls


def test_retry_keeps_the_glossary_when_that_is_enough(monkeypatch):
    fixed = [seg(text=" We met Northwind.")]
    tr, calls = _scripted(monkeypatch, ["Northwind"], {build_prompt(["Northwind"]): [seg(text="...")], "Northwind.": fixed})
    assert tr._transcribe(np.zeros(16000))["segments"] == fixed
    assert [prompt for prompt, _ in calls] == [tr.prompt, "Northwind."]


def test_recited_glossary_is_retried_without_any_prompt(monkeypatch):
    terms = ["Northwind", "Zylex", "Gaspard"]
    recited = [seg(text=" Northwind, Zylex, Gaspard.")]
    real = [seg(text=" Good morning.")]
    tr, calls = _scripted(monkeypatch, terms, {build_prompt(terms): recited, "Northwind, Zylex, Gaspard.": recited, None: real})
    assert tr._transcribe(np.zeros(16000))["segments"] == real
    assert calls[-1] == (None, None)


def test_forced_language_decodes_keep_the_glossary(monkeypatch):
    script = {build_prompt(["Northwind"]): [seg(text="ありがとうございました")], "Northwind.": [GOOD]}
    tr = MlxTranscriber("model", ["Northwind"])
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append((prompt, language))
        return {"language": language or "ja", "segments": script[prompt]}

    monkeypatch.setattr(tr, "_decode", decode)
    tr._transcribe(np.zeros(16000))
    assert calls[1:] == [("Northwind.", "fr"), ("Northwind.", "en")]


def test_someone_saying_just_a_term_is_not_a_recitation():
    prompt = build_prompt(["Schneider Electric", "Northwind"])
    terms = ["Schneider Electric", "Northwind"]
    assert not is_hallucination("Schneider Electric.", GOOD, prompt, terms)
    assert is_hallucination("Schneider Electric, Northwind.", GOOD, prompt, terms)
    assert is_hallucination("Meeting in French and English.", GOOD, prompt, terms)


def test_glossary_is_cut_by_real_token_count_and_keeps_its_order():
    from mlx_whisper.tokenizer import get_tokenizer

    terms = [f"Kerguelen{i} Ouagadougou" for i in range(100)]
    kept, dropped = fit_glossary(terms)
    assert kept + dropped == terms
    assert kept and dropped
    tokenizer = get_tokenizer(multilingual=True, num_languages=100, task="transcribe")
    size = lambda names: len(tokenizer.encode(" " + build_prompt(names)))
    assert size(kept) <= MAX_PROMPT_TOKENS < size(terms[: len(kept) + 1])


def test_short_glossary_is_kept_whole():
    assert fit_glossary(["Northwind", "Zylex", "Gaspard"]) == (["Northwind", "Zylex", "Gaspard"], [])
    assert fit_glossary([]) == ([], [])


def test_decoding_never_samples_above_temperature_zero(monkeypatch):
    import mlx_whisper

    seen = {}
    monkeypatch.setattr(mlx_whisper, "transcribe", lambda audio, **kw: seen.update(kw) or {"segments": []})
    MlxTranscriber("model")._decode(np.zeros(16000), None)
    assert seen["temperature"] == 0.0
    assert seen["language"] is None


def test_uncovered_keeps_only_what_diarization_missed():
    assert _uncovered([(0.0, 10.0)], [(2.0, 3.0), (3.5, 8.0)]) == [(0.0, 2.0), (8.0, 10.0)]
    assert _uncovered([(0.0, 10.0)], [(0.0, 10.0)]) == []
    assert _uncovered([(0.0, 3.0), (5.0, 6.0)], [(5.5, 6.0)]) == [(0.0, 3.0)]


def test_speech_missed_by_diarization_is_still_transcribed():
    rng = np.random.default_rng(0)
    audio = np.zeros(au.SR * 20, dtype=np.float32) + rng.normal(0, 1e-4, au.SR * 20).astype(np.float32)
    audio[au.SR * 2 : au.SR * 5] = rng.normal(0, 0.1, au.SR * 3)  # diarized
    audio[au.SR * 10 : au.SR * 15] = rng.normal(0, 0.1, au.SR * 5)  # missed by diarization
    regions = regions_from_turns(audio, [SpeakerTurn(2.0, 5.0, "A")])
    assert any(s <= 10.5 and e >= 14.5 for s, e in regions)
    assert any(s <= 2.5 and e >= 4.5 for s, e in regions)


def test_chunk_detected_outside_french_and_english_is_decoded_as_both(monkeypatch):
    tr = MlxTranscriber("model")
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append(language)
        return {
            None: {"language": "ja", "segments": [seg(text="ありがとうございました")]},
            "fr": {"language": "fr", "segments": [seg(text=" Merci.", avg_logprob=-0.9)]},
            "en": {"language": "en", "segments": [seg(text=" Thank you.", avg_logprob=-0.4)]},
        }[language]

    monkeypatch.setattr(tr, "_decode", decode)
    result = tr._transcribe(np.zeros(16000))
    assert calls == [None, "fr", "en"]
    assert result["language"] == "en"
    assert result["segments"][0]["text"] == " Thank you."


def test_meeting_languages_keep_supported_ones_in_a_stable_order():
    assert meeting_languages(["pt", "es", "xx", "fr", "it"]) == ("fr", "es", "it", "pt")
    assert meeting_languages([]) == ("fr", "en")
    assert meeting_languages(None) == ("fr", "en")


def test_a_single_language_meeting_is_decoded_in_it(monkeypatch):
    # The reason to tick only French: a French voice must never come out as invented English.
    tr = MlxTranscriber("model", languages=["fr"])
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append(language)
        return {"language": language, "segments": [seg(text=" Bonjour.")]}

    monkeypatch.setattr(tr, "_decode", decode)
    assert tr._transcribe(np.zeros(16000))["language"] == "fr"
    assert calls == ["fr"]


def test_chunk_outside_the_meeting_languages_is_decoded_in_each_of_them(monkeypatch):
    tr = MlxTranscriber("model", languages=["de", "nl"])
    calls = []

    def decode(chunk, prompt, language=None):
        calls.append(language)
        return {
            None: {"language": "en", "segments": [seg(text=" Good morning.")]},
            "de": {"language": "de", "segments": [seg(text=" Guten Morgen.", avg_logprob=-0.3)]},
            "nl": {"language": "nl", "segments": [seg(text=" Goedemorgen.", avg_logprob=-0.8)]},
        }[language]

    monkeypatch.setattr(tr, "_decode", decode)
    result = tr._transcribe(np.zeros(16000))
    assert calls == [None, "de", "nl"]
    assert result["segments"][0]["text"] == " Guten Morgen."


def test_subtitle_credits_are_dropped_in_every_supported_language():
    for text in (
        "Untertitel im Auftrag des ZDF, 2021",
        "Vielen Dank fürs Zuschauen!",
        "Ondertiteld door de Amara.org gemeenschap",
        "Bedankt voor het kijken.",
        "Subtítulos realizados por la comunidad de Amara.org",
        "¡Gracias por ver el video!",
        "Sottotitoli creati dalla comunità Amara.org",
        "Grazie per la visione!",
        "Legendas pela comunidade Amara.org",
        "Obrigado por assistir!",
    ):
        assert is_hallucination(text, GOOD), text
    assert not is_hallucination("Wir haben das Budget intern freigegeben.", GOOD)
    assert not is_hallucination("Hemos validado el presupuesto.", GOOD)
    assert not is_hallucination("Abbiamo approvato il budget.", GOOD)
    assert not is_hallucination("Aprovamos o orçamento.", GOOD)
