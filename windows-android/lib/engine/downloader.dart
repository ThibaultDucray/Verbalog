// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Downloads the on-device models once. Files land as `<name>.part` and are renamed
// only when complete, so an interrupted download never leaves a broken model.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'models_catalog.dart';

typedef DownloadProgress = void Function(String label, double fraction);

class ModelDownloader {
  ModelDownloader(this.modelDir, {http.Client? client}) : _client = client ?? http.Client();
  final String modelDir;
  final http.Client _client;

  bool isInstalled(ModelSpec spec) => spec.files.every((f) => File(p.join(modelDir, f.name)).existsSync());

  Future<void> install(ModelSpec spec, {DownloadProgress? onProgress}) async {
    Directory(modelDir).createSync(recursive: true);
    final missing = spec.files.where((f) => !File(p.join(modelDir, f.name)).existsSync()).toList();
    final totalMb = missing.fold(0, (s, f) => s + (f.approxMb == 0 ? 1 : f.approxMb));
    var doneMb = 0;
    for (final file in missing) {
      final weight = file.approxMb == 0 ? 1 : file.approxMb;
      void report(double f) => onProgress?.call(spec.title, (doneMb + weight * f) / totalMb);
      await _installFile(file, report);
      doneMb += weight;
    }
    onProgress?.call(spec.title, 1);
  }

  Future<void> _installFile(ModelFile file, void Function(double) report) async {
    final target = p.join(modelDir, file.name);
    final direct = file.direct ?? file.hf;
    if (direct != null) {
      try {
        await _download(direct, target, report);
        return;
      } catch (_) {
        if (file.archive == null) rethrow;
      }
    }
    // Fallback: the release archive, extracting only the file we need.
    final archive = p.join(modelDir, '${p.basename(file.archive!)}.part');
    if (!File(archive).existsSync()) {
      await _download(file.archive!, archive, (f) => report(f * 0.9), keepPart: true);
    }
    await _extractFromTarBz2(archive, file.archivePath!, target);
    report(1);
    // Other files of the same model may come from the same archive: remove it once none is missing.
  }

  /// Remove leftover archives once a model is complete.
  void cleanArchives() {
    final d = Directory(modelDir);
    if (!d.existsSync()) return;
    for (final f in d.listSync().whereType<File>()) {
      if (f.path.endsWith('.tar.bz2.part') || f.path.endsWith('.tar.part')) f.deleteSync();
    }
  }

  Future<void> _download(String url, String target, void Function(double) report, {bool keepPart = false}) async {
    final partPath = keepPart ? target : '$target.part';
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final total = response.contentLength ?? 0;
    final sink = File(partPath).openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) report(received / total);
      }
    } catch (_) {
      await sink.close();
      File(partPath).deleteSync();
      rethrow;
    }
    await sink.close();
    if (!keepPart) File(partPath).renameSync(target);
  }

  static Future<void> _extractFromTarBz2(String archivePath, String inner, String target) async {
    final tarPath = '${archivePath.replaceAll('.bz2.part', '')}.part';
    if (!File(tarPath).existsSync()) {
      final input = InputFileStream(archivePath);
      final output = OutputFileStream('$tarPath.tmp');
      BZip2Decoder().decodeStream(input, output);
      await input.close();
      await output.close();
      File('$tarPath.tmp').renameSync(tarPath);
    }
    final input = InputFileStream(tarPath);
    final archive = TarDecoder().decodeStream(input, storeData: false);
    try {
      final entry = archive.files.firstWhere((f) => f.name == inner,
          orElse: () => throw StateError('$inner not found in ${p.basename(archivePath)}'));
      final out = OutputFileStream('$target.part');
      entry.writeContent(out);
      await out.close();
      File('$target.part').renameSync(target);
    } finally {
      await input.close();
    }
  }
}
