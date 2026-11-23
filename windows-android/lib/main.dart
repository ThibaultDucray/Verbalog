// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// VerbaLog for Windows and Android: records meetings, transcribes them on the
// device, tells the voices apart, and prepares minutes, an agenda and a follow-up
// email. A port of Verbalog for macOS by Thibault Ducray.

import 'package:material_ui/material_ui.dart';

import 'app/app_state.dart';
import 'ui/common.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const VerbaLogApp());
}

class VerbaLogApp extends StatelessWidget {
  const VerbaLogApp({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => MaterialApp(
          title: 'VerbaLog',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: const HomeScreen(),
        ),
      );
}
