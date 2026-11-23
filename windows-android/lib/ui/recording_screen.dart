// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/app_state.dart';
import '../app/recorder.dart';
import '../core/i18n.dart';
import '../core/models.dart';
import '../core/notes.dart';
import '../core/session.dart';
import '../core/text.dart';
import 'common.dart';
import 'meeting_screen.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.meeting});
  final Meeting meeting;
  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final MeetingRecorder _rec = MeetingRecorder(widget.meeting);
  final _note = TextEditingController();
  final _focus = FocusNode();
  final List<RawNote> _notes = [];
  Timer? _ticker;
  StreamSubscription<double>? _levelSub;
  double _mic = -160, _system = -160;
  double? _noteStart; // the timestamp is taken at the first keystroke
  String? _error;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _notes.addAll(widget.meeting.rawNotes());
    _start();
  }

  Future<void> _start() async {
    try {
      await _rec.start();
      _started = true;
      // A phone that locks would cut the microphone: keep the screen on while recording.
      WakelockPlus.enable().catchError((_) {});
      _levelSub = _rec.micLevel().listen((v) => _mic = v);
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        _system = await _rec.systemLevel();
        if (mounted) setState(() {});
      });
      if (_rec.systemError != null && mounted) {
        showSnack(context, t("The PC's sound can't be recorded: {error}", {'error': _rec.systemError}));
      }
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    _note.dispose();
    _focus.dispose();
    if (_started) _rec.stop();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  double get _now => _rec.elapsed.inMilliseconds / 1000;

  void _onTyping(String text) {
    if (text.isNotEmpty && _noteStart == null) _noteStart = _now;
    if (text.isEmpty) _noteStart = null;
  }

  void _submit() {
    final text = _note.text;
    final note = RawNote(_noteStart ?? _now, text);
    widget.meeting.appendNote(note);
    setState(() {
      _notes.add(note);
      _note.clear();
      _noteStart = null;
    });
    _focus.requestFocus();
  }

  void _prefix(String p) {
    _note.text = '$p ${_note.text.replaceFirst(RegExp(r'^[!#?~@]\s*'), '')}';
    _note.selection = TextSelection.collapsed(offset: _note.text.length);
    _onTyping(_note.text);
    _focus.requestFocus();
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    await _rec.stop();
    _started = false;
    if (app.settings.autoProcess) app.enqueue(widget.meeting);
    app.refresh();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MeetingScreen(meeting: widget.meeting)));
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))),
      );
    }
    final participants = widget.meeting.participants;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _rec.paused ? _rec.resume() : _rec.pause(),
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final stop = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(t('Stop the recording?')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('Keep recording'))),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('Stop'))),
              ],
            ),
          );
          if (stop == true) _stop();
        },
        child: Scaffold(
          appBar: AppBar(title: Text(widget.meeting.title)),
          body: Readable(
            child: Column(children: [
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.fiber_manual_record, color: _rec.paused ? c.outline : Colors.red, size: 18),
                const SizedBox(width: 8),
                Text(hms(_now), style: Theme.of(context).textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(children: [
                  _Meter(label: t('Microphone'), db: _mic),
                  if (_rec.capturesSystem) _Meter(label: t('Call sound'), db: _system),
                ]),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    _rec.paused ? await _rec.resume() : await _rec.pause();
                    setState(() {});
                  },
                  icon: Icon(_rec.paused ? Icons.play_arrow : Icons.pause),
                  label: Text(_rec.paused ? t('Resume') : t('Pause')),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: c.error, foregroundColor: c.onError),
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                  label: Text(t('Stop')),
                ),
              ]),
              const Divider(height: 32),
              Expanded(
                child: _notes.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          t('Type notes while you listen. Start with ! for an action, # for a decision, ? for a question, ~ for a private note, @Name to say who is speaking. An empty note is a bookmark.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.onSurfaceVariant),
                        ),
                      )
                    : ListView(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          for (final n in _notes.reversed) _NoteRow(note: parseNote(n.t, n.text, expected: participants)),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final (p, label, icon) in [
                        ('!', t('Action'), Icons.task_alt),
                        ('#', t('Decision'), Icons.gavel),
                        ('?', t('Question'), Icons.help_outline),
                        ('~', t('Private'), Icons.lock_outline),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(avatar: Icon(icon, size: 18), label: Text(label), onPressed: () => _prefix(p)),
                        ),
                      for (final name in participants)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            avatar: const Icon(Icons.record_voice_over_outlined, size: 18),
                            label: Text(name),
                            onPressed: () {
                              _noteStart = _now;
                              _note.text = '@$name';
                              _submit();
                            },
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _note,
                    focusNode: _focus,
                    autofocus: true,
                    onChanged: _onTyping,
                    onSubmitted: (_) => _submit(),
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: t('Note, then Enter'),
                      suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _submit),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.db});
  final String label;
  final double db;
  @override
  Widget build(BuildContext context) {
    final v = ((db + 60) / 60).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: LinearProgressIndicator(value: v, minHeight: 6, borderRadius: BorderRadius.circular(3))),
      ]),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});
  final Note note;
  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (note.type) {
      'action' => (Icons.task_alt, note.text),
      'decision' => (Icons.gavel, note.text),
      'question' => (Icons.help_outline, note.text),
      'private' => (Icons.lock_outline, note.text),
      'bookmark' => (Icons.bookmark_outline, t('Bookmark')),
      'speaker' => (Icons.record_voice_over_outlined, t('{name} is speaking', {'name': note.speaker})),
      _ => (Icons.notes, note.text),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(text),
      trailing: Text(hms(note.t), style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
