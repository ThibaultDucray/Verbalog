// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../core/session.dart';

const seed = Color(0xFF3D5AFE);

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: scheme.outlineVariant)),
    ),
  );
}

String modeLabel(String mode) => switch (mode) {
      'visio' => t('Video call'),
      'hybride' => t('Hybrid'),
      _ => t('In person'),
    };

IconData modeIcon(String mode) => switch (mode) {
      'visio' => Icons.videocam_outlined,
      'hybride' => Icons.groups_2_outlined,
      _ => Icons.groups_outlined,
    };

String statusLabel(Meeting m) => switch (m.status) {
      'recording' => t('Recording'),
      'recorded' => t('Ready to process'),
      'queued' => t('Waiting'),
      'processing' => m.progressLabel ?? t('Processing'),
      'review' => t('Name the speakers'),
      'done' => t('Done'),
      'failed' => t('Failed'),
      _ => m.status,
    };

Color statusColor(BuildContext context, Meeting m) {
  final c = Theme.of(context).colorScheme;
  return switch (m.status) {
    'review' => c.tertiary,
    'failed' => c.error,
    'done' => c.primary,
    _ => c.onSurfaceVariant,
  };
}

String formatDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String formatDuration(double seconds) {
  final s = seconds.round();
  if (s < 60) return '${s}s';
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}' : '$m min';
}

void showSnack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));

/// Centered column that stays readable on a wide PC window.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child, this.maxWidth = 860});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) =>
      Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child));
}

class LanguageChips extends StatelessWidget {
  const LanguageChips({super.key, required this.selected, required this.onChanged});
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in languageNames.entries)
            FilterChip(
              label: Text(t(e.value)),
              selected: selected.contains(e.key),
              onSelected: (on) {
                final next = [...selected];
                on ? next.add(e.key) : next.remove(e.key);
                if (next.isNotEmpty) onChanged(next);
              },
            ),
        ],
      );
}
