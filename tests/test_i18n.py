"""English is the default; every message has a French translation with the same placeholders."""

import ast
import re
import string
from pathlib import Path

import numpy as np

from conftest import speech
from verbalog import audio as au
from verbalog import config, i18n, pipeline
from verbalog.model_types import Diarization, Segment, SpeakerTurn, Word
from verbalog.session import Session

ROOT = Path(__file__).parent.parent


def fields(text):
    return {name for _, name, _, _ in string.Formatter().parse(text) if name}


def test_english_is_the_default_language():
    assert config.DEFAULTS["general"]["language"] == "en"


def test_french_table_keeps_placeholders():
    for english, french in i18n.FR.items():
        assert fields(english) == fields(french), english


def test_every_message_passed_to_t_has_a_french_translation_and_vice_versa():
    used = set()
    for path in (ROOT / "verbalog").glob("*.py"):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "t" and node.args:
                if isinstance(node.args[0], ast.Constant):
                    used.add(node.args[0].value)
    # Passed through a variable or a table.
    used |= {"Room speaker {n}", "Remote speaker {n}", "Speaker {n}", "room", "remote", "BOOKMARK"}
    assert used - set(i18n.FR) == set()
    assert set(i18n.FR) - used == set()


def _swift_strings():
    text = (ROOT / "app/Resources/fr.lproj/Localizable.strings").read_text(encoding="utf-8")
    return dict(re.findall(r'^"(.+)" = "(.+)";$', text, re.M))


def test_swift_french_table_keeps_format_specifiers():
    table = _swift_strings()
    assert len(table) > 200
    for english, french in table.items():
        assert re.findall(r"%(?:lld|d|@)", english) == re.findall(r"%(?:lld|d|@)", french), english


def test_no_french_left_in_swift_sources():
    # Allowed: the voiceprint script, read aloud in both languages, and a language's own name.
    allowed = ("Bonjour, je lis ce texte", "à mon rythme", 'Text(verbatim: "Français")')
    leftovers = []
    for path in (ROOT / "app/Sources").rglob("*.swift"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("//") or any(a in line for a in allowed):
                continue
            for literal in re.findall(r'"(?:[^"\\]|\\.)*"', line):
                if re.search(r"[éèêàçùôîœ«»]", literal):
                    leftovers.append(f"{path.name}:{number} {literal}")
    assert leftovers == []


def _finished_session():
    session = Session.create("Meeting", "presentiel")
    mic = np.concatenate([speech(3, seed=1), np.zeros(16000, np.float32), speech(3, seed=2)])
    au.write_wav(session.mic_path, mic)
    with session.notes_path.open("w", encoding="utf-8") as fh:
        fh.write('{"t": 1, "text": "! Send the deck"}\n{"t": 5, "text": ""}\n')

    class Transcriber:
        def transcribe_regions(self, audio, regions, progress=None):
            word = lambda text, start, end: Segment(start, end, text, "en", [Word(" " + text, start, end, 0.9, "en")])
            return [word("Hello", 0.5, 2.5), word("Thanks", 4.5, 6.5)]

    diarizer = lambda audio, n=None: Diarization([SpeakerTurn(0, 3, "A"), SpeakerTurn(4, 7, "B")], {})
    pipeline.process(session, transcriber=Transcriber(), diarizer=diarizer)
    return pipeline.finalize(Session.load(session.id))


def test_english_export():
    config.update({"general": {"language": "en"}})
    result = _finished_session()
    md = Path(result["outputs"]["md"]).read_text(encoding="utf-8")
    assert "## Organizer notes (summary)" in md and "## Transcript" in md
    assert "**[00:00:00] Speaker 1:** Hello" in md
    assert "> **BOOKMARK [00:00:05]**" in md
    assert "  - Speaker 1 (room, unidentified)" in md
    for french in ("Intervenant", "SIGNET", "organisateur", "salle"):
        assert french not in md


def test_french_export():
    config.update({"general": {"language": "fr"}})
    md = Path(_finished_session()["outputs"]["md"]).read_text(encoding="utf-8")
    assert "**[00:00:00] Intervenant 1 :** Hello" in md and "> **SIGNET [00:00:05]**" in md


def test_prompt_follows_language_and_matches_export_markers():
    config.update({"general": {"language": "en"}, "claude": {"output_language": "fr"}})
    prompt = pipeline.load_prompt(config.load())
    assert "BOOKMARK" in prompt and "Write in French" in prompt and "{{" not in prompt
    config.update({"general": {"language": "fr"}})
    assert "SIGNET" in pipeline.load_prompt(config.load())


def test_error_messages_follow_language():
    config.update({"general": {"language": "en"}})
    assert i18n.t("Session not found: {ref}", ref="x") == "Session not found: x"
    config.update({"general": {"language": "fr"}})
    assert i18n.t("Session not found: {ref}", ref="x") == "Session introuvable : x"
