# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

"""Orchestration: process a recorded session, then finalize it after review."""

from __future__ import annotations

from importlib import resources
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from . import audio as au
from . import cleanup, config, dedup, edit, enroll, export, merge, naming, pseudonymize
from .diarize import Diarizer, PyannoteDiarizer, relabel
from .events import Emit, null_emit
from .i18n import language, t
from .keychain import get_secret
from .model_types import Diarization, SpeakerTurn
from .notes import load_notes
from .session import Session
from .transcribe import MlxTranscriber, Transcriber, regions_from_turns, regions_from_vad


class Stages:
    """Maps per-stage progress onto a single 0-1 bar."""

    def __init__(self, emit: Emit, plan: list[tuple[str, str, float]]):
        self.emit = emit
        self.plan = plan
        self.total = sum(weight for _, _, weight in plan)
        self.done = 0.0

    def run(self, stage: str):
        label, weight = next((l, w) for s, l, w in self.plan if s == stage)
        base = self.done
        self.emit("progress", stage=stage, label=label, fraction=round(base / self.total, 4))

        def report(fraction: float) -> None:
            value = (base + weight * min(fraction, 1.0)) / self.total
            self.emit("progress", stage=stage, label=label, fraction=round(value, 4))

        self.done += weight
        return report


def _read_track(path: Path) -> np.ndarray | None:
    if not path.exists() or path.stat().st_size <= au.HEADER_SIZE:
        return None
    return au.read_wav(path)


def _count(value: Any) -> int | None:
    return value if isinstance(value, int) and value > 0 else None


def _diarize(diarizer: Diarizer, audio: np.ndarray, count: int | None, prefix: str, warnings: list[str]) -> Diarization | None:
    try:
        return relabel(diarizer(audio, count), prefix)
    except Exception as exc:  # the transcript is still worth having without speaker separation
        warnings.append(t("Diarization unavailable, voices on this track aren't separated: {error}", error=exc))
        return None


def default_transcriber(cfg: dict[str, Any], participants: Sequence[str] = (), languages: Sequence[str] = ()) -> Transcriber:
    # Sensitive terms stay on this machine at this stage. Whisper spelling them right
    # is what lets the pseudonymizer recognize them later.
    sensitive = [term for _, term in pseudonymize.load_sensitive(config.expand(cfg["privacy"]["sensitive_file"]))]
    terms = [*participants, *config.read_glossary(cfg), *sensitive]  # first in, last to be cut
    return MlxTranscriber(cfg["transcription"]["model"], list(dict.fromkeys(terms)), languages or cfg["transcription"]["languages"])


def default_diarizer(cfg: dict[str, Any]) -> Diarizer:
    return PyannoteDiarizer(cfg["diarization"]["model"], cfg["diarization"]["device"], get_secret("hf-token"))


def process(session: Session, emit: Emit = null_emit, transcriber: Transcriber | None = None, diarizer: Diarizer | None = None) -> dict[str, Any]:
    cfg = config.load()
    mode = session.mode
    if mode not in ("visio", "presentiel", "hybride"):
        raise ValueError(t("Unknown meeting type: {mode}", mode=mode))
    session.set(status="processing", error=None)
    edit.clear_undo(session)  # snapshots of an earlier transcript must not overwrite the new one
    try:
        transcriber = transcriber or default_transcriber(cfg, session.data.get("participants") or [], session.data.get("languages") or [])
        doc = _process(session, cfg, emit, transcriber, diarizer or default_diarizer(cfg))
    except Exception as exc:
        session.set(status="failed", error=str(exc))
        raise

    if doc["needs_review"]:
        session.set(status="review", warnings=doc["warnings"])
        return {"status": "review", "session": session.id}
    return finalize(session, emit=emit, doc=doc)


