// SPDX-FileCopyrightText: 2026 VerbaLog PC & Android contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The on-device models, all from the sherpa-onnx project (k2-fsa), free to download
// with no account. Each file is tried from Hugging Face first (single int8 files),
// then from the sherpa-onnx GitHub release archive.

class ModelFile {
  const ModelFile(this.name, {this.hf, this.archive, this.archivePath, this.direct, this.approxMb = 0});
  final String name; // file name on disk
  final String? hf; // Hugging Face resolve URL
  final String? archive; // .tar.bz2 release URL containing the file
  final String? archivePath; // path inside that archive
  final String? direct; // direct download URL
  final int approxMb;
}

class ModelSpec {
  const ModelSpec(this.id, this.title, this.description, this.files);
  final String id;
  final String title;
  final String description;
  final List<ModelFile> files;
  int get approxMb => files.fold(0, (s, f) => s + f.approxMb);
}

const _gh = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';
const _hf = 'https://huggingface.co/csukuangfj';

ModelSpec _whisper(String size, String title, String description, int encMb, int decMb) => ModelSpec(
      'whisper-$size',
      title,
      description,
      [
        for (final (part, mb) in [('encoder.int8.onnx', encMb), ('decoder.int8.onnx', decMb), ('tokens.txt', 1)])
          ModelFile(
            '$size-$part',
            hf: '$_hf/sherpa-onnx-whisper-$size/resolve/main/$size-$part',
            archive: '$_gh/asr-models/sherpa-onnx-whisper-$size.tar.bz2',
            archivePath: 'sherpa-onnx-whisper-$size/$size-$part',
            approxMb: mb,
          ),
      ],
    );

final whisperModels = [
  _whisper('turbo', 'Best accuracy (Whisper large-v3 turbo)',
      'Most accurate, close to the macOS Verbalog. Recommended on a PC. About 1 GB.', 675, 361),
  _whisper('small', 'Balanced (Whisper small)', 'Good accuracy, faster. Recommended on a phone. About 360 MB.', 112, 250),
  _whisper('base', 'Fast (Whisper base)', 'Quick, less accurate on names and accents. About 160 MB.', 29, 131),
];

const segmentationModel = ModelSpec('segmentation', 'Speaker separation', 'pyannote segmentation 3.0', [
  ModelFile('segmentation.int8.onnx',
      archive: '$_gh/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
      archivePath: 'sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx',
      approxMb: 2),
]);

const embeddingModel = ModelSpec('embedding', 'Voice fingerprints', '3D-Speaker ERes2Net', [
  ModelFile('3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
      direct: '$_gh/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
      approxMb: 40),
]);

ModelSpec whisperById(String id) => whisperModels.firstWhere((m) => m.id == id, orElse: () => whisperModels.first);
