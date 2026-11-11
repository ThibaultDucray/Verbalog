"""Replace sensitive terms before any text leaves the machine.

The alias table lives next to the session and is never sent. It's reused between
runs, so that CLIENT_A stays the same client across previews and re-sends.
"""

from __future__ import annotations

import difflib
import json
import re
from pathlib import Path
from typing import Any, Iterable

from . import config

_ACCENTS = {
    "a": "aàâäáã", "c": "cç", "e": "eéèêë", "i": "iîïíì", "n": "nñ", "o": "oôöóòõ", "u": "uùûüú", "y": "yÿ",
}
_FOLD = {ch: base for base, chars in _ACCENTS.items() for ch in chars}
LETTERED = {"CLIENT", "PROJET", "TERME"}
NEAR_MISS_MIN_LENGTH = 5
NEAR_MISS_RATIO = 0.8

EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
PHONE = re.compile(r"(?<![\w:])(?:\+\d{1,3}[ .\- ]?(?:\(0\)[ .\- ]?)?\d(?:[ .\- ]?\d){6,12}|0\d(?:[ .\- ]?\d{2}){4})(?![\w:])")
_NUM = r"\d(?:[\d   .,]*\d)?"
AMOUNT = re.compile(
    rf"(?:[$€£] ?{_NUM}(?: ?(?:k|K|M|Md|millions?|milliards?)\b)?)"
    rf"|(?:(?<![\w:]){_NUM} ?(?:(?:k|K|M|Md|millions?(?: d[e'] ?)?|milliards?(?: d[e'] ?)?) ?)?(?:€|\$|£|(?:euros?|dollars?|EUR|USD|GBP)\b))"
)
_ALIAS_SHAPE = re.compile(r"^[A-Z]+_[A-Z0-9]+$")
_NER_STOPWORDS = {"note", "action", "decision", "décision", "question", "signet", "bookmark", "transcription", "transcript", "intervenant", "speaker", "room", "remote"}


def term_regex(term: str) -> str:
    """Case- and accent-insensitive whole-term pattern: "Société Générale" also catches "SOCIETE GENERALE"."""
    parts = []
    for ch in term.strip():
        low = ch.casefold()
        base = _FOLD.get(low)
        if ch.isspace():
            parts.append(r"\s+")
        elif ch in "'’":
            parts.append("['’]")
        elif base:
            parts.append(f"[{_ACCENTS[base]}]")
        else:
            parts.append(re.escape(ch))
    # Collapse the repeated \s+ of terms with double spaces.
    return r"(?<!\w)" + "".join(parts).replace(r"\s+\s+", r"\s+") + r"(?!\w)"


def _folded(term: str) -> str:
    return "".join(_FOLD.get(c, c) for c in term.casefold()).strip()


def load_sensitive(path: Path) -> list[tuple[str, str]]:
    """Lines are `Term` or `CATEGORY: Term`, e.g. `CLIENT: Acme`, `PERSONNE: Jim`."""
    if not path.exists():
        return []
    terms = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        category, sep, term = line.partition(":")
        if sep and re.fullmatch(r"[A-Za-zÀ-ÿ_]+", category.strip()) and term.strip():
            terms.append((category.strip().upper(), term.strip()))
        else:
            terms.append(("TERME", line))
    return terms


class Pseudonymizer:
    def __init__(self, mapping: dict[str, str] | None = None):
        self.mapping: dict[str, str] = dict(mapping or {})
        self._by_term = {_folded(v): k for k, v in self.mapping.items()}

    def _alias(self, category: str, original: str) -> str:
        key = _folded(original)
        if key in self._by_term:
            return self._by_term[key]
        count = sum(1 for alias in self.mapping if alias.startswith(category + "_"))
        if category in LETTERED:
            n, suffix = count, ""
            while True:
                suffix = chr(ord("A") + n % 26) + suffix
                n = n // 26 - 1
                if n < 0:
                    break
        else:
            suffix = str(count + 1)
        alias = f"{category}_{suffix}"
        self.mapping[alias] = original
        self._by_term[key] = alias
        return alias

    def apply_terms(self, text: str, terms: Iterable[tuple[str, str]]) -> str:
        # Longest first, so "Acme Europe" isn't half-replaced by the rule for "Acme".
        for category, term in sorted(set(terms), key=lambda item: len(item[1]), reverse=True):
            if term.strip():
                text = re.sub(term_regex(term), lambda m, c=category, t=term: self._alias(c, t), text, flags=re.IGNORECASE)
        return text

    def apply_near_misses(self, text: str, terms: Iterable[tuple[str, str]]) -> str:
        """Whisper misspells proper nouns, and a misspelled client name is still that client.
        Over-replacing a rare word costs little; the preview shows it, and leaking costs more."""
        singles = [(c, t.strip(), _folded(t)) for c, t in set(terms) if len(t.strip()) >= NEAR_MISS_MIN_LENGTH and " " not in t.strip()]
        if not singles:
            return text
        replacements: dict[str, str] = {}
        for word in set(re.findall(r"(?<![\w'’])[^\W\d_]{%d,}(?![\w])" % NEAR_MISS_MIN_LENGTH, text)):
            folded = _folded(word)
            best = max(singles, key=lambda item: difflib.SequenceMatcher(None, folded, item[2]).ratio())
            ratio = difflib.SequenceMatcher(None, folded, best[2]).ratio()
            if ratio >= NEAR_MISS_RATIO and folded[0] == best[2][0]:
                replacements[word] = self._alias(best[0], best[1])
        for word, alias in replacements.items():
            text = re.sub(rf"(?<!\w){re.escape(word)}(?!\w)", alias, text)
        return text

    def apply_patterns(self, text: str) -> str:
        for category, pattern in (("EMAIL", EMAIL), ("TEL", PHONE), ("MONTANT", AMOUNT)):
            text = pattern.sub(lambda m, c=category: self._alias(c, m.group(0).strip()), text)
        return text

    def apply_entities(self, text: str, entities: Iterable[tuple[str, str]]) -> str:
        # Unlike a listed term, a detected name is only trusted in the case it was found in.
        kept = [
            (category, name) for category, name in entities
            if len(name) >= 3 and "\n" not in name and not re.search(r"[*\[\]_:>#]", name)
            and not _ALIAS_SHAPE.match(name) and name.split()[0].casefold() not in _NER_STOPWORDS
        ]
        for category, name in sorted(set(kept), key=lambda item: len(item[1]), reverse=True):
            text = re.sub(rf"(?<!\w){re.escape(name)}(?!\w)", lambda m, c=category, t=name: self._alias(c, t), text)
        return text

    def reidentify(self, text: str) -> str:
        if not self.mapping:
            return text
        # The alternation tries longest first, so PERSONNE_10 can't match as PERSONNE_1.
        pattern = "|".join(re.escape(a) for a in sorted(self.mapping, key=len, reverse=True))
        return re.sub(rf"(?<!\w)(?:{pattern})(?!\w)", lambda m: self.mapping[m.group(0)], text)


