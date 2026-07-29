// The install flow — stream to a `.part` file, extract off the main isolate,
// verify by required-file existence, and clean up partial downloads — is
// derived from Control Center (https://github.com/SamuelAlev/control-center),
// MIT (c) 2026 Samuel Alev. See the NOTICE file at the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'failure.dart';
import 'models.dart';

/// Opens an HTTP client, so tests can substitute a transport.
typedef SherpaHttpClientFactory = http.Client Function();

/// Reports install progress in the inclusive range 0–1.
typedef SherpaInstallProgress = void Function(double progress);

/// Downloads, installs, and resolves the sherpa-onnx model files.
///
/// The registry owns no directories of its own: [root] is supplied by the
/// caller so the SDK never guesses at an application's storage layout.
final class SherpaModelRegistry {
  /// Creates a registry rooted at [root].
  SherpaModelRegistry({
    required this.root,
    SherpaHttpClientFactory? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Directory that holds every installed model.
  final Directory root;

  final SherpaHttpClientFactory _httpClientFactory;

  /// Directory a recognition model unpacks into.
  Directory recognitionDirectory(SherpaRecognitionModel model) =>
      Directory(p.join(root.path, model.unpackedDirName));

  /// Directory holding the shared single-file models.
  Directory get supportDirectory => Directory(p.join(root.path, 'support'));

  /// Resolves [model] when every required file is present, else null.
  SherpaRecognitionModelPaths? resolveRecognition(
    SherpaRecognitionModel model,
  ) {
    final dir = recognitionDirectory(model);
    final encoder = File(p.join(dir.path, model.encoderFile));
    final decoder = File(p.join(dir.path, model.decoderFile));
    final tokens = File(p.join(dir.path, model.tokensFile));
    final joinerName = model.joinerFile;
    final joiner = joinerName == null
        ? null
        : File(p.join(dir.path, joinerName));

    final complete =
        encoder.existsSync() &&
        decoder.existsSync() &&
        tokens.existsSync() &&
        (joiner == null || joiner.existsSync());
    if (!complete) {
      return null;
    }
    return SherpaRecognitionModelPaths(
      model: model,
      encoder: encoder.path,
      decoder: decoder.path,
      tokens: tokens.path,
      joiner: joiner?.path,
    );
  }

  /// Resolves the Silero VAD model path when installed, else null.
  String? resolveVad() {
    final file = File(
      p.join(supportDirectory.path, SherpaFileModel.sileroVad.fileName),
    );
    return file.existsSync() ? file.path : null;
  }

  /// Resolves the diarization pair when both files are present, else null.
  SherpaDiarizationModelPaths? resolveDiarization() {
    final segmentation = File(
      p.join(
        supportDirectory.path,
        SherpaArchivedFileModel.pyannoteSegmentation.modelFile,
      ),
    );
    final embedding = File(
      p.join(supportDirectory.path, SherpaFileModel.wespeakerResnet34.fileName),
    );
    if (!segmentation.existsSync() || !embedding.existsSync()) {
      return null;
    }
    return SherpaDiarizationModelPaths(
      segmentation: segmentation.path,
      embedding: embedding.path,
      embeddingModelId: SherpaFileModel.wespeakerResnet34.id,
    );
  }

  /// Installs [model], returning immediately when it is already present.
  Future<SherpaRecognitionModelPaths> installRecognition(
    SherpaRecognitionModel model, {
    SherpaInstallProgress? onProgress,
  }) async {
    final existing = resolveRecognition(model);
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    await _installArchive(
      url: model.archiveUrl,
      expectedBytes: model.archiveBytes,
      destination: root,
      onProgress: onProgress,
    );
    final resolved = resolveRecognition(model);
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The ${model.displayName} archive did not contain the expected files.',
      );
    }
    return resolved;
  }

