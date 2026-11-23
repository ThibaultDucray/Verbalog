// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../engine/models_catalog.dart';
import 'common.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = app.settings;
  late final _name = TextEditingController(text: s.userName);
  late final _glossary = TextEditingController(text: s.glossary.join(', '));
  late final _sensitive = TextEditingController(text: app.sensitiveText);
  final _key = TextEditingController();
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    s.apiKey().then((k) => mounted ? setState(() => _hasKey = k.isNotEmpty) : null);
  }

  @override
  void dispose() {
    _name.dispose();
    _glossary.dispose();
    _sensitive.dispose();
    _key.dispose();
    super.dispose();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Settings'))),
      body: Readable(
        maxWidth: 680,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 40), children: [
          _section(t('You')),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: t('Your name')),
            onChanged: (v) => s.userName = v,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: s.language,
            decoration: InputDecoration(labelText: t('App language')),
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'fr', child: Text('Français')),
            ],
            onChanged: (v) => setState(() {
              s.language = v!;
              appLanguage = v;
              app.refresh();
            }),
          ),
          _section(t('Transcription')),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Quality')),
            subtitle: Text(t(whisperById(s.whisperModel).title)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen()));
              setState(() {});
            },
          ),
          Text(t('Languages ticked by default'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          LanguageChips(selected: s.defaultLanguages, onChanged: (l) => setState(() => s.defaultLanguages = l)),
          const SizedBox(height: 12),
          TextField(
            controller: _glossary,
            decoration: InputDecoration(
              labelText: t('Glossary'),
              helperText: t('Names, products and acronyms, separated by commas. Added to the exports to help the AI.'),
            ),
            onChanged: (v) => s.glossary = v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Process each meeting when it ends')),
            subtitle: Text(t('Turn off to record several meetings in a row and process them later.')),
            value: s.autoProcess,
            onChanged: (v) => setState(() => s.autoProcess = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Keep the audio')),
            subtitle: Text(t('By default the audio is deleted once the transcript is validated.')),
            value: s.keepAudio,
            onChanged: (v) => setState(() => s.keepAudio = v),
          ),
          _section(t('Privacy')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Hide names before sending to an AI')),
            subtitle: Text(t('Participants, emails, phone numbers, amounts and the terms below are replaced by aliases.')),
            value: s.pseudonymize,
            onChanged: (v) => setState(() => s.pseudonymize = v),
          ),
          TextField(
            controller: _sensitive,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: t('Sensitive terms'),
              hintText: 'CLIENT: Acme\nPROJET: Phoenix\nSociété Générale',
              helperText: t('One per line, optionally with a category.'),
            ),
            onChanged: (v) => app.sensitiveText = v,
          ),
          _section(t('Minutes, agenda and email')),
          DropdownButtonFormField<String>(
            initialValue: s.outputLanguage,
            decoration: InputDecoration(labelText: t('Write them in')),
            items: [for (final e in languageNames.entries) DropdownMenuItem(value: e.key, child: Text(t(e.value)))],
            onChanged: (v) => setState(() => s.outputLanguage = v!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _hasKey ? t('Anthropic API key (saved)') : t('Anthropic API key (optional)'),
              hintText: 'sk-ant-…',
              helperText: t('Stored in the system keychain. Without it, copy and paste into any assistant.'),
              suffixIcon: IconButton(
                icon: Icon(_hasKey ? Icons.delete_outline : Icons.save_outlined),
                onPressed: () async {
                  await s.setApiKey(_hasKey ? '' : _key.text);
                  final k = await s.apiKey();
                  _key.clear();
                  setState(() => _hasKey = k.isNotEmpty);
                  if (context.mounted) showSnack(context, k.isEmpty ? t('Key removed.') : t('Key saved.'));
                },
              ),
            ),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse('https://platform.claude.com/settings/keys')),
            child: Text(t('Get an API key')),
          ),
          _section(t('About')),
          Text(
            t('VerbaLog for Windows and Android is free software under the GNU GPL v3 or later. It is a port of Verbalog for macOS by Thibault Ducray, whose transcript logic, notes and prompts it reuses.'),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse('https://github.com/ThibaultDucray/Verbalog')),
            child: const Text('github.com/ThibaultDucray/Verbalog'),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse('https://github.com/StressFull/VerbaLog_PC_Android')),
            child: const Text('github.com/StressFull/VerbaLog_PC_Android'),
          ),
          Text(t('Meetings are stored in {path}', {'path': app.paths.meetings}), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
