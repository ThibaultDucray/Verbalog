"""The full pipeline per meeting context, with models replaced by deterministic fakes."""

import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from conftest import speech
from verbalog import audio as au
from verbalog import cli, config, enroll, events, export, pipeline
from verbalog.model_types import Diarization, Segment, SpeakerTurn, Word
from verbalog.session import Session

SILENCE = lambda s: np.zeros(int(s * 16000), np.float32)


def make_seg(text, start, end, lang="fr"):
    tokens = text.split()
    step = (end - start) / len(tokens)
    words = [Word(" " + t, start + i * step, start + (i + 1) * step, 0.9, lang) for i, t in enumerate(tokens)]
    return Segment(start, end, text, lang, words)


class FakeDiarizer:
    def __init__(self, by_length, embeddings=None):
        self.by_length = by_length
        self.embeddings = embeddings or {}
        self.calls = []

    def __call__(self, audio, num_speakers=None):
        self.calls.append((audio.copy(), num_speakers))
        return Diarization(self.by_length[len(audio)], self.embeddings)


class BrokenDiarizer:
    def __call__(self, audio, num_speakers=None):
        raise RuntimeError("modèle absent")


def notes(session, rows):
    with session.notes_path.open("w", encoding="utf-8") as fh:
        for t, text in rows:
            fh.write(json.dumps({"t": t, "text": text}, ensure_ascii=False) + "\n")
        fh.write('{"t": 3, "text": "ligne coup')  # crash mid-write


def visio_session(**fields):
    session = Session.create("Comité: pilotage SMOC", "visio", **fields)
    mic = np.concatenate([speech(3, seed=1), SILENCE(9)])
    system = np.concatenate([SILENCE(4), speech(4, seed=2), SILENCE(1), speech(3, seed=3)])
    au.write_wav(session.mic_path, mic)
    au.write_wav(session.system_path, system)
    # What the pipeline will actually read: 16-bit samples, not these floats.
    return session, au.read_wav(session.mic_path), au.read_wav(session.system_path)


def transcriber_for(mic, system, mic_segments, system_segments):
    # Both tracks may have equal lengths, so key by array identity via a small wrapper.
    class T:
        def transcribe_regions(self, audio, regions, progress=None):
            segs = system_segments if np.array_equal(audio, system) else mic_segments
            if progress:
                progress(1.0)
            return [s for s in segs if any(a - 0.5 <= s.start <= b for a, b in regions)]

    return T()


def run_visio(session, mic, system):
    transcriber = transcriber_for(
        mic, system,
        [make_seg("Bonjour à tous", 0.2, 2.8)],
        [make_seg("Right the rollout depends on MDM", 4.2, 7.8, "en"), make_seg("Oui tout à fait", 9.2, 11.8)],
    )
    diarizer = FakeDiarizer({len(system): [SpeakerTurn(4.0, 8.0, "SPEAKER_00"), SpeakerTurn(9.0, 12.0, "SPEAKER_01")]})
    return pipeline.process(session, transcriber=transcriber, diarizer=diarizer), diarizer


def test_visio_fully_named_exports_and_deletes_audio():
    session, mic, system = visio_session(participants=["Marc", "Sophie"], remote_count=2)
    notes(session, [(5.0, "@Marc"), (10.0, "ici c'est Sophie"), (6.0, "! Envoyer la grille"), (6.5, "~ secret perso"), (11.0, "")])
    result, diarizer = run_visio(session, mic, system)

    assert result["status"] == "done"
    assert diarizer.calls[0][1] == 2  # known head count reaches pyannote
    assert not session.mic_path.exists() and not session.system_path.exists()

    md = Path(result["outputs"]["md"]).read_text(encoding="utf-8")
    assert md.startswith("---\ntitle: \"Comité: pilotage SMOC\"")
    assert "**[00:00:00] Camille :** Bonjour à tous" in md
    assert "**[00:00:04] Marc :** Right the rollout depends on MDM" in md
    assert "**[00:00:09] Sophie :** Oui tout à fait" in md
    assert "- ACTION [00:00:06] Envoyer la grille" in md
    assert "> **SIGNET [00:00:11]**" in md
    assert "languages: [en, fr]" in md
    # Consumed or private: never in the file meant for the LLM.
    assert "secret perso" not in md and "@Marc" not in md and "ici c'est" not in md
    # A note lands after the turn in progress, not inside it.
    assert md.index("Right the rollout") < md.index("> **ACTION [00:00:06]**") < md.index("Oui tout à fait")

    # The JSON keeps the private note and word timings.
    saved = json.loads(Path(result["outputs"]["json"]).read_text(encoding="utf-8"))
    assert any(n["type"] == "private" for n in saved["notes"])
    assert saved["turns"][0]["words"][0]["start"] == 0.2


