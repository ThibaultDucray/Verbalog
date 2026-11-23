// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Preview what would leave the device, then either ask Claude directly with the
// person's API key, or copy it into any assistant and paste the answer back.

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../core/llm.dart';
import '../core/session.dart';
import 'common.dart';

Future<void> openMailDraft(String subject, String body) => launchUrl(Uri(
      scheme: 'mailto',
      query: 'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}',
    ));

Future<void> showGenerateSheet(BuildContext context, Meeting m, Deliverable d, String title) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (_) => FractionallySizedBox(heightFactor: 0.9, child: _GenerateSheet(meeting: m, d: d, title: title)),
    );

class _GenerateSheet extends StatefulWidget {
  const _GenerateSheet({required this.meeting, required this.d, required this.title});
  final Meeting meeting;
  final Deliverable d;
  final String title;
  @override
  State<_GenerateSheet> createState() => _GenerateSheetState();
}

class _GenerateSheetState extends State<_GenerateSheet> {
  late bool _pseudo = app.settings.pseudonymize;
  ({String prompt, String transcript, bool pseudonymized, int aliases})? _prepared;
  String? _error;
  bool _busy = false;
  bool _hasKey = false;
  final _paste = TextEditingController();

  @override
  void initState() {
    super.initState();
    _prepare();
    app.settings.apiKey().then((k) => mounted ? setState(() => _hasKey = k.isNotEmpty) : null);
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final p = await app.prepare(widget.meeting, widget.d, pseudonymize: _pseudo);
      if (mounted) setState(() => _prepared = p);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String get _payload => buildPayload(_prepared!.prompt, _prepared!.transcript);

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text = await app.generateWithApi(widget.meeting, widget.d,
          prompt: _prepared!.prompt, transcript: _prepared!.transcript);
      app.saveResult(widget.meeting, widget.d, text, pseudonymized: _prepared!.pseudonymized);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e is LlmException ? t(e.message) : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyAndOpen(String url) async {
    await Clipboard.setData(ClipboardData(text: _payload));
    if (mounted) showSnack(context, t('Copied. Paste it in the assistant, then paste its answer below.'));
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _savePasted() {
    if (_paste.text.trim().isEmpty) return;
    app.saveResult(widget.meeting, widget.d, _paste.text, pseudonymized: _prepared!.pseudonymized);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final p = _prepared;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: ListView(children: [
        Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('Hide names and sensitive terms')),
          subtitle: Text(p == null || !p.pseudonymized
              ? t('Off: the text is sent as it is.')
              : t('{n} terms replaced by aliases such as PERSONNE_1. The real names come back in the answer.', {'n': p.aliases})),
          value: _pseudo,
          onChanged: (v) {
            setState(() {
              _pseudo = v;
              _prepared = null;
            });
            _prepare();
          },
        ),
        if (_error != null)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_error!, style: TextStyle(color: c.error))),
        if (p == null && _error == null) const LinearProgressIndicator(),
        if (p != null) ...[
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(t('Exact text that would be sent')),
            subtitle: Text(t('{n} characters', {'n': _payload.length})),
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(child: SelectableText(_payload, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(t('With Claude, directly'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          if (_hasKey)
            FilledButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(_busy ? t('Writing…') : t('Send to Claude and write it')),
            )
          else
            Text(t('Add your Anthropic API key in Settings to do this in one click.'),
                style: TextStyle(color: c.onSurfaceVariant)),
          const SizedBox(height: 20),
          Text(t('Or with the assistant you prefer'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t('Copy')),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _payload));
                showSnack(context, t('Copied.'));
              },
            ),
            for (final e in chatAssistants.entries)
              OutlinedButton(onPressed: () => _copyAndOpen(e.value), child: Text(t('Copy and open {name}', {'name': e.key}))),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _paste,
            minLines: 4,
            maxLines: 10,
            decoration: InputDecoration(labelText: t("Paste the assistant's answer here")),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(onPressed: _savePasted, child: Text(t('Save the answer'))),
          ),
          const SizedBox(height: 8),
          Text(
            t("Once the text leaves this device, it is under the terms of the service you send it to."),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ]),
    );
  }
}
