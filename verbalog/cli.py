"""Command-line entry point. Every command speaks NDJSON on stdout (see events.py)."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

from . import events
from .events import emit

OFFLINE_COMMANDS = {"process", "finalize", "live", "enroll"}


def _load(ref: str):
    from .session import Session

    return Session.load(ref)


def _session_from_ref(ref: str):
    """`rename` accepts a session id or the exported .json."""
    path = Path(ref).expanduser()
    if path.is_file() and path.suffix == ".json":
        return _load(json.loads(path.read_text(encoding="utf-8"))["session_id"])
    return _load(ref)


def cmd_doctor(args) -> Any:
    from . import doctor

    return doctor.report()


def cmd_setup(args) -> Any:
    from . import doctor

    return doctor.download_models(emit)


def cmd_process(args) -> Any:
    from . import pipeline

    return pipeline.process(_load(args.session), emit)


def cmd_finalize(args) -> Any:
    from . import pipeline

    decisions = json.loads(args.decisions) if args.decisions else {}
    return pipeline.finalize(_load(args.session), decisions.get("names"), decisions.get("merges"), emit)


def cmd_rename(args) -> Any:
    from . import pipeline

    return pipeline.rename_speaker(_session_from_ref(args.file), args.speaker, args.name)


def cmd_edit(args) -> Any:
    from . import edit

    return edit.apply(_load(args.session), json.loads(args.op))


def cmd_retitle(args) -> Any:
    from . import config, export

    session = _load(args.session)
    session.set(title=args.title)
    if session.transcript_path.exists() and session.data.get("status") == "done":
        export.save_outputs(session, session.load_transcript(), config.load())
    return {"session": session.id, "title": args.title}


def _pseudonym_choice(args) -> bool | None:
    return True if args.pseudonymize else False if args.no_pseudonymize else None


def cmd_prepare(args) -> Any:
    from . import pipeline

    return pipeline.prepare(_load(args.session), _pseudonym_choice(args))


def cmd_summarize(args) -> Any:
    from . import pipeline

    return pipeline.summarize(_load(args.session), emit, _pseudonym_choice(args))


def cmd_save_summary(args) -> Any:
    from . import pipeline

    return pipeline.save_summary(_load(args.session), sys.stdin.read(), not args.no_reidentify)


def cmd_live(args) -> Any:
    from . import config, live

    live.run(_load(args.session), config.load(), emit)
    return {"stopped": True}


def cmd_enroll(args) -> Any:
    from . import audio as au
    from . import config, enroll, pipeline
    from .i18n import t

    cfg = config.load()
    if args.list:
        return {"voiceprints": enroll.list_names(cfg)}
    if args.delete:
        return {"deleted": enroll.delete(cfg, args.delete)}
    if not (args.name and args.wav):
        raise ValueError(t("--name and --wav are required to record a voiceprint."))
    if not args.self_voice and not args.consent:
        raise PermissionError(t("The person's explicit consent is required (--consent)."))
    diarization = pipeline.default_diarizer(cfg)(au.read_wav(Path(args.wav)), 1)
    if not diarization.embeddings:
        raise RuntimeError(t("This diarization model didn't provide a voiceprint, or the recording is too short."))
    embedding = next(iter(diarization.embeddings.values()))
    path = enroll.save(cfg, args.name, embedding, args.self_voice, args.consent)
    return {"name": args.name, "path": str(path)}


def cmd_purge_audio(args) -> Any:
    from . import cleanup

    return {"deleted": cleanup.delete_audio(_load(args.session))}


def cmd_delete(args) -> Any:
    session = _load(args.session)
    for value in (session.data.get("outputs") or {}).values():
        if value and Path(value).exists():
            Path(value).unlink()
    shutil.rmtree(session.path)
    return {"deleted": args.session}


def cmd_config(args) -> Any:
    from . import config, pipeline

    if args.set:
        config.update(json.loads(args.set))
    return {"config": config.load(), "default_prompt": pipeline.default_prompt()}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="verbalog")
    sub = parser.add_subparsers(dest="command", required=True)

    def command(name, func, *arguments):
        p = sub.add_parser(name)
        p.set_defaults(func=func)
        for flags, options in arguments:
            p.add_argument(*flags, **options)
        return p

    session_arg = (["session"], {})
    pseudo = (
        (["--pseudonymize"], {"action": "store_true"}),
        (["--no-pseudonymize"], {"action": "store_true"}),
    )
    command("doctor", cmd_doctor)
    command("setup", cmd_setup)
    command("process", cmd_process, session_arg)
    command("finalize", cmd_finalize, session_arg, (["--decisions"], {"help": 'JSON: {"names": {...}, "merges": [[keep, absorbed]]}'}))
    command("rename", cmd_rename, (["file"], {}), (["speaker"], {}), (["name"], {}))
    command("edit", cmd_edit, session_arg, (["--op"], {"required": True, "help": "JSON, see verbalog/edit.py"}))
    command("retitle", cmd_retitle, session_arg, (["title"], {}))
    command("prepare", cmd_prepare, session_arg, *pseudo)
    command("summarize", cmd_summarize, session_arg, *pseudo)
    command("save-summary", cmd_save_summary, session_arg, (["--no-reidentify"], {"action": "store_true"}))
    command("live", cmd_live, session_arg)
    command(
        "enroll", cmd_enroll,
        (["--name"], {}), (["--wav"], {}),
        (["--self"], {"action": "store_true", "dest": "self_voice"}),
        (["--consent"], {"action": "store_true"}),
        (["--delete"], {}), (["--list"], {"action": "store_true"}),
    )
    command("purge-audio", cmd_purge_audio, session_arg)
    command("delete", cmd_delete, session_arg)
    command("config", cmd_config, (["--set"], {"help": "JSON merged into config.toml"}))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # pyannote.audio 4 reports usage (audio duration, speaker count) to otel.pyannote.ai by
    # default, which HF_HUB_OFFLINE doesn't stop. Read at its import, so set it first.
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    if args.command in OFFLINE_COMMANDS:
        # Must be set before huggingface_hub is imported: it reads this once at import.
        os.environ["HF_HUB_OFFLINE"] = "1"
    events.init_protocol()
    try:
        result = args.func(args)
    except KeyboardInterrupt:
        emit("error", message="Interrompu.")
        return 130
    except Exception as exc:
        emit("error", message=str(exc) or exc.__class__.__name__, kind=exc.__class__.__name__)
        return 1
    emit("result", **(result or {}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
