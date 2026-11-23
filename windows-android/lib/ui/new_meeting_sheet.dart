// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import 'common.dart';

Future<Meeting?> showNewMeetingSheet(BuildContext context) => showModalBottomSheet<Meeting>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const _NewMeetingSheet(),
    );

List<String> splitNames(String text) =>
    text.split(RegExp(r'[,;\n]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

class _NewMeetingSheet extends StatefulWidget {
  const _NewMeetingSheet();
  @override
  State<_NewMeetingSheet> createState() => _NewMeetingSheetState();
}

class _NewMeetingSheetState extends State<_NewMeetingSheet> {
  final _title = TextEditingController();
  final _people = TextEditingController();
  late String _mode = Platform.isWindows ? app.settings.lastMode : 'presentiel';
  late List<String> _languages = app.settings.defaultLanguages;
  int? _count;

  @override
  void dispose() {
    _title.dispose();
    _people.dispose();
    super.dispose();
  }

  void _start() {
    final title = _title.text.trim().isEmpty ? t('Meeting of {date}', {'date': formatDate(DateTime.now().toIso8601String())}) : _title.text.trim();
    final m = app.newMeeting(
      title: title,
      mode: _mode,
      languages: _languages,
      participants: splitNames(_people.text),
      roomCount: _mode == 'visio' ? null : _count,
      remoteCount: _mode == 'visio' ? _count : null,
    );
    Navigator.pop(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final call = Platform.isWindows;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, bottom: MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t('New meeting'), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            autofocus: true,
            decoration: InputDecoration(labelText: t('Title'), hintText: t('Weekly review')),
            onSubmitted: (_) => _start(),
          ),
          const SizedBox(height: 16),
          if (call) ...[
            SegmentedButton<String>(
              segments: [
                for (final mode in ['visio', 'presentiel', 'hybride'])
                  ButtonSegment(value: mode, label: Text(modeLabel(mode)), icon: Icon(modeIcon(mode))),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 6),
            Text(
              switch (_mode) {
                'visio' => t("Records your microphone and the PC's sound (Teams, Zoom, Meet…). Use a headset if you can."),
                'hybride' => t("Records the room and the call's sound."),
                _ => t('Records the room through the microphone.'),
              },
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
          ],
          Text(t('Languages spoken'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          LanguageChips(selected: _languages, onChanged: (l) => setState(() => _languages = l)),
          const SizedBox(height: 16),
          TextField(
            controller: _people,
            decoration: InputDecoration(
              labelText: t('Participants (optional)'),
              hintText: t('Sophie Martin, Jim, Karim'),
              helperText: t('Helps name the speakers and hide their names before anything is sent to an AI.'),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int?>(
            initialValue: _count,
            decoration: InputDecoration(labelText: _mode == 'visio' ? t('Number of remote participants') : t('Number of people speaking')),
            items: [
              DropdownMenuItem(value: null, child: Text(t('Detect automatically'))),
              for (var i = 1; i <= 10; i++) DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: (v) => setState(() => _count = v),
          ),
          const SizedBox(height: 20),
          Text(t("Let participants know they're being recorded."), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _start, icon: const Icon(Icons.fiber_manual_record), label: Text(t('Start recording'))),
        ]),
      ),
    );
  }
}
