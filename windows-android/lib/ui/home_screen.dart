// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import 'common.dart';
import 'meeting_screen.dart';
import 'new_meeting_sheet.dart';
import 'recording_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _newMeeting(BuildContext context) async {
    if (!app.modelsReady) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen()));
      if (!app.modelsReady) return;
    }
    if (!context.mounted) return;
    final m = await showNewMeetingSheet(context);
    if (m == null || !context.mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => RecordingScreen(meeting: m)));
  }

  Future<void> _import(BuildContext context) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: t('Import a recording'),
      type: FileType.custom,
      allowedExtensions: const ['wav'],
    );
    final path = picked.isEmpty ? null : picked.single.path;
    if (path == null || !context.mounted) return;
    try {
      final m = await app.importAudio(path, languages: app.settings.defaultLanguages);
      if (context.mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => MeetingScreen(meeting: m)));
      }
    } catch (e) {
      if (context.mounted) showSnack(context, t("This file can't be read: {error}", {'error': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('VerbaLog'),
          actions: [
            IconButton(
              tooltip: t('Import a recording'),
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: () => _import(context),
            ),
            IconButton(
              tooltip: t('Settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _newMeeting(context),
          icon: const Icon(Icons.mic_none),
          label: Text(t('New meeting')),
        ),
        body: Readable(
          child: ListView(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 12, wide ? 24 : 12, 96),
            children: [
              if (!app.modelsReady) const _SetupBanner(),
              if (app.meetings.isEmpty) const _Empty(),
              for (final m in app.meetings) _MeetingTile(meeting: m),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      color: c.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: Text(app.downloading ? t('Downloading the speech models…') : t('One step left: download the speech models')),
        subtitle: app.downloading
            ? Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(value: app.downloadFraction),
              )
            : Text(t('Everything runs on this device. About {mb} MB, once.',
                {'mb': app.requiredModels.fold<int>(0, (s, m) => s + m.approxMb)})),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen())),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 24),
      child: Column(children: [
        Icon(Icons.graphic_eq, size: 56, color: c.primary),
        const SizedBox(height: 16),
        Text(t('No meetings yet'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          !Platform.isAndroid
              ? t('Record a call or a meeting room. VerbaLog transcribes it on this computer, tells the voices apart, and prepares minutes, an agenda and a follow-up email.')
              : t('Record a meeting. VerbaLog transcribes it on this phone, tells the voices apart, and prepares minutes, an agenda and a follow-up email.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.onSurfaceVariant),
        ),
      ]),
    );
  }
}

class _MeetingTile extends StatelessWidget {
  const _MeetingTile({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final c = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => m.status == 'recording' ? RecordingScreen(meeting: m) : MeetingScreen(meeting: m)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: c.primaryContainer,
              foregroundColor: c.onPrimaryContainer,
              child: Icon(m.imported ? Icons.audio_file_outlined : modeIcon(m.mode)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  [formatDate(m.createdAt), if (m.durationSeconds > 0) formatDuration(m.durationSeconds)].join(' · '),
                  style: TextStyle(color: c.onSurfaceVariant),
                ),
                if (m.status == 'processing' || m.status == 'queued') ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: m.progress),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            Text(statusLabel(m), style: TextStyle(color: statusColor(context, m), fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}