def test_naming_applies_to_the_whole_meeting_including_before_the_hint():
    session, mic, system = visio_session(participants=["Marc"])
    notes(session, [(11.0, "@marc")])  # said during the last turn, names that speaker everywhere
    result, _ = run_visio(session, mic, system)
    assert result["status"] == "review"
    doc = session.load_transcript()
    assert doc["speakers"]["DISTANT_2"]["name"] == "Marc"
    assert doc["speakers"]["DISTANT_1"]["name"] is None
    assert session.mic_path.exists()  # kept: the review screen can replay it


def test_review_then_finalize_with_names_and_merge():
    session, mic, system = visio_session()
    run_visio(session, mic, system)
    assert session.load_transcript()["needs_review"]
    assert Session.load(session.id).data["status"] == "review"

    samples = session.load_transcript()["speakers"]["DISTANT_1"]["samples"]
    assert samples and samples[0]["text"].startswith("Right")

    result = pipeline.finalize(Session.load(session.id), names={"DISTANT_1": "Karim"}, merges=[["DISTANT_1", "DISTANT_2"]])
    md = Path(result["outputs"]["md"]).read_text(encoding="utf-8")
    assert "Karim : **" not in md
    assert md.count("Karim :") == 2
    assert "DISTANT_2" not in json.dumps(session.load_transcript()["speakers"])
    assert result["audio_deleted"]


def test_finalize_without_names_leaves_anonymous_speakers():
    session, mic, system = visio_session()
    run_visio(session, mic, system)
    result = pipeline.finalize(Session.load(session.id))
    md = Path(result["outputs"]["md"]).read_text(encoding="utf-8")
    assert "Intervenant 1 :" in md and "Intervenant 2 :" in md
    assert "  - Intervenant 1 (distant, non identifié)\n" in md


def _hybrid():
    session = Session.create("Hybride", "hybride", room_count=2, remote_count=1)
    system = np.concatenate([speech(4, seed=5), SILENCE(8)])
    rng = np.random.default_rng(1)
    mic = rng.standard_normal(len(system)).astype(np.float32) * 0.002
    mic[3200:3200 + 16000 * 4] += system[: 16000 * 4] * 0.5  # the room mic hears the loudspeaker
    mic[16000 * 6:16000 * 8] += speech(2, 220, seed=6)
    mic[16000 * 9:16000 * 11] += speech(2, 300, seed=7)
    au.write_wav(session.mic_path, mic)
    au.write_wav(session.system_path, system)
    return session, mic, system


