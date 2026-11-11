from verbalog.config import DEFAULTS
from verbalog.notes import match_participant, parse_note

PATTERNS = DEFAULTS["speakers"]["naming_patterns"]
PEOPLE = ["Sophie", "Marc", "Jim", "Karim"]


def parse(raw, expected=PEOPLE):
    return parse_note(1.0, raw, PATTERNS, expected)


def test_typed_prefixes():
    assert parse("! Envoyer la grille").type == "action"
    assert parse("! Envoyer la grille").text == "Envoyer la grille"
    assert parse("# Pilote sur 2 sites").type == "decision"
    assert parse("? Périmètre").type == "question"
    assert parse("~ pas très convaincu").type == "private"
    assert parse("texte libre").type == "note"


def test_empty_line_is_a_bookmark():
    assert parse("   ").type == "bookmark"


def test_shortcut_corrects_typos_against_expected():
    note = parse("@jmi")
    assert (note.type, note.speaker, note.announce) == ("speaker", "Jim", False)


def test_announce_variant():
    assert parse("@Jim+").announce is True


def test_natural_language_fr_and_en():
    for raw in ("ici c'est Jim", "ici c’est Jim", "C'est Jim qui parle", "Jim parle", "this is Jim", "Jim speaking."):
        note = parse(raw)
        assert (note.type, note.speaker) == ("speaker", "Jim"), raw


def test_sentence_matching_a_pattern_stays_a_note_when_name_is_unknown():
    note = parse("le directeur financier parle")
    assert note.type == "note"
    assert note.text == "le directeur financier parle"


def test_without_participant_list_natural_language_is_trusted():
    assert parse("ici c'est Jim", []).speaker == "Jim"


def test_match_handles_accents_and_full_names():
    assert match_participant("helene", ["Hélène Dupont"]) == "Hélène Dupont"
    assert match_participant("zzz", PEOPLE) is None
