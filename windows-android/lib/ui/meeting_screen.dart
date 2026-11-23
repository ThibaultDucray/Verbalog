// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_state.dart';
import '../core/i18n.dart';
import '../core/llm.dart';
import '../core/merge.dart';
import '../core/models.dart';
import '../core/notes.dart';
import '../core/session.dart';
import '../core/text.dart';
import 'common.dart';
import 'generate_sheet.dart';

class MeetingScreen extends StatefulWidget {
  const MeetingScreen({super.key, required this.meeting});
  final Meeting meeting;
  @override
  State<MeetingScreen> createState() => MeetingScreenState();
}

class MeetingScreenState extends State<MeetingScreen> {
  Transcript? _doc;
  String? _docStatus;
  AudioPlayer? _player; // created on first use: audio back-ends are slow to start
  Timer? _stopTimer;

  Meeting get m => widget.meeting;

  @override
  void dispose() {
    _stopTimer?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Transcript? get doc {
    // Reload when processing finishes or the review is validated.
    if (_docStatus != m.status) {
      _doc = m.loadTranscript();
      _docStatus = m.status;
    }
    return _doc;
  }

  Future<void> play(String track, double start, double end) async {
    final path = track == 'system' ? m.systemPath : m.micPath;
    if (!File(path).existsSync()) return;
    _stopTimer?.cancel();
    final player = _player ??= AudioPlayer();
    await player.stop();
    await player.play(DeviceFileSource(path), position: Duration(milliseconds: (start * 1000).round()));
    _stopTimer = Timer(Duration(milliseconds: ((end - start).clamp(1, 12) * 1000).round()), player.stop);
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: m.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Rename')),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(t('Save'))),
        ],
      ),
    );
    if (title != null && title.trim().isNotEmpty) app.renameMeeting(m, title.trim());
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Delete this meeting?')),
        content: Text(t('Its audio, transcript, notes and summaries are deleted from this device.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('Delete'))),
        ],
      ),
    );
    if (ok == true && mounted) {
      app.deleteMeeting(m);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final d = doc;
        return DefaultTabController(
          length: 3,
          initialIndex: m.status == 'review' ? 1 : 0,
          child: Scaffold(
            appBar: AppBar(
              title: Text(m.title),
              actions: [
                IconButton(tooltip: t('Rename'), icon: const Icon(Icons.edit_outlined), onPressed: _rename),
                if (File(m.markdownPath).existsSync())
                  IconButton(
                    tooltip: t('Share the transcript'),
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(m.markdownPath)], title: m.title)),
                  ),
                IconButton(tooltip: t('Delete'), icon: const Icon(Icons.delete_outline), onPressed: _delete),
              ],
              bottom: TabBar(tabs: [
                Tab(text: t('Transcript')),
                Tab(text: t('Speakers')),
                Tab(text: t('Minutes & follow-up')),
              ]),
            ),
            body: Column(children: [
              _StatusBar(meeting: m),
              Expanded(
                child: TabBarView(children: [
                  d == null ? const _NoTranscript() : _TranscriptTab(doc: d, state: this),
                  d == null ? const _NoTranscript() : _SpeakersTab(doc: d, state: this),
                  d == null ? const _NoTranscript() : _FollowUpTab(meeting: m),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.meeting});
  final Meeting meeting;
  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final c = Theme.of(context).colorScheme;
    Widget bar(IconData icon, String text, {Widget? action, Color? color, Widget? below}) => Material(
          color: color ?? c.surfaceContainerHigh,
          child: Readable(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Column(children: [
                Row(children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(text)),
                  ?action,
                ]),
                ?below,
              ]),
            ),
          ),
        );

    switch (m.status) {
      case 'queued':
      case 'processing':
        return bar(Icons.hourglass_top, statusLabel(m),
            below: Padding(padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: m.progress)));
      case 'recorded':
        return bar(Icons.graphic_eq, app.modelsReady ? t('Recorded. Transcribe it when you are ready.') : t('Download the speech models first, from the home screen.'),
            action: app.modelsReady ? FilledButton(onPressed: () => app.enqueue(m), child: Text(t('Transcribe'))) : null);
      case 'failed':
        return bar(Icons.error_outline, t('Processing failed: {error}', {'error': m.error ?? ''}),
            color: c.errorContainer,
            action: m.hasAudio ? TextButton(onPressed: () => app.enqueue(m), child: Text(t('Try again'))) : null);
      case 'review':
        return bar(Icons.record_voice_over_outlined,
            t('Some voices have no name yet. Name them in Speakers, then validate.'),
            color: c.tertiaryContainer);
      default:
        if (m.warnings.isEmpty) return const SizedBox.shrink();
        return bar(Icons.info_outline, m.warnings.join('\n'));
    }
  }
}