def test_hybrid_removes_echo_diarizes_cleaned_mic_and_labels_by_origin():
    session, mic, system = _hybrid()
    # Reload from disk: the pipeline reads 16-bit samples, not these floats.
    mic_disk, system_disk = au.read_wav(session.mic_path), au.read_wav(session.system_path)
    transcriber = transcriber_for(
        mic_disk, system_disk,
        [
            make_seg("the plan is ready to go", 0.3, 3.9, "en"),
            make_seg("on valide le plan", 6.1, 7.9),
            make_seg("je suis d'accord", 9.1, 10.9),
        ],
        [make_seg("the plan is ready to go", 0.1, 3.9, "en")],
    )
    calls = []

    def fake(audio, num_speakers=None):
        calls.append((audio.copy(), num_speakers))
        if np.array_equal(audio, system_disk):
            return Diarization([SpeakerTurn(0.0, 4.0, "SPEAKER_00")], {})
        return Diarization([SpeakerTurn(6.0, 8.0, "SPEAKER_07"), SpeakerTurn(9.0, 11.0, "SPEAKER_03")], {})

    result = pipeline.process(session, transcriber=transcriber, diarizer=fake)
    assert result["status"] == "review"
    doc = session.load_transcript()

    texts = [t["text"] for t in doc["turns"]]
    assert texts.count("the plan is ready to go") == 1  # phase 4 acceptance: no remote sentence twice
    assert {t["label"] for t in doc["turns"]} == {"DISTANT_1", "SALLE_1", "SALLE_2"}
    assert doc["speakers"]["SALLE_2"]["display"] == "Intervenant salle 2"
    assert doc["speakers"]["DISTANT_1"]["display"] == "Intervenant distant 1"
    assert len(doc["dedup_removed"]) == 1

    # Diarization of the mic ran after dedup: it must not hear the echo.
    mic_call = calls[1]
    assert mic_call[1] == 2
    assert au.rms_db(au.slice_seconds(mic_call[0], 0.5, 3.0)) < -100

    # Echoes count as accounted for, so the audio can be deleted.
    final = pipeline.finalize(Session.load(session.id))
    assert final["coverage"] >= 0.9 and final["audio_deleted"]


def test_presentiel_ignores_system_and_diarizes_mic():
    session = Session.create("Salle", "presentiel", room_count=2)
    mic = np.concatenate([speech(3, seed=1), SILENCE(1), speech(3, seed=2)])
    au.write_wav(session.mic_path, mic)
    au.write_wav(session.system_path, speech(7, seed=9))  # stray file must not be used
    mic_disk = au.read_wav(session.mic_path)
    transcriber = transcriber_for(mic_disk, None, [make_seg("Premier", 0.2, 2.8), make_seg("Second", 4.2, 6.8)], [])
    seen = []

    def fake(audio, n=None):
        seen.append(n)
        return Diarization([SpeakerTurn(0, 3, "A"), SpeakerTurn(4, 7, "B")], {})

    assert pipeline.process(session, transcriber=transcriber, diarizer=fake)["status"] == "review"
    assert seen == [2]
    assert {t["track"] for t in session.load_transcript()["turns"]} == {"mic"}


def test_voiceprint_names_speaker_but_live_hint_wins():
    cfg = config.load()
    enroll.save(cfg, "Camille", np.array([1.0, 0.0, 0.0], np.float32), True, False)
    enroll.save(cfg, "Jim", np.array([0.0, 1.0, 0.0], np.float32), False, True)
    session = Session.create("Salle", "presentiel")
    mic = np.concatenate([speech(3, seed=1), SILENCE(1), speech(3, seed=2)])
    au.write_wav(session.mic_path, mic)
    mic_disk = au.read_wav(session.mic_path)
    transcriber = transcriber_for(mic_disk, None, [make_seg("Moi", 0.2, 2.8), make_seg("Lui", 4.2, 6.8)], [])
    notes(session, [(5.0, "@Karim")])
    embeddings = {"A": np.array([0.99, 0.1, 0.0], np.float32), "B": np.array([0.1, 0.99, 0.0], np.float32)}

    def fake(audio, n=None):
        return Diarization([SpeakerTurn(0, 3, "A"), SpeakerTurn(4, 7, "B")], embeddings)

    result = pipeline.process(session, transcriber=transcriber, diarizer=fake)
    assert result["status"] == "done"
    doc = session.load_transcript()
    assert doc["speakers"]["SALLE_1"]["name"] == "Camille"
    assert doc["speakers"]["SALLE_1"]["source"] == "voiceprint"
    assert doc["speakers"]["SALLE_2"]["name"] == "Karim"
    assert doc["speakers"]["SALLE_2"]["source"] == "hint"


def test_voiceprints_are_encrypted_consent_gated_and_deletable():
    cfg = config.load()
    path = enroll.save(cfg, "Camille", np.ones(4, np.float32), True, False)
    assert b"Camille" not in path.read_bytes()
    with pytest.raises(PermissionError):
        enroll.save(cfg, "Jim", np.ones(4, np.float32), False, False)
    assert enroll.list_names(cfg)[0]["name"] == "Camille"
    assert enroll.delete(cfg, "Camille") and enroll.list_names(cfg) == []


