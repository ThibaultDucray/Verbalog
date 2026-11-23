// SPDX-FileCopyrightText: 2026 Thibault Ducray (Verbalog), 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Interface and export strings. English is the source language; French follows Verbalog's.

import 'i18n_ui_fr.dart';

String appLanguage = 'en';

const Map<String, String> _fr = {
  // Pipeline
  'Remote participants diarization': 'Diarisation des participants distants',
  'Remote participants transcription': 'Transcription des participants distants',
  'Mic transcription': 'Transcription du micro',
  'Room diarization': 'Diarisation de la salle',
  'Merging and naming': 'Fusion et nommage',
  'Loading models': 'Chargement des modèles',
  'No audio to process: it was deleted or never recorded.':
      "Aucun audio à traiter : l'audio a été supprimé ou n'a jamais été enregistré.",
  'Mic track missing or empty.': 'Piste micro absente ou vide.',
  'Your microphone recorded almost no speech. If you spoke during this meeting, your voice is missing from the transcript: the audio is kept so you can check.':
      "Votre micro n'a presque rien enregistré. Si vous avez parlé pendant cette réunion, votre voix manque dans la transcription : l'audio est conservé pour que vous puissiez vérifier.",
  'Call audio track missing or empty.': 'Piste audio de l’appel absente ou vide.',
  "Diarization unavailable, voices on this track aren't separated: {error}":
      'Diarisation indisponible, les voix ne sont pas séparées sur cette piste : {error}',
  'Me': 'Moi',
  'French': 'français',
  'English': 'anglais',
  'German': 'allemand',
  'Dutch': 'néerlandais',
  'Spanish': 'espagnol',
  'Italian': 'italien',
  'Portuguese': 'portugais',
  // Exports
  'NOTE': 'NOTE',
  'ACTION': 'ACTION',
  'DECISION': 'DECISION',
  'QUESTION': 'QUESTION',
  'BOOKMARK': 'SIGNET',
  'Organizer notes (summary)': "Notes de l'organisateur (synthèse)",
  'Transcript': 'Transcription',
  'organizer': 'organisateur',
  'unidentified': 'non identifié',
  'room': 'salle',
  'remote': 'distant',
  'Speaker {n}': 'Intervenant {n}',
  'Room speaker {n}': 'Intervenant salle {n}',
  'Remote speaker {n}': 'Intervenant distant {n}',
};

/// Translate `message` and fill `{name}` placeholders.
String t(String message, [Map<String, Object?> values = const {}]) {
  var out = appLanguage == 'fr' ? (_fr[message] ?? frUi[message] ?? message) : message;
  values.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
  return out;
}

const languageNames = {
  'fr': 'French',
  'en': 'English',
  'de': 'German',
  'nl': 'Dutch',
  'es': 'Spanish',
  'it': 'Italian',
  'pt': 'Portuguese',
};