class _NoTranscript extends StatelessWidget {
  const _NoTranscript();
  @override
  Widget build(BuildContext context) => Center(
      child: Text(t('No transcript yet.'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)));
}

Color speakerColor(BuildContext context, String label, Map<String, Speaker> speakers) {
  const palette = [Color(0xFF3D5AFE), Color(0xFF00897B), Color(0xFFD81B60), Color(0xFFF4511E), Color(0xFF8E24AA), Color(0xFF6D4C41), Color(0xFF039BE5), Color(0xFF7CB342)];
  final i = speakers.keys.toList().indexOf(label);
  return palette[(i < 0 ? 0 : i) % palette.length];
}

class _TranscriptTab extends StatelessWidget {
  const _TranscriptTab({required this.doc, required this.state});
  final Transcript doc;
  final MeetingScreenState state;

  @override
  Widget build(BuildContext context) {
    final notes = doc.notes.where((n) => n.type != 'speaker').toList();
    final positions = notePositions(doc.turns, notes.map((n) => n.t).toList());
    final after = <int, List<Note>>{};
    for (var i = 0; i < notes.length; i++) {
      after.putIfAbsent(positions[i], () => []).add(notes[i]);
    }
    final c = Theme.of(context).colorScheme;
    Widget noteChip(Note n) => Padding(
          padding: const EdgeInsets.only(left: 12, bottom: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: n.type == 'private' ? c.surfaceContainerHighest : c.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${t(n.type == 'private' ? 'Private' : exportLabels[n.type] ?? 'NOTE')} [${hms(n.t)}]  ${n.text}',
              style: TextStyle(color: c.onSecondaryContainer),
            ),
          ),
        );
    final items = <Widget>[for (final n in after[-1] ?? const <Note>[]) noteChip(n)];
    for (var i = 0; i < doc.turns.length; i++) {
      final turn = doc.turns[i];
      final speaker = doc.speakers[turn.label];
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            InkWell(
              onTap: () => renameSpeakerDialog(context, state, doc, turn.label),
              child: Text(speaker?.display ?? turn.label,
                  style: TextStyle(fontWeight: FontWeight.w700, color: speakerColor(context, turn.label, doc.speakers))),
            ),
            const SizedBox(width: 8),
            Text(hms(turn.start), style: Theme.of(context).textTheme.bodySmall),
            if (File(turn.track == 'system' ? state.m.systemPath : state.m.micPath).existsSync())
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: const Icon(Icons.play_arrow_outlined),
                onPressed: () => state.play(turn.track, turn.start, turn.end),
              ),
          ]),
          const SizedBox(height: 2),
          SelectableText(turn.text, style: Theme.of(context).textTheme.bodyLarge),
        ]),
      ));
      for (final n in after[i] ?? const <Note>[]) {
        items.add(noteChip(n));
      }
    }
    return Readable(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 40), children: [
        Row(children: [
          Expanded(
            child: Text('${formatDate(doc.date)} · ${formatDuration(doc.duration)} · ${modeLabel(doc.context)}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(t('Copy')),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: File(state.m.markdownPath).readAsStringSync()));
              showSnack(context, t('Transcript copied as Markdown.'));
            },
          ),
        ]),
        const SizedBox(height: 8),
        if (doc.turns.isEmpty) Text(t('No speech was recognized in this recording.')),
        ...items,
      ]),
    );
  }
}

Future<void> renameSpeakerDialog(BuildContext context, MeetingScreenState state, Transcript doc, String label) async {
  final s = doc.speakers[label];
  if (s == null || label == 'MOI') return;
  final controller = TextEditingController(text: s.name ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('Who is {speaker}?', {'speaker': s.display})),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        if (doc.expectedParticipants.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 6, children: [
            for (final p in doc.expectedParticipants) ActionChip(label: Text(p), onPressed: () => Navigator.pop(ctx, p)),
          ]),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(t('Save'))),
      ],
    ),
  );
  if (name != null && name.trim().isNotEmpty) app.renameSpeaker(state.m, doc, label, name);
}

class _SpeakersTab extends StatefulWidget {
  const _SpeakersTab({required this.doc, required this.state});
  final Transcript doc;
  final MeetingScreenState state;
  @override
  State<_SpeakersTab> createState() => _SpeakersTabState();
}

class _SpeakersTabState extends State<_SpeakersTab> {
  final Map<String, TextEditingController> _names = {};
  final Map<String, String> _mergeInto = {};

  TextEditingController _controller(String label, Speaker s) =>
      _names.putIfAbsent(label, () => TextEditingController(text: s.name ?? ''));