def _process(session: Session, cfg: dict[str, Any], emit: Emit, transcriber: Transcriber, diarizer: Diarizer) -> dict[str, Any]:
    mode = session.mode
    headset = bool(session.data.get("headset", True))
    warnings: list[str] = []
    user_name = cfg["general"]["user_name"] or t("Me")
    if dropped := getattr(transcriber, "dropped_terms", None):
        # A count only: warnings are exported, and these terms can be sensitive.
        warnings.append(t("Glossary too long: the last {count} terms weren't used.", count=len(dropped)))

    mic = _read_track(session.mic_path)
    system = None if mode == "presentiel" else _read_track(session.system_path)
    if mic is None and system is None:
        raise FileNotFoundError(t("No audio to process: it was deleted or never recorded."))
    if mic is None:
        warnings.append(t("Mic track missing or empty."))
    if system is None and mode != "presentiel":
        warnings.append(t("System track missing or empty: check the screen recording permission."))

    plan: list[tuple[str, str, float]] = []
    if system is not None:
        plan += [("diarize_system", t("Remote participants diarization"), 2), ("transcribe_system", t("Remote participants transcription"), 5)]
    if mic is not None:
        plan += [("transcribe_mic", t("Mic transcription"), 5)]
        if system is not None and (mode == "hybride" or (mode == "visio" and not headset)):
            plan += [("dedup", t("Removing mic/system duplicates"), 1)]
        if mode != "visio":
            plan += [("diarize_mic", t("Room diarization"), 2)]
    plan += [("merge", t("Merging and naming"), 1)]
    stages = Stages(emit, plan)

    embeddings: dict[str, np.ndarray] = {}
    tracks: list[list[dict[str, Any]]] = []
    removed: list[dedup.Removed] = []
    system_segments: list = []

    # System track: remote participants.
    if system is not None:
        stages.run("diarize_system")
        diarization = _diarize(diarizer, system, _count(session.data.get("remote_count")), "DISTANT", warnings)
        if diarization and diarization.turns:
            regions = regions_from_turns(system, diarization.turns)
            embeddings.update(diarization.embeddings)
        else:
            regions = regions_from_vad(system, au.energy_vad(system))
        report = stages.run("transcribe_system")
        system_segments = transcriber.transcribe_regions(system, regions, report)
        if diarization and diarization.turns:
            tracks.append(merge.build_turns(system_segments, "system", speaker_turns=diarization.turns))
        else:
            tracks.append(merge.build_turns(system_segments, "system", label="DISTANT_1"))

    # Mic track. Diarization must only hear voices from the room, so with echoes
    # possible the order is transcribe, de-duplicate, then diarize what remains.
    fixed: set[str] = set()
    if mic is not None:
        echo_possible = system is not None and (mode == "hybride" or (mode == "visio" and not headset))
        room_count = _count(session.data.get("room_count"))
        room_turns: list[SpeakerTurn] | None = None

        if mode == "presentiel":
            stages.run("diarize_mic")
            diarization = _diarize(diarizer, mic, room_count, "SALLE", warnings)
            if diarization and diarization.turns:
                room_turns = diarization.turns
                embeddings.update(diarization.embeddings)
            regions = regions_from_turns(mic, room_turns) if room_turns else regions_from_vad(mic, au.energy_vad(mic))
            mic_segments = transcriber.transcribe_regions(mic, regions, stages.run("transcribe_mic"))
        else:
            regions = regions_from_vad(mic, au.energy_vad(mic))
            mic_segments = transcriber.transcribe_regions(mic, regions, stages.run("transcribe_mic"))
            cleaned = mic
            if echo_possible:
                stages.run("dedup")
                mic_segments, cleaned, removed = dedup.remove_echoes(mic_segments, mic, system_segments, system)
            if mode == "hybride":
                stages.run("diarize_mic")
                diarization = _diarize(diarizer, cleaned, room_count, "SALLE", warnings)
                if diarization and diarization.turns:
                    room_turns = diarization.turns
                    embeddings.update(diarization.embeddings)

        if mode == "visio":
            tracks.append(merge.build_turns(mic_segments, "mic", label="MOI"))
            fixed.add("MOI")
        elif room_turns:
            tracks.append(merge.build_turns(mic_segments, "mic", speaker_turns=room_turns))
        else:
            tracks.append(merge.build_turns(mic_segments, "mic", label="SALLE_1"))

    stages.run("merge")
    turns = merge.merge_tracks(*tracks)

    expected = session.data.get("participants") or []
    speaker_cfg = cfg["speakers"]
    notes = load_notes(session.notes_path, speaker_cfg["naming_patterns"], expected)

    def track_energy(track: str, at: float) -> float:
        audio = mic if track == "mic" else system
        return au.rms_db(au.slice_seconds(audio, at - 1, at + 1)) if audio is not None else -120.0

    hints, conflicts = naming.resolve_hints(notes, turns, float(speaker_cfg["lookback_seconds"]), fixed, track_energy)

    # Priority: live hints win over voiceprints, which win over the review screen.
    names: dict[str, tuple[str, str]] = {"MOI": (user_name, "user")} if "MOI" in fixed else {}
    voiceprints_error = None
    try:
        for label, (name, _) in enroll.identify_from_store(cfg, embeddings).items():
            names[label] = (name, "voiceprint")
    except Exception as exc:
        voiceprints_error = str(exc)
    if voiceprints_error:
        warnings.append(t("Voiceprints unreadable, automatic identification skipped: {error}", error=voiceprints_error))
    for label, name in hints.items():
        names[label] = (name, "hint")

    speakers = naming.summarize_speakers(turns, names, session.mode)
    languages = sorted({turn["lang"] for turn in turns if turn["lang"]})
    durations = [au.duration(a) for a in (mic, system) if a is not None]

    doc = {
        "version": 1,
        "session_id": session.id,
        "title": session.data["title"],
        "date": session.data["created_at"],
        "duration": round(max(durations), 1),
        "context": session.mode,
        **({"imported": True} if session.data.get("imported") else {}),
        "headset": headset,
        "languages": languages,
        "expected_participants": expected,
        "glossary": config.read_glossary(cfg),
        "speakers": speakers,
        "turns": turns,
        "notes": [
            {"t": round(n.t, 3), "type": n.type, "text": n.text, **({"speaker": n.speaker} if n.speaker else {})}
            for n in notes
        ],
        "conflicts": conflicts,
        "dedup_removed": [vars(r) for r in removed],
        "warnings": warnings,
        "needs_review": bool(conflicts) or any(not s["name"] for s in speakers.values()),
    }
    session.save_transcript(doc)
    return doc