def test_identify_gives_each_print_to_one_speaker_only():
    prints = [{"name": "Jim", "embedding": np.array([1.0, 0.0], np.float32)}]
    embeddings = {"A": np.array([1.0, 0.1], np.float32), "B": np.array([1.0, 0.0], np.float32)}
    assert list(enroll.identify(embeddings, prints, 0.5)) == ["B"]
    assert enroll.identify({"A": np.array([0.0, 1.0], np.float32)}, prints, 0.5) == {}


def test_without_diarization_pipeline_still_produces_transcript_and_warns():
    session, mic, system = visio_session()
    transcriber = transcriber_for(mic, system, [make_seg("Bonjour", 0.2, 2.8)], [make_seg("Hello there", 4.2, 7.8, "en"), make_seg("Oui", 9.2, 11.8)])
    result = pipeline.process(session, transcriber=transcriber, diarizer=BrokenDiarizer())
    assert result["status"] == "review"
    doc = session.load_transcript()
    assert "DISTANT_1" in doc["speakers"]
    assert any("Diarisation indisponible" in w for w in doc["warnings"])


def test_low_coverage_keeps_audio_and_warns():
    session, mic, system = visio_session()
    transcriber = transcriber_for(mic, system, [make_seg("Bonjour", 0.2, 2.8)], [])  # system never transcribed
    result = pipeline.process(session, transcriber=transcriber, diarizer=BrokenDiarizer())
    assert result["status"] == "done"
    assert result["audio_deleted"] == []
    assert session.mic_path.exists()
    assert any("Audio conservé" in w for w in Session.load(session.id).data["warnings"])


def test_failure_is_recorded_and_audio_preserved():
    session, mic, system = visio_session()

    class Boom:
        def transcribe_regions(self, *a, **k):
            raise RuntimeError("GPU indisponible")

    with pytest.raises(RuntimeError):
        pipeline.process(session, transcriber=Boom(), diarizer=BrokenDiarizer())
    saved = Session.load(session.id).data
    assert saved["status"] == "failed" and "GPU" in saved["error"]
    assert session.mic_path.exists()


def test_missing_audio_fails_cleanly():
    session = Session.create("Vide", "visio")
    with pytest.raises(FileNotFoundError):
        pipeline.process(session, transcriber=object(), diarizer=object())


def _done_session():
    session, mic, system = visio_session(participants=["Marc"])
    notes(session, [(5.0, "@Marc"), (10.0, "@Marc+")])
    result, _ = run_visio(session, mic, system)
    result = pipeline.finalize(Session.load(session.id), names={"DISTANT_2": "Karim"})
    return Session.load(session.id), result


def test_rename_regenerates_markdown_without_retranscribing():
    session, result = _done_session()
    md_path = Path(result["outputs"]["md"])
    assert "Karim :" in md_path.read_text(encoding="utf-8")
    pipeline.rename_speaker(session, "Karim", "Julie")
    text = md_path.read_text(encoding="utf-8")
    assert "Julie :" in text and "Karim :" not in text
    with pytest.raises(KeyError):
        pipeline.rename_speaker(session, "Inconnu", "X")


def test_rename_via_cli_accepts_exported_json(capfd):
    session, result = _done_session()
    code = cli.main(["rename", result["outputs"]["json"], "Karim", "Julie"])
    assert code == 0
    assert "Julie :" in Path(result["outputs"]["md"]).read_text(encoding="utf-8")
    events._stream = None


def test_retitle_moves_output_files():
    session, result = _done_session()
    old_md = Path(result["outputs"]["md"])
    session.set(title="Nouveau titre")
    outputs = export.save_outputs(session, session.load_transcript(), config.load())
    assert not old_md.exists()
    assert "nouveau-titre" in outputs["md"]
    assert "# Nouveau titre" in Path(outputs["md"]).read_text(encoding="utf-8")


