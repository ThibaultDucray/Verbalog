// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../engine/models_catalog.dart';
import 'common.dart';

/// First run: your name, how accurate the transcription should be, and the download.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _name = TextEditingController(text: app.settings.userName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ready = app.modelsReady;
        return Scaffold(
          appBar: AppBar(title: Text(t('Set up VerbaLog'))),
          body: Readable(
            maxWidth: 640,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text(t('Your name'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                decoration: InputDecoration(hintText: t('Shown as the organizer in transcripts')),
                onChanged: (v) => app.settings.userName = v,
              ),
              const SizedBox(height: 28),
              Text(t('Transcription quality'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(t('Transcription and speaker separation run entirely on this device. Nothing is sent anywhere.'),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              RadioGroup<String>(
                groupValue: app.settings.whisperModel,
                onChanged: (v) => setState(() => app.settings.whisperModel = v!),
                child: Column(children: [
                  for (final m in whisperModels)
                    RadioListTile<String>(
                      value: m.id,
                      title: Text(t(m.title)),
                      subtitle: Text(t(m.description)),
                      secondary: app.downloader.isInstalled(m) ? const Icon(Icons.check_circle_outline) : null,
                    ),
                ]),
              ),
              const SizedBox(height: 20),
              if (app.downloading) ...[
                Text(app.downloadLabel == null ? t('Starting…') : t(app.downloadLabel!)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: app.downloadFraction),
                const SizedBox(height: 4),
                Text('${((app.downloadFraction ?? 0) * 100).toStringAsFixed(0)} %'),
              ] else if (ready)
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text(t('All set')),
                  onPressed: () {
                    app.settings.setupDone = true;
                    Navigator.pop(context);
                  },
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(t('Download models (about {mb} MB)', {
                    'mb': app.requiredModels.where((s) => !app.downloader.isInstalled(s)).fold<int>(0, (s, m) => s + m.approxMb)
                  })),
                  onPressed: app.downloadModels,
                ),
              if (app.downloadError != null) ...[
                const SizedBox(height: 12),
                Text(t('Download failed: {error}', {'error': app.downloadError}),
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 28),
              Text(
                t('Models come from the open-source sherpa-onnx project (Whisper by OpenAI, pyannote, 3D-Speaker). No account is needed.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        );
      },
    );
  }
}
