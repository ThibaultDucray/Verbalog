"""Backend messages and exports, in the interface's language (`general.language` in the config).

English is the source language, as in the app; French lives in `FR` below.
"""

from __future__ import annotations

from typing import Any

from . import config

FR = {
    # Progress
    "Remote participants diarization": "Diarisation des participants distants",
    "Remote participants transcription": "Transcription des participants distants",
    "Mic transcription": "Transcription du micro",
    "Removing mic/system duplicates": "Suppression des doublons micro/système",
    "Room diarization": "Diarisation de la salle",
    "Merging and naming": "Fusion et nommage",
    "Validating and deleting audio": "Validation et suppression de l'audio",
    "Downloading {repo}": "Téléchargement de {repo}",
    # Pipeline
    "Unknown meeting type: {mode}": "Type de réunion inconnu : {mode}",
    "No audio to process: it was deleted or never recorded.": "Aucun audio à traiter : l'audio a été supprimé ou n'a jamais été enregistré.",
    "Mic track missing or empty.": "Piste micro absente ou vide.",
    "System track missing or empty: check the screen recording permission.": "Piste système absente ou vide : vérifiez l'autorisation d'enregistrement de l'écran.",
    "Diarization unavailable, voices on this track aren't separated: {error}": "Diarisation indisponible, les voix ne sont pas séparées sur cette piste : {error}",
    "Voiceprints unreadable, automatic identification skipped: {error}": "Empreintes vocales illisibles, identification automatique ignorée : {error}",
    "Audio kept: {reason}.": "Audio conservé : {reason}.",
    "Unknown speaker: {speaker}": "Locuteur inconnu : {speaker}",
    "The transcript has changed: try again.": "La transcription a changé : réessayez.",
    "This selection contains no words.": "Cette sélection ne contient aucun mot.",
    "Nothing to undo.": "Rien à annuler.",
    "Unknown edit: {op}": "Modification inconnue : {op}",
    "The Markdown file is missing: finish the review first.": "Le fichier Markdown est absent : terminez d'abord la vérification.",
    "Me": "Moi",
    "French": "français",
    "English": "anglais",
    # Audio validation
    "the transcript file is missing or empty": "le fichier de transcription est absent ou vide",
    "no speech transcribed although the audio isn't silent": "aucune parole transcrite alors que l'audio n'est pas silencieux",
    "the transcript only covers {value:.0%} of the audible audio (minimum {minimum:.0%})": "la transcription ne couvre que {value:.0%} de l'audio audible (minimum {minimum:.0%})",
    # Sessions and audio files
    "Session not found: {ref}": "Session introuvable : {ref}",
    "Transcript missing: run processing first.": "Transcription absente : lancez d'abord le traitement.",
    "Invalid WAV file: {path}": "Fichier WAV invalide : {path}",
    "Unexpected format ({channels} channels, {rate} Hz, {bits} bits): {path}": "Format inattendu ({channels} canaux, {rate} Hz, {bits} bits) : {path}",
    # Models
    "pyannote.audio isn't installed": "pyannote.audio n'est pas installé",
    "model {model} not available locally ({error})": "modèle {model} indisponible localement ({error})",
    "model {model} not available locally": "modèle {model} indisponible localement",
    "Hugging Face token missing": "jeton Hugging Face manquant",
    "access denied: accept the model's licence on huggingface.co": "accès refusé : acceptez la licence du modèle sur huggingface.co",
    "{error} (have you accepted the model's licence on huggingface.co?)": "{error} (avez-vous accepté la licence du modèle sur huggingface.co ?)",
    "Glossary too long: the last {count} terms weren't used.": "Glossaire trop long : les {count} derniers termes n'ont pas été utilisés.",
    "Live transcript falling behind: a passage was skipped.": "Transcription en direct en retard : un passage a été ignoré.",
    # Voiceprints
    "--name and --wav are required to record a voiceprint.": "--name et --wav sont requis pour enregistrer une empreinte.",
    "The person's explicit consent is required (--consent).": "Le consentement explicite de la personne est requis (--consent).",
    "The person's explicit consent is required to record their voiceprint.": "Le consentement explicite de la personne est requis pour enregistrer son empreinte.",
    "This diarization model didn't provide a voiceprint, or the recording is too short.": "Ce modèle de diarisation n'a pas fourni d'empreinte, ou l'enregistrement est trop court.",
    # Claude API
    "No Anthropic API key: add one in Settings.": "Aucune clé API Anthropic : ajoutez-la dans les réglages.",
    "Anthropic API key rejected.": "Clé API Anthropic refusée.",
    "Unknown or unauthorized model: {model}": "Modèle inconnu ou non autorisé : {model}",
    "API rate limit reached: try again shortly.": "Limite de débit de l'API atteinte : réessayez dans un instant.",
    "Anthropic API error ({status}): {message}": "Erreur de l'API Anthropic ({status}) : {message}",
    "Can't connect to the Anthropic API.": "Connexion à l'API Anthropic impossible.",
    "The model declined to process this transcript.": "Le modèle a refusé de traiter cette transcription.",
    "Empty response from the model.": "Réponse vide du modèle.",
    "The summary reached the maximum length and may be cut off.": "La synthèse a atteint la longueur maximale et peut être tronquée.",
    # Exports and speaker names
    "BOOKMARK": "SIGNET",
    "Organizer notes (summary)": "Notes de l'organisateur (synthèse)",
    "Transcript": "Transcription",
    "organizer": "organisateur",
    "unidentified": "non identifié",
    "room": "salle",
    "remote": "distant",
    "Speaker {n}": "Intervenant {n}",
    "Room speaker {n}": "Intervenant salle {n}",
    "Remote speaker {n}": "Intervenant distant {n}",
}


def language() -> str:
    return "fr" if config.load()["general"].get("language") == "fr" else "en"


def t(message: str, **values: Any) -> str:
    template = FR.get(message, message) if language() == "fr" else message
    return template.format(**values) if values else template