def apply_review(doc: dict[str, Any], names: dict[str, str] | None = None, merges: list[list[str]] | None = None) -> None:
    """Merges are [keep, absorbed] pairs: pyannote split one person into two labels."""
    for keep, absorbed in merges or []:
        if keep == absorbed or keep not in doc["speakers"] or absorbed not in doc["speakers"]:
            continue
        kept, gone = doc["speakers"][keep], doc["speakers"].pop(absorbed)
        if not kept.get("name") and gone.get("name"):
            kept["name"], kept["source"] = gone["name"], gone.get("source")
        for turn in doc["turns"]:
            if turn["label"] == absorbed:
                turn["label"] = keep
        if names and absorbed in names:
            names.setdefault(keep, names[absorbed])
    for label, name in (names or {}).items():
        if label in doc["speakers"] and name.strip():
            doc["speakers"][label]["name"] = name.strip()
            doc["speakers"][label]["source"] = "review"
    doc["conflicts"] = []
    naming.rebuild_speakers(doc)


def finalize(
    session: Session,
    names: dict[str, str] | None = None,
    merges: list[list[str]] | None = None,
    emit: Emit = null_emit,
    doc: dict[str, Any] | None = None,
) -> dict[str, Any]:
    cfg = config.load()
    doc = doc or session.load_transcript()
    if names or merges or doc.get("needs_review"):
        apply_review(doc, names, merges)

    outputs = export.save_outputs(session, doc, cfg)
    emit("progress", stage="cleanup", label=t("Validating and deleting audio"), fraction=0.99)

    keep = bool(cfg["general"]["keep_audio"] or session.data.get("keep_audio"))
    warnings = list(doc.get("warnings", []))
    validation = cleanup.validate(session, doc, Path(outputs["md"]))
    deleted: list[str] = []
    if validation.ok and not keep:
        deleted = cleanup.delete_audio(session)
    elif not validation.ok:
        warnings.append(t("Audio kept: {reason}.", reason=validation.reason))
    session.set(status="done", warnings=warnings, coverage=round(validation.coverage, 3), duration=doc["duration"])
    return {"status": "done", "session": session.id, "outputs": outputs, "audio_deleted": deleted, "coverage": validation.coverage}


