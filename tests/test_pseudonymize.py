import json

import pytest

from verbalog import config
from verbalog.pseudonymize import Pseudonymizer, detect_entities, load_sensitive, pseudonymize_text, reidentify_text, term_regex


TEXT = """**[00:17:48] Sophie Martin :** Acme Europe veut signer, ACME aussi, avec la Société Générale.
Écrivez à jim@acme.com ou au 06 12 34 56 78, ou +33 1 42 68 53 00. Budget de 500 000 € et $2.5M, soit 1,5 million d'euros.
Le marché avance ; la Societe Generale confirme."""


def engine_run(tmp_path, sensitive, people=("Sophie Martin",)):
    home = config.home()
    (home / "sensitive.txt").write_text(sensitive, encoding="utf-8")
    return pseudonymize_text(TEXT, config.load(), people, tmp_path / ".mapping.json")


def test_no_sensitive_term_survives_and_roundtrip_restores(tmp_path):
    out, mapping = engine_run(tmp_path, "CLIENT: Acme\nCLIENT: Acme Europe\nSociété Générale\n")
    for leak in ("Acme", "ACME", "acme", "Société", "Societe", "Sophie", "Martin", "jim@", "06 12", "+33", "500 000", "2.5M", "1,5"):
        assert leak not in out, leak
    assert "CLIENT_A" in out and "CLIENT_B" in out
    assert "TERME_A" in out and "PERSONNE_1" in out
    assert "EMAIL_1" in out and "TEL_1" in out and "MONTANT_1" in out
    assert "marché" in out  # "Marc" isn't a participant, but boundaries must hold anyway
    assert "[00:17:48]" in out  # timestamps are not phone numbers or amounts

    restored = reidentify_text(out, tmp_path / ".mapping.json")
    assert "Acme Europe veut signer" in restored
    assert "Sophie Martin" in restored
    assert "jim@acme.com" not in out and "06 12 34 56 78" in restored
    assert "500 000 €" in restored


def test_names_inside_words_are_untouched():
    engine = Pseudonymizer()
    assert engine.apply_terms("Le marché de Marc", [("PERSONNE", "Marc")]) == "Le marché de PERSONNE_1"


def test_aliases_are_stable_across_runs(tmp_path):
    first, mapping = engine_run(tmp_path, "CLIENT: Acme\n")
    second, again = engine_run(tmp_path, "CLIENT: Zeta\nCLIENT: Acme\n")
    assert first == second
    assert mapping["CLIENT_A"] == "Acme" and again["CLIENT_A"] == "Acme"


def test_reidentify_long_alias_before_its_prefix():
    engine = Pseudonymizer({f"PERSONNE_{i}": f"P{i}" for i in range(1, 12)})
    assert engine.reidentify("PERSONNE_10 et PERSONNE_1") == "P10 et P1"


def test_transcription_misspellings_of_a_term_are_caught():
    engine = Pseudonymizer()
    terms = [("CLIENT", "Enedis"), ("PERSONNE", "Karim")]
    out = engine.apply_near_misses("Chez Enedys avec Karime, et la marche avance enfin.", terms)
    assert out == "Chez CLIENT_A avec PERSONNE_1, et la marche avance enfin."
    assert engine.reidentify(out).startswith("Chez Enedis avec Karim")


def test_mapping_file_is_private(tmp_path):
    engine_run(tmp_path, "Acme\n")
    assert (tmp_path / ".mapping.json").stat().st_mode & 0o077 == 0
    assert json.loads((tmp_path / ".mapping.json").read_text())


def test_sensitive_file_format(tmp_path):
    path = tmp_path / "s.txt"
    path.write_text("# comment\n\nCLIENT: Acme\nProjet Phoenix\n", encoding="utf-8")
    assert load_sensitive(path) == [("CLIENT", "Acme"), ("TERME", "Projet Phoenix")]


def test_entity_filter_skips_markup_and_aliases():
    engine = Pseudonymizer()
    out = engine.apply_entities("NOTE Intervenant 1 PERSONNE_1 Karim", [
        ("PERSONNE", "NOTE"), ("PERSONNE", "Intervenant 1"), ("PERSONNE", "PERSONNE_1"), ("PERSONNE", "Karim"),
    ])
    assert out == "NOTE Intervenant 1 PERSONNE_1 PERSONNE_1"