def test_prepare_pseudonymizes_payload_and_save_summary_restores_names():
    session, result = _done_session()
    (config.home() / "sensitive.txt").write_text("CLIENT: MDM\n", encoding="utf-8")
    prepared = pipeline.prepare(session, True, use_ner=False)
    payload = prepared["payload"]
    assert "MDM" not in payload and "Marc" not in payload and "Camille" not in payload
    assert "Tu reçois la transcription" in payload and "{{output_language}}" not in payload
    assert "<transcription>" in payload
    alias = next(a for a, v in json.loads(session.mapping_path.read_text()).items() if v == "Marc")

    saved = pipeline.save_summary(session, f"Action pour {alias} sur CLIENT_A.", True)
    assert saved["text"] == "Action pour Marc sur MDM."
    assert Path(saved["summary_path"]).name.endswith("_synthese.md")
    assert Session.load(session.id).data["outputs"]["summary"] == saved["summary_path"]


def test_prepare_without_pseudonyms_is_plain_and_private_notes_stay_out():
    session, mic, system = visio_session(participants=["Marc"])
    notes(session, [(6.5, "~ secret perso")])
    run_visio(session, mic, system)
    pipeline.finalize(Session.load(session.id))
    prepared = pipeline.prepare(Session.load(session.id), False)
    assert prepared["aliases"] == []
    assert "Camille" in prepared["transcript"]
    assert "secret perso" not in prepared["payload"]


def test_sensitive_terms_reach_whisper_prompt_but_not_the_exported_glossary():
    (config.home() / "sensitive.txt").write_text("CLIENT: Enedis\n", encoding="utf-8")
    (config.home() / "glossary.txt").write_text("SMOC\n", encoding="utf-8")
    assert "Enedis" in pipeline.default_transcriber(config.load()).prompt
    assert config.read_glossary(config.load()) == ["SMOC"]


def test_participants_reach_the_whisper_prompt_first():
    (config.home() / "glossary.txt").write_text("Northwind, Zylex\n", encoding="utf-8")
    transcriber = pipeline.default_transcriber(config.load(), ["Gaspard", "Northwind"])
    assert transcriber.terms == ["Gaspard", "Northwind", "Zylex"]


def test_meeting_participants_and_languages_are_given_to_the_default_transcriber(monkeypatch):
    session, mic, system = visio_session(participants=["Gaspard"])
    session.set(languages=["es"])
    seen = {}

    def default(cfg, participants=(), languages=()):
        seen["participants"], seen["languages"] = participants, languages
        return transcriber_for(mic, system, [make_seg("Bonjour", 0.2, 2.8)], [])

    monkeypatch.setattr(pipeline, "default_transcriber", default)
    pipeline.process(session, diarizer=FakeDiarizer({}))
    assert seen == {"participants": ["Gaspard"], "languages": ["es"]}


def test_overlong_glossary_warns_without_naming_the_terms():
    session, mic, system = visio_session()
    transcriber = transcriber_for(mic, system, [make_seg("Bonjour", 0.2, 2.8)], [])
    transcriber.dropped_terms = ["CLIENT-SECRET", "OTHER"]
    pipeline.process(session, transcriber=transcriber, diarizer=FakeDiarizer({}))
    warnings = Session.load(session.id).data["warnings"]
    assert any("the last 2 terms" in w or "les 2 derniers termes" in w for w in warnings)
    assert "CLIENT-SECRET" not in " ".join(warnings)


def test_default_paths_follow_verbalog_home(monkeypatch, tmp_path):
    monkeypatch.setenv("VERBALOG_HOME", str(tmp_path / "elsewhere"))
    assert config.expand("~/.verbalog/sensitive.txt") == tmp_path / "elsewhere" / "sensitive.txt"
    assert config.expand("~/.verbalog") == tmp_path / "elsewhere"
    assert config.expand("~/Verbalog") == Path.home() / "Verbalog"


def test_concurrent_config_saves_all_land():
    # Each save from the app is its own process; none may fail or erase another.
    code = "import json, sys; from verbalog import config; config.update(json.loads(sys.argv[1]))"
    env = {**os.environ, "PYTHONPATH": str(Path(config.__file__).parents[1])}
    saves = [
        subprocess.Popen(
            [sys.executable, "-c", code, json.dumps({"race": {f"key{i}": i}})],
            env=env,
            stderr=subprocess.PIPE,
            text=True,
        )
        for i in range(12)
    ]
    errors = [save.communicate()[1] for save in saves]
    assert [save.returncode for save in saves] == [0] * 12, errors
    assert config.load()["race"] == {f"key{i}": i for i in range(12)}