def rename_speaker(session: Session, speaker: str, name: str) -> dict[str, Any]:
    """Regenerate the Markdown from the JSON without transcribing again."""
    cfg = config.load()
    doc = session.load_transcript()
    label = next(
        (key for key, entry in doc["speakers"].items() if speaker in (key, entry.get("display"), entry.get("name"))),
        None,
    )
    if label is None:
        raise KeyError(t("Unknown speaker: {speaker}", speaker=speaker))
    edit.snapshot(session, doc)
    doc["speakers"][label]["name"] = name
    doc["speakers"][label]["source"] = "review"
    naming.rebuild_speakers(doc)
    return {"session": session.id, "outputs": export.save_outputs(session, doc, cfg)}


def load_prompt(cfg: dict[str, Any]) -> str:
    """The user's copy if there is one, else the packaged default."""
    custom = config.home() / "prompts" / "synthese.md"
    text = custom.read_text(encoding="utf-8") if custom.exists() else default_prompt()
    languages = {"fr": t("French"), "en": t("English"), "de": t("German"), "nl": t("Dutch"), "es": t("Spanish"), "it": t("Italian"), "pt": t("Portuguese")}
    output_language = cfg["claude"]["output_language"]
    return text.replace("{{output_language}}", languages.get(output_language, output_language))


def default_prompt() -> str:
    name = "prompts/synthese.md" if language() == "fr" else "prompts/synthese.en.md"
    return resources.files("verbalog").joinpath(name).read_text(encoding="utf-8")


def _people(session: Session, doc: dict[str, Any], cfg: dict[str, Any]) -> list[str]:
    names = [s["name"] for s in doc["speakers"].values() if s.get("name")]
    return names + list(doc.get("expected_participants", [])) + [cfg["general"]["user_name"]]


def _text_by_language(doc: dict[str, Any]) -> dict[str, str]:
    """Spoken text per language, for entity detection. Notes are left out: short fragments
    with no known language are where the models misfire most ("Envoyer la grille" as a person).
    Names found in speech are still replaced everywhere, notes included."""
    by_language: dict[str, list[str]] = {}
    for turn in doc["turns"]:
        if turn.get("lang"):
            by_language.setdefault(turn["lang"], []).append(turn["text"])
    return {lang: "\n".join(lines) for lang, lines in by_language.items()}


def prepare(session: Session, use_pseudonyms: bool | None = None, use_ner: bool = True) -> dict[str, Any]:
    """The exact text that would leave the machine, for preview, copy or file transfer."""
    cfg = config.load()
    doc = session.load_transcript()
    md_path = (session.data.get("outputs") or {}).get("md")
    if not md_path or not Path(md_path).exists():
        raise FileNotFoundError(t("The Markdown file is missing: finish the review first."))
    text = Path(md_path).read_text(encoding="utf-8")
    if use_pseudonyms is None:
        use_pseudonyms = bool(cfg["privacy"]["pseudonymize"])
    mapping: dict[str, str] = {}
    if use_pseudonyms:
        text, mapping = pseudonymize.pseudonymize_text(
            text, cfg, _people(session, doc, cfg), session.mapping_path, _text_by_language(doc) if use_ner else None
        )
    prompt = load_prompt(cfg)
    payload = f"{prompt.rstrip()}\n\n<transcription>\n{text}\n</transcription>\n"
    return {
        "session": session.id,
        "pseudonymized": use_pseudonyms,
        "payload": payload,
        "transcript": text,
        "prompt": prompt,
        "aliases": [{"alias": alias, "category": alias.split("_")[0]} for alias in mapping],
    }


def save_summary(session: Session, text: str, use_pseudonyms: bool) -> dict[str, Any]:
    """Store an LLM response, with real names restored if the transcript was pseudonymized."""
    cfg = config.load()
    if use_pseudonyms:
        text = pseudonymize.reidentify_text(text, session.mapping_path)
    md_path, _ = export.output_paths(session, cfg)
    path = md_path.with_name(f"{md_path.stem}_synthese.md")
    path.write_text(text.rstrip() + "\n", encoding="utf-8")
    outputs = dict(session.data.get("outputs") or {}, summary=str(path))
    session.set(outputs=outputs)
    return {"session": session.id, "summary_path": str(path), "text": text}


def summarize(session: Session, emit: Emit = null_emit, use_pseudonyms: bool | None = None) -> dict[str, Any]:
    from .claude_client import summarize_text

    cfg = config.load()
    prepared = prepare(session, use_pseudonyms)
    response = summarize_text(prepared["prompt"], prepared["transcript"], cfg, emit)
    return save_summary(session, response, prepared["pseudonymized"])
