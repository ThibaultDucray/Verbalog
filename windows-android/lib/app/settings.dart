// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Paths {
  Paths._(this.meetings, this.models, this.sensitiveFile);
  final String meetings; // user-visible: Documents/VerbaLog
  final String models; // app support: downloaded once
  final String sensitiveFile;

  static Future<Paths> resolve() async {
    final support = await getApplicationSupportDirectory();
    // Meetings go where people find them: Documents/VerbaLog on a PC, the app's own
    // documents folder on Android. Without a documents folder, next to the models.
    String docs;
    try {
      docs = (await getApplicationDocumentsDirectory()).path;
      if (!Platform.isAndroid) docs = p.join(docs, 'VerbaLog');
    } catch (_) {
      docs = support.path;
    }
    final meetings = p.join(docs, 'meetings');
    Directory(meetings).createSync(recursive: true);
    final models = p.join(support.path, 'models');
    Directory(models).createSync(recursive: true);
    Settings.supportDir = support.path;
    return Paths._(meetings, models, p.join(support.path, 'sensitive.txt'));
  }
}

class Settings {
  Settings._(this._prefs);
  final SharedPreferences _prefs;
  static const _secure = FlutterSecureStorage();

  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  String get userName => _prefs.getString('user_name') ?? '';
  set userName(String v) => _prefs.setString('user_name', v.trim());

  String get language => _prefs.getString('language') ?? (Platform.localeName.startsWith('fr') ? 'fr' : 'en');
  set language(String v) => _prefs.setString('language', v);

  String get whisperModel =>
      _prefs.getString('whisper_model') ?? (Platform.isAndroid ? 'whisper-small' : 'whisper-turbo');
  set whisperModel(String v) => _prefs.setString('whisper_model', v);

  List<String> get defaultLanguages => _prefs.getStringList('languages') ?? const ['fr', 'en'];
  set defaultLanguages(List<String> v) => _prefs.setStringList('languages', v);

  String get lastMode => _prefs.getString('last_mode') ?? (Platform.isWindows ? 'visio' : 'presentiel');
  set lastMode(String v) => _prefs.setString('last_mode', v);

  String get outputLanguage => _prefs.getString('output_language') ?? language;
  set outputLanguage(String v) => _prefs.setString('output_language', v);

  bool get pseudonymize => _prefs.getBool('pseudonymize') ?? true;
  set pseudonymize(bool v) => _prefs.setBool('pseudonymize', v);

  bool get keepAudio => _prefs.getBool('keep_audio') ?? false;
  set keepAudio(bool v) => _prefs.setBool('keep_audio', v);

  bool get autoProcess => _prefs.getBool('auto_process') ?? true;
  set autoProcess(bool v) => _prefs.setBool('auto_process', v);

  String get llmModel => _prefs.getString('llm_model') ?? 'claude-opus-5-5';
  set llmModel(String v) => _prefs.setString('llm_model', v);

  List<String> get glossary => _prefs.getStringList('glossary') ?? const [];
  set glossary(List<String> v) => _prefs.setStringList('glossary', v);

  bool get setupDone => _prefs.getBool('setup_done') ?? false;
  set setupDone(bool v) => _prefs.setBool('setup_done', v);

  // Windows Credential Manager and the Android Keystore through flutter_secure_storage.
  // Linux (a development target only) has no reliable keyring everywhere: a private file.
  static String supportDir = '';
  File get _linuxKeyFile => File(p.join(supportDir, 'anthropic_key'));

  Future<String> apiKey() async {
    try {
      if (Platform.isLinux) return _linuxKeyFile.existsSync() ? _linuxKeyFile.readAsStringSync().trim() : '';
      return await _secure.read(key: 'anthropic_api_key') ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setApiKey(String v) async {
    if (Platform.isLinux) {
      if (v.trim().isEmpty) {
        if (_linuxKeyFile.existsSync()) _linuxKeyFile.deleteSync();
      } else {
        _linuxKeyFile.writeAsStringSync(v.trim());
        await Process.run('chmod', ['600', _linuxKeyFile.path]);
      }
      return;
    }
    if (v.trim().isEmpty) {
      await _secure.delete(key: 'anthropic_api_key');
    } else {
      await _secure.write(key: 'anthropic_api_key', value: v.trim());
    }
  }
}