SPACY_MODELS = {
    "fr": "fr_core_news_sm",
    "en": "en_core_web_sm",
    "de": "de_core_news_sm",
    "nl": "nl_core_news_sm",
    "es": "es_core_news_sm",
    "pt": "pt_core_news_sm",
    # No Italian: it_core_news_sm is CC BY-NC-SA, and Verbalog is used in work meetings.
}
# Articles the models sometimes include in a name: "la Commission", "die Telekom", "het Rijk",
# "l'Agence". A whole word followed by a space, or an elision: never the start of "Anne" or "Laura".
_DETERMINERS = re.compile(
    r"^(?:(?:the|an?|les?|la|une?|des?|du"  # English, French
    r"|der|die|das|dem|den|ein|eine[mnrs]?"  # German
    r"|het|een"  # Dutch ("de" above)
    r"|el|los|las|unos?|unas?|del|al"  # Spanish
    r"|il|lo|gli|uno"  # Italian (others above)
    r"|o|os|a|as|um|uma|uns|umas|do|da|dos|das)\s+"  # Portuguese
    r"|[ld]['’]\s*)",
    re.IGNORECASE,
)


def detect_entities(text_by_language: dict[str, str]) -> list[tuple[str, str]]:
    """Named entities from the local spaCy models; empty if they aren't installed.

    Each model only reads text in its own language. Run on the other one it tags
    ordinary words as names ("Envoyer la grille" as a person), and the replacements
    would make the transcript unusable. The transcript knows each turn's language.
    """
    try:
        import spacy
    except ImportError:
        return []
    found: set[tuple[str, str]] = set()
    everything = " ".join(text_by_language.values())
    lowercase_words = set(re.findall(r"(?<![^\W\d_])[^\W\d_A-ZÀ-Þ][^\W\d_]*", everything))
    for language, text in text_by_language.items():
        model = SPACY_MODELS.get(language)
        if not model or not text.strip():
            continue
        try:
            nlp = spacy.load(model, disable=["lemmatizer"])
        except OSError:
            continue
        nlp.max_length = max(nlp.max_length, len(text) + 1)
        for ent in nlp(text).ents:
            if ent.label_ not in ("PER", "PERSON", "ORG"):
                continue
            name = _DETERMINERS.sub("", ent.text.strip())
            if not name or not name[0].isupper() or not any(t.pos_ == "PROPN" for t in ent):
                continue
            # Capitalized only by its position in the sentence: "Enveloppe" next to "l'enveloppe".
            if " " not in name and name.casefold() in lowercase_words:
                continue
            found.add(("PERSONNE" if ent.label_ in ("PER", "PERSON") else "ORGANISATION", name))
    return sorted(found)


def pseudonymize_text(
    text: str,
    cfg: dict[str, Any],
    participants: Iterable[str],
    mapping_path: Path,
    text_by_language: dict[str, str] | None = None,
) -> tuple[str, dict[str, str]]:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8")) if mapping_path.exists() else {}
    engine = Pseudonymizer(mapping)
    terms = load_sensitive(config.expand(cfg["privacy"]["sensitive_file"]))

    people: list[tuple[str, str]] = []
    for person in participants:
        person = person.strip()
        if not person or person.startswith(("Intervenant", "Speaker", "Room speaker", "Remote speaker")):
            continue
        people.append(("PERSONNE", person))
        # Full name first, then its parts, so "Sophie" alone is caught too.
        people.extend(("PERSONNE", part) for part in person.split() if len(part) >= 3)

    result = engine.apply_terms(text, terms + people)
    result = engine.apply_near_misses(result, terms + people)
    result = engine.apply_patterns(result)
    if text_by_language:
        result = engine.apply_entities(result, detect_entities(text_by_language))
    mapping_path.write_text(json.dumps(engine.mapping, ensure_ascii=False, indent=2), encoding="utf-8")
    mapping_path.chmod(0o600)
    return result, engine.mapping


def reidentify_text(text: str, mapping_path: Path) -> str:
    if not mapping_path.exists():
        return text
    return Pseudonymizer(json.loads(mapping_path.read_text(encoding="utf-8"))).reidentify(text)