  @override
  void dispose() {
    for (final c in _names.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _validate() {
    final names = {for (final e in _names.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()};
    final merges = [for (final e in _mergeInto.entries) (e.value, e.key)];
    app.finalize(widget.state.m, widget.doc, names: names, merges: merges);
    showSnack(context, t('Saved. The transcript and exports use these names.'));
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final review = widget.state.m.status == 'review';
    final c = Theme.of(context).colorScheme;
    return Readable(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 40), children: [
        Text(
          t('Listen to a few words from each voice and give it a name. If two entries are the same person, merge them.'),
          style: TextStyle(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final e in doc.speakers.entries)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  CircleAvatar(radius: 8, backgroundColor: speakerColor(context, e.key, doc.speakers)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('${e.value.display} · ${formatDuration(e.value.talkSeconds)}',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  if (e.value.source != null)
                    Text(switch (e.value.source) {
                      'hint' => t('named from your notes'),
                      'user' => t('you'),
                      _ => t('named by you'),
                    }, style: Theme.of(context).textTheme.bodySmall),
                ]),
                const SizedBox(height: 10),
                if (e.key != 'MOI')
                  TextField(
                    controller: _controller(e.key, e.value),
                    decoration: InputDecoration(labelText: t('Name'), isDense: true),
                  ),
                if (doc.expectedParticipants.isNotEmpty && e.key != 'MOI')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(spacing: 6, children: [
                      for (final p in doc.expectedParticipants)
                        ActionChip(
                          label: Text(p),
                          onPressed: () => setState(() => _controller(e.key, e.value).text = p),
                        ),
                    ]),
                  ),
                const SizedBox(height: 8),
                for (final s in e.value.samples)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: () => widget.state.play(s.track, s.t, s.end),
                    ),
                    title: Text('“${s.text}”', maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(hms(s.t)),
                  ),
                if (doc.speakers.length > 1 && e.key != 'MOI')
                  DropdownButton<String?>(
                    value: _mergeInto[e.key],
                    hint: Text(t('Same person as…')),
                    items: [
                      DropdownMenuItem(value: null, child: Text(t('Not merged'))),
                      for (final o in doc.speakers.entries)
                        if (o.key != e.key) DropdownMenuItem(value: o.key, child: Text(o.value.display)),
                    ],
                    onChanged: (v) => setState(() => v == null ? _mergeInto.remove(e.key) : _mergeInto[e.key] = v),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _validate,
          icon: const Icon(Icons.check),
          label: Text(review ? t('Validate and export') : t('Save names')),
        ),
        if (review && !app.settings.keepAudio)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t('The audio is deleted once validated. Keep it in Settings if you prefer.'),
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ]),
    );
  }
}

class _FollowUpTab extends StatelessWidget {
  const _FollowUpTab({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final items = [
      (Deliverable.minutes, Icons.summarize_outlined, t('Minutes'), t('Summary, decisions, actions with owners and deadlines, open points.')),
      (Deliverable.agenda, Icons.event_note_outlined, t('Next meeting agenda'), t('Follow-up of actions, open points, what to prepare.')),
      (Deliverable.email, Icons.mail_outline, t('Follow-up email'), t('Ready to send to the participants.')),
    ];
    return Readable(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 40), children: [
        Text(
          t('These are written by an AI from the transcript. Names and sensitive terms are replaced before anything leaves the device, and you see the exact text first.'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final (d, icon, title, subtitle) in items) _DeliverableCard(meeting: meeting, d: d, icon: icon, title: title, subtitle: subtitle),
      ]),
    );
  }
}

class _DeliverableCard extends StatelessWidget {
  const _DeliverableCard({required this.meeting, required this.d, required this.icon, required this.title, required this.subtitle});
  final Meeting meeting;
  final Deliverable d;
  final IconData icon;
  final String title;
  final String subtitle;

  (String, String) _splitEmail(String text) {
    final lines = text.trim().split('\n');
    final i = lines.indexWhere((l) => RegExp(r'^\s*(subject|objet)\s*:', caseSensitive: false).hasMatch(l));
    if (i < 0) return ('', text.trim());
    final subject = lines[i].substring(lines[i].indexOf(':') + 1).trim();
    return (subject, lines.sublist(i + 1).join('\n').trim());
  }

  @override
  Widget build(BuildContext context) {
    final saved = app.savedResult(meeting, d);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: FilledButton.tonal(
              onPressed: () => showGenerateSheet(context, meeting, d, title),
              child: Text(saved == null ? t('Prepare') : t('Redo')),
            ),
          ),
          if (saved != null) ...[
            const Divider(),
            SelectableText(saved),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: Text(t('Copy')),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: saved));
                  showSnack(context, t('Copied.'));
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(t('Share')),
                onPressed: () => SharePlus.instance.share(ShareParams(text: saved, subject: title)),
              ),
              if (d == Deliverable.email)
                FilledButton.icon(
                  icon: const Icon(Icons.send, size: 18),
                  label: Text(t('Open in my email app')),
                  onPressed: () {
                    final (subject, body) = _splitEmail(saved);
                    openMailDraft(subject, body);
                  },
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}
