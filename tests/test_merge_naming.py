from verbalog import merge, naming
from verbalog.model_types import Segment, SpeakerTurn, Word
from verbalog.notes import Note


def seg(words, lang="fr"):
    """words: (text, start, end)"""
    ws = [Word(" " + t, s, e, 0.9, lang) for t, s, e in words]
    return Segment(ws[0].start, ws[-1].end, " ".join(t for t, _, _ in words), lang, ws)


def turn(label, start, end, track="mic", text="x"):
    return {"label": label, "start": start, "end": end, "track": track, "text": text, "words": [], "lang": "fr"}


def test_words_follow_diarization_and_pause_splits_turns():
    segments = [seg([("bonjour", 0.0, 0.5), ("à", 0.6, 0.7), ("tous", 0.8, 1.2), ("merci", 1.3, 1.6)])]
    speakers = [SpeakerTurn(0.0, 1.25, "A"), SpeakerTurn(1.25, 2.0, "B")]
    turns = merge.build_turns(segments, "mic", speaker_turns=speakers)
    assert [t["label"] for t in turns] == ["A", "B"]
    assert turns[0]["text"] == "bonjour à tous"

    paused = merge.build_turns([seg([("un", 0.0, 0.5)]), seg([("deux", 3.0, 3.5)])], "mic", label="A")
    assert [t["text"] for t in paused] == ["un", "deux"]


def test_word_outside_any_turn_goes_to_nearby_speaker():
    speakers = [SpeakerTurn(0.0, 1.0, "A"), SpeakerTurn(5.0, 6.0, "B")]
    assert merge.speaker_for_word(Word("x", 1.2, 1.4), speakers, "Z") == "A"
    assert merge.speaker_for_word(Word("x", 3.0, 3.1), speakers, "Z") == "Z"


def test_chronological_merge_keeps_overlaps():
    a = [turn("A", 0.0, 5.0)]
    b = [turn("B", 2.0, 3.0, "system")]
    assert [t["label"] for t in merge.merge_tracks(a, b)] == ["A", "B"]


def test_note_goes_after_the_turn_in_progress():
    turns = [turn("A", 1.0, 5.0), turn("B", 6.0, 9.0)]
    assert merge.note_positions(turns, [0.5, 3.0, 5.5, 20.0]) == [-1, 0, 0, 1]


def hint(t, name, announce=False):
    return Note(t, "speaker", speaker=name, announce=announce)


def test_hint_names_active_speaker_or_last_within_lookback():
    turns = [turn("A", 0, 10), turn("B", 20, 30)]
    assert naming.resolve_hints([hint(25, "Jim")], turns, 5, set())[0] == {"B": "Jim"}
    assert naming.resolve_hints([hint(13, "Jim")], turns, 5, set())[0] == {"A": "Jim"}
    names, conflicts = naming.resolve_hints([hint(17, "Jim")], turns, 5, set())
    assert names == {} and conflicts[0]["kind"] == "no_speaker"


def test_announce_targets_next_speaker():
    turns = [turn("A", 0, 10), turn("B", 12, 20)]
    assert naming.resolve_hints([hint(5, "Jim", announce=True)], turns, 5, set())[0] == {"B": "Jim"}


def test_contradictory_names_are_flagged_and_first_kept():
    names, conflicts = naming.resolve_hints([hint(1, "Jim"), hint(2, "Marc")], [turn("A", 0, 10)], 5, set())
    assert names == {"A": "Jim"}
    assert conflicts[0]["kind"] == "contradiction"


def test_both_tracks_active_louder_wins_or_is_ambiguous():
    turns = [turn("SALLE_1", 0, 10, "mic"), turn("DISTANT_1", 0, 10, "system")]
    loud = lambda track, t: -20.0 if track == "system" else -40.0
    assert naming.resolve_hints([hint(5, "Jim")], turns, 5, set(), loud)[0] == {"DISTANT_1": "Jim"}
    close = lambda track, t: -20.0 if track == "system" else -21.0
    names, conflicts = naming.resolve_hints([hint(5, "Jim")], turns, 5, set(), close)
    assert names == {} and conflicts[0]["kind"] == "ambiguous"


def test_user_track_is_never_named_by_a_hint():
    turns = [turn("MOI", 0, 10, "mic"), turn("DISTANT_1", 2, 8, "system")]
    assert naming.resolve_hints([hint(5, "Jim")], turns, 5, {"MOI"})[0] == {"DISTANT_1": "Jim"}


def test_anonymous_display_names_by_context():
    turns = [turn("SALLE_1", 0, 1), turn("DISTANT_1", 1, 2, "system")]
    hybrid = naming.summarize_speakers(turns, {}, "hybride")
    assert hybrid["SALLE_1"]["display"] == "Intervenant salle 1"
    assert hybrid["DISTANT_1"]["display"] == "Intervenant distant 1"
    assert naming.summarize_speakers(turns[:1], {}, "presentiel")["SALLE_1"]["display"] == "Intervenant 1"