def test_user_prompt_override_and_language():
    config.update({"claude": {"output_language": "en"}})
    assert "anglais" in pipeline.load_prompt(config.load())
    custom = config.home() / "prompts"
    custom.mkdir()
    (custom / "synthese.md").write_text("Résume en {{output_language}}.", encoding="utf-8")
    assert pipeline.load_prompt(config.load()) == "Résume en anglais."


def test_summarize_with_stubbed_api(monkeypatch):
    """Exercises our request against the real SDK, with a local server standing in for the API."""
    import http.server
    import threading

    received = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            received["body"] = json.loads(self.rfile.read(int(self.headers["content-length"])))
            received["beta"] = self.headers.get("anthropic-beta")
            events_ = [
                ("message_start", {"type": "message_start", "message": {"id": "m", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Action pour PERSONNE_1."}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for name, data in events_:
                self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("ANTHROPIC_BASE_URL", f"http://127.0.0.1:{server.server_address[1]}")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    session, _ = _done_session()
    deltas = []
    saved = pipeline.summarize(session, lambda event, **f: deltas.append(f.get("text")) if event == "delta" else None, True)
    server.shutdown()

    assert deltas == ["Action pour PERSONNE_1."]
    mapping = json.loads(session.mapping_path.read_text())
    assert saved["text"] == f"Action pour {mapping['PERSONNE_1']}."
    body = received["body"]
    assert body["model"] == "claude-opus-5-5"
    assert body["fallbacks"] == "default" and "server-side-fallback-2026-07-01" in received["beta"]
    assert body["thinking"] == {"type": "adaptive"}
    assert "Marc" not in json.dumps(body["messages"])


def test_summarize_without_key_reports_it(monkeypatch):
    from verbalog import claude_client, keychain

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setattr(claude_client, "get_secret", lambda name: None)
    with pytest.raises(claude_client.SummaryError, match="clé API"):
        claude_client.summarize_text("p", "t", config.load(), lambda *a, **k: None)


def test_cli_turns_off_pyannote_telemetry(monkeypatch):
    # "Nothing leaves this Mac": pyannote would otherwise report each diarization run.
    monkeypatch.setenv("PYANNOTE_METRICS_ENABLED", "true")
    assert cli.main(["config"]) == 0
    assert os.environ["PYANNOTE_METRICS_ENABLED"] == "0"
    metrics = pytest.importorskip("pyannote.audio.telemetry.metrics")  # the diarization extra
    assert not metrics.is_metrics_enabled()


def test_config_file_keeps_only_what_differs_from_the_defaults():
    # Saving every default froze them in the file, so improved defaults never reached anyone.
    config.update({"general": {"user_name": "Camille"}, "notes": {"anchor": "first_keystroke"}})
    saved = (config.home() / "config.toml").read_text(encoding="utf-8")
    assert 'user_name = "Camille"' in saved
    assert "anchor" not in saved and "naming_patterns" not in saved and "glossary_file" in saved  # set by conftest
    assert config.load()["notes"]["anchor"] == "first_keystroke"


def test_naming_patterns_frozen_by_older_versions_follow_the_defaults_again():
    import tomllib

    import tomli_w

    path = config.home() / "config.toml"
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    data["speakers"]["naming_patterns"] = ["ici c'est {nom}", "c'est {nom} qui parle", "{nom} parle", "this is {nom}", "{nom} speaking"]
    path.write_text(tomli_w.dumps(data), encoding="utf-8")
    assert "hier ist {nom}" in config.load()["speakers"]["naming_patterns"]
    custom = ["moi c'est {nom}"]
    config.update({"speakers": {"naming_patterns": custom}})
    assert config.load()["speakers"]["naming_patterns"] == custom  # a real choice is kept


def test_meeting_languages_reach_the_transcriber(monkeypatch):
    cfg = config.load()
    assert pipeline.default_transcriber(cfg).languages == ("fr", "en")
    assert pipeline.default_transcriber(cfg, languages=["es"]).languages == ("es",)
    config.update({"transcription": {"languages": ["de", "nl"]}})
    assert pipeline.default_transcriber(config.load()).languages == ("de", "nl")
