# SPDX-FileCopyrightText: 2026 Thibault Ducray
# SPDX-License-Identifier: GPL-3.0-or-later

import pytest

from verbalog import edit, export
from verbalog.config import load
from verbalog.merge import finish_turn
from verbalog.session import Session


def turn(label, start, *words, track="mic"):
    items = [
        {"w": " " + w, "start": start + i, "end": start + i + 0.9, "conf": 0.8, "lang": "en"}
        for i, w in enumerate(words)
    ]
    built = {"start": items[0]["start"], "end": items[-1]["end"], "label": label, "track": track, "words": items}
    finish_turn(built)
    return built


@pytest.fixture
def session():
    s = Session.create("Meeting", "presentiel")
    speakers = {
        "SALLE_1": {"name": "Alex", "source": "review", "display": "Alex"},
        "SALLE_2": {"name": "Chris", "source": "review", "display": "Chris"},
    }
    doc = {
        "version": 1, "session_id": s.id, "title": "Meeting", "date": s.data["created_at"], "duration": 100.0,
        "context": "presentiel", "headset": True, "languages": ["en"], "expected_participants": [], "glossary": [],
        "speakers": speakers, "notes": [], "conflicts": [], "dedup_removed": [], "warnings": [], "needs_review": False,
        "turns": [turn("SALLE_1", 0, "one", "two", "three", "four"), turn("SALLE_2", 20, "five", "six")],
    }
    export.save_outputs(s, doc, load())
    return s


def doc_of(s):
    return Session.load(s.id).load_transcript()


def summary(s):
    return [(t["label"], t["text"]) for t in doc_of(s)["turns"]]


def op(kind, index=0, start=0.0, **fields):
    return {"op": kind, "turn": index, "start": start, **fields}


def test_reassign_whole_block_updates_exports(session):
    edit.apply(session, op("assign", label="SALLE_2"))
    assert summary(session)[0] == ("SALLE_2", "one two three four")
    assert "SALLE_1" not in doc_of(session)["speakers"]  # nobody left under that label
    md = open(Session.load(session.id).data["outputs"]["md"], encoding="utf-8").read()
    assert "Chris" in md.split("one two three four")[0].splitlines()[-1] and "Alex" not in md


def test_selection_in_the_middle_splits_into_three(session):
    edit.apply(session, op("assign", label="SALLE_2", **{"from": 4, "to": 13}))  # "two three"
    assert summary(session) == [
        ("SALLE_1", "one"), ("SALLE_2", "two three"), ("SALLE_1", "four"), ("SALLE_2", "five six"),
    ]
    middle = doc_of(session)["turns"][1]
    assert (middle["start"], middle["end"]) == (1.0, 2.9)


def test_partial_word_selection_takes_the_whole_word(session):
    edit.apply(session, op("assign", label="SALLE_2", **{"from": 5, "to": 6}))  # inside "two"
    assert summary(session)[1] == ("SALLE_2", "two")


def test_whitespace_selection_is_refused_and_changes_nothing(session):
    before = summary(session)
    with pytest.raises(ValueError):
        edit.apply(session, op("assign", label="SALLE_2", **{"from": 3, "to": 4}))
    assert summary(session) == before


def test_selection_at_the_end_joins_the_next_turn_of_that_speaker(session):
    doc = doc_of(session)
    doc["turns"][1] = turn("SALLE_2", 4, "five", "six")
    session.save_transcript(doc)
    edit.apply(session, op("assign", label="SALLE_2", **{"from": 14, "to": 18}))  # "four"
    assert summary(session) == [("SALLE_1", "one two three"), ("SALLE_2", "four five six")]


def test_new_speaker_gets_a_new_label_and_is_named(session):
    edit.apply(session, op("assign", name="Gaspard", **{"from": 0, "to": 3}))
    doc = doc_of(session)
    assert doc["turns"][0]["label"] == "SALLE_3"
    assert doc["speakers"]["SALLE_3"]["display"] == "Gaspard"


def test_typing_an_existing_name_reuses_that_speaker(session):
    edit.apply(session, op("assign", name=" chris "))
    assert doc_of(session)["turns"][0]["label"] == "SALLE_2"
    assert len(doc_of(session)["speakers"]) == 1


def test_unknown_label_is_refused(session):
    with pytest.raises(KeyError):
        edit.apply(session, op("assign", label="SALLE_9"))


def test_stale_view_is_refused(session):
    with pytest.raises(ValueError):
        edit.apply(session, op("delete", index=0, start=7.0))
    with pytest.raises(ValueError):
        edit.apply(session, op("delete", index=9))


def test_text_edit_keeps_timing_of_unchanged_words(session):
    edit.apply(session, op("set_text", text="one 2 three four extra"))
    words = doc_of(session)["turns"][0]["words"]
    assert [w["w"].strip() for w in words] == ["one", "2", "three", "four", "extra"]
    assert (words[0]["conf"], words[1]["conf"]) == (0.8, 1.0)
    assert (words[1]["start"], words[1]["end"]) == (1.0, 1.9)
    assert words[2]["start"] == 2.0
    assert doc_of(session)["turns"][0]["text"] == "one 2 three four extra"


def test_emptying_a_block_removes_it(session):
    edit.apply(session, op("set_text", text="   "))
    assert summary(session) == [("SALLE_2", "five six")]


def test_deleting_the_only_foreign_block_clears_its_language(session):
    doc = doc_of(session)
    doc["turns"][0]["lang"] = "ja"
    doc["languages"] = ["en", "ja"]
    session.save_transcript(doc)
    edit.apply(session, op("delete"))
    assert doc_of(session)["languages"] == ["en"]


def test_undo_walks_back_edits_and_renames_in_order(session):
    from verbalog import pipeline

    original = summary(session)
    edit.apply(session, op("assign", label="SALLE_2"))
    pipeline.rename_speaker(session, "SALLE_2", "Christopher")
    edit.apply(session, {"op": "undo"})
    assert doc_of(session)["speakers"]["SALLE_2"]["display"] == "Chris"
    edit.apply(session, {"op": "undo"})
    assert summary(session) == original
    with pytest.raises(ValueError):
        edit.apply(session, {"op": "undo"})


def test_undo_history_is_capped(session):
    for number in range(edit.MAX_UNDO + 5):
        edit.apply(session, op("set_text", text=f"version {number}"))
    assert len(edit._undo_files(session)) == edit.MAX_UNDO


def test_processing_again_clears_undo(session):
    from verbalog import pipeline

    edit.apply(session, op("delete"))
    assert edit._undo_files(session)
    with pytest.raises(FileNotFoundError):  # no audio in this fixture: stops right after the reset
        pipeline.process(session, transcriber=object(), diarizer=object())
    assert edit._undo_files(session) == []