def test_term_regex_accents_and_spacing():
    import re
    assert re.search(term_regex("L'Oréal  France"), "chez l’oreal france", re.I)


def test_entity_detection_finds_names_and_leaves_ordinary_words_alone():
    pytest.importorskip("fr_core_news_sm")
    pytest.importorskip("en_core_web_sm")
    french = """D'accord, on a validé l'enveloppe en interne, donc on peut partir sur la phase 2.
Enveloppe confirmée en interne
Envoyer la grille tarifaire avant vendredi
Parfait. Je regarde ça avec l'équipe d'ici jeudi et on lance le pilote sur deux sites.
Lancement pilote sur 2 sites
J'ai eu Jean-Pierre Durand hier, il travaille chez Schneider Electric à Grenoble.
Il faut voir avec la société Veolia."""
    english = """Good morning everyone. The rollout timeline depends on the integration.
Thanks. I will send the updated deck tonight, and we can review the budget on Friday.
Bob from Microsoft called Sarah Connor about the contract."""
    names = {name for _, name in detect_entities({"fr": french, "en": english})}
    assert {"Jean-Pierre Durand", "Schneider Electric", "Veolia", "Bob", "Microsoft", "Sarah Connor"} <= names
    for word in ("Enveloppe", "Envoyer", "Parfait", "Lancement", "Thanks", "Good"):
        assert not any(word in name for name in names), (word, names)

    engine = Pseudonymizer()
    out = engine.apply_entities(french + english, sorted(detect_entities({"fr": french, "en": english})))
    assert "l'enveloppe" in out and "Envoyer la grille" in out and "Thanks." in out
    assert "Durand" not in out and "Microsoft" not in out


def test_names_starting_like_an_article_are_kept_whole(monkeypatch):
    # "Anne" isn't "An" + "ne", nor "Laura" "La" + "ura": cut, they failed the name check and
    # stayed in clear text. Real articles still go: "la Poste", "l'Agence", "die Telekom".
    from verbalog.pseudonymize import _DETERMINERS

    for name in ("Anne", "Laura", "Dupont", "Thea", "Lesage", "Elena", "Dieter", "Hetty", "Oscar", "Ilaria", "Umberto", "Asunción"):
        assert _DETERMINERS.sub("", name) == name
    for raw, name in (("la Poste", "Poste"), ("l'Agence", "Agence"), ("The Guardian", "Guardian"),
                      ("die Telekom", "Telekom"), ("het Rijksmuseum", "Rijksmuseum"), ("el Banco Santander", "Banco Santander")):
        assert _DETERMINERS.sub("", raw) == name


def test_entity_detection_in_german_dutch_and_spanish():
    for model in ("de_core_news_sm", "nl_core_news_sm", "es_core_news_sm", "pt_core_news_sm"):
        pytest.importorskip(model)
    texts = {
        "de": "Ich habe gestern mit Anna Schmidt von Siemens telefoniert. Wir senden das Angebot am Freitag.",
        "nl": "Ik heb gisteren met Pieter de Vries van Philips gebeld. We sturen de offerte vrijdag.",
        "es": "Ayer hablé con María García de Telefónica. Enviaremos la oferta el viernes.",
        "pt": "Ontem falei com João Silva da Petrobras. Enviaremos a proposta na sexta-feira.",
    }
    # The small models sometimes take the company into the name ("María García de Telefónica"):
    # the whole span is replaced, which still removes the name.
    found = detect_entities(texts)
    out = Pseudonymizer().apply_entities(" ".join(texts.values()), sorted(found))
    for name in ("Schmidt", "Vries", "García", "Siemens", "Silva"):
        assert name not in out, (name, out)
    for word in ("Ich habe gestern", "Wir senden", "Ayer hablé", "Enviaremos la oferta", "Ontem falei", "Enviaremos a proposta"):
        assert word in out, (word, out)


def test_detected_name_is_case_sensitive_unlike_a_listed_term():
    engine = Pseudonymizer()
    assert engine.apply_entities("Orange confirme, le fruit est orange.", [("ORGANISATION", "Orange")]) == "ORGANISATION_1 confirme, le fruit est orange."