  /// Installs the Silero VAD model, returning its path.
  Future<String> installVad({SherpaInstallProgress? onProgress}) async {
    final existing = resolveVad();
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    await _installFile(
      model: SherpaFileModel.sileroVad,
      onProgress: onProgress,
    );
    final resolved = resolveVad();
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The Silero VAD model could not be installed.',
      );
    }
    return resolved;
  }

  /// Installs the pyannote and WeSpeaker pair used for diarization.
  Future<SherpaDiarizationModelPaths> installDiarization({
    SherpaInstallProgress? onProgress,
  }) async {
    final existing = resolveDiarization();
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    const segmentation = SherpaArchivedFileModel.pyannoteSegmentation;
    await _installArchive(
      url: segmentation.archiveUrl,
      expectedBytes: segmentation.archiveBytes,
      destination: supportDirectory,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(progress * 0.5),
    );
    await _installFile(
      model: SherpaFileModel.wespeakerResnet34,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(0.5 + progress * 0.5),
    );
    final resolved = resolveDiarization();
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The diarization models could not be installed.',
      );
    }
    return resolved;
  }

  /// Removes an installed recognition model.
  Future<void> uninstallRecognition(SherpaRecognitionModel model) async {
    final dir = recognitionDirectory(model);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> _installFile({
    required SherpaFileModel model,
    SherpaInstallProgress? onProgress,
  }) async {
    await supportDirectory.create(recursive: true);
    final target = File(p.join(supportDirectory.path, model.fileName));
    final partial = File('${target.path}.part');
    try {
      final bytes = await _download(
        url: model.url,
        expectedBytes: model.sizeBytes,
        target: partial,
        onProgress: onProgress,
      );
      if (bytes.isEmpty) {
        throw sherpaSpeechFailure(
          'sherpa_model_download_empty',
          'install',
          'The ${model.displayName} download returned no data.',
        );
      }
      await partial.rename(target.path);
      onProgress?.call(1);
    } on Object {
      if (partial.existsSync()) {
        await partial.delete();
      }
      rethrow;
    }
  }

  Future<void> _installArchive({
    required String url,
    required int expectedBytes,
    required Directory destination,
    SherpaInstallProgress? onProgress,
  }) async {
    await destination.create(recursive: true);
    final partial = File(p.join(destination.path, '${p.basename(url)}.part'));
    try {
      final bytes = await _download(
        url: url,
        expectedBytes: expectedBytes,
        target: partial,
        // Extraction is the last 20% of the reported progress.
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress(progress * 0.8),
      );
      // bzip2 decoding is opaque and CPU-bound; keep it off the caller's
      // isolate so a UI stays responsive for the whole extraction.
      final destinationPath = destination.path;
      await Isolate.run(() => _extractTarBz2(bytes, destinationPath));
      onProgress?.call(1);
    } on Object {
      if (partial.existsSync()) {
        await partial.delete();
      }
      rethrow;
    } finally {
      if (partial.existsSync()) {
        await partial.delete();
      }
    }
  }

  Future<Uint8List> _download({
    required String url,
    required int expectedBytes,
    required File target,
    SherpaInstallProgress? onProgress,
  }) async {
    final client = _httpClientFactory();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw sherpaSpeechFailure(
          'sherpa_model_download_failed',
          'install',
          'The model download failed with status ${response.statusCode}.',
          retryable: response.statusCode >= 500,
        );
      }
      final total = response.contentLength ?? expectedBytes;
      final builder = BytesBuilder(copy: false);
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0, 1));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return builder.takeBytes();
    } finally {
      await sink?.close();
      client.close();
    }
  }
}

/// Extracts a `.tar.bz2` payload into [destinationPath].
void _extractTarBz2(Uint8List bytes, String destinationPath) {
  final tarBytes = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tarBytes);
  for (final entry in archive) {
    if (!entry.isFile) {
      continue;
    }
    // Reject traversal outside the destination before writing anything.
    final normalized = p.normalize(entry.name);
    if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
      continue;
    }
    final file = File(p.join(destinationPath, normalized));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
  }
}
