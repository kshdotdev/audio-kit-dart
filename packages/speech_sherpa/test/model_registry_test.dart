import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:speech_core/speech_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('speech_sherpa_registry');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// Builds a real `.tar.bz2` so the extraction path is exercised end to end.
  Uint8List buildArchive(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.add(ArchiveFile.bytes(entry.key, bytes));
    }
    final tar = TarEncoder().encodeBytes(archive);
    return Uint8List.fromList(BZip2Encoder().encode(tar));
  }

  group('resolve', () {
    test('returns null until every required file exists', () {
      final registry = SherpaModelRegistry(root: root);
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final dir = registry.recognitionDirectory(model)
        ..createSync(recursive: true);

      File('${dir.path}/${model.encoderFile}').writeAsStringSync('e');
      File('${dir.path}/${model.decoderFile}').writeAsStringSync('d');
      File('${dir.path}/${model.tokensFile}').writeAsStringSync('t');
      // The joiner is still missing, so a transducer is not usable yet.
      expect(registry.resolveRecognition(model), isNull);

      File('${dir.path}/${model.joinerFile}').writeAsStringSync('j');
      final resolved = registry.resolveRecognition(model);
      expect(resolved, isNotNull);
      expect(resolved!.joiner, isNotNull);
      expect(resolved.model.id, model.id);
    });

    test('a Whisper model needs no joiner', () {
      final registry = SherpaModelRegistry(root: root);
      const model = SherpaRecognitionModel.whisperBaseEn;
      final dir = registry.recognitionDirectory(model)
        ..createSync(recursive: true);
      File('${dir.path}/${model.encoderFile}').writeAsStringSync('e');
      File('${dir.path}/${model.decoderFile}').writeAsStringSync('d');
      File('${dir.path}/${model.tokensFile}').writeAsStringSync('t');

      final resolved = registry.resolveRecognition(model);
      expect(resolved, isNotNull);
      expect(resolved!.joiner, isNull);
    });

    test('diarization needs both halves of the pair', () {
      final registry = SherpaModelRegistry(root: root);
      final support = registry.supportDirectory..createSync(recursive: true);
      File(
        '${support.path}/${SherpaFileModel.wespeakerResnet34.fileName}',
      ).writeAsStringSync('embedding');

      expect(registry.resolveDiarization(), isNull);

      final segmentation = File(
        '${support.path}/'
        '${SherpaArchivedFileModel.pyannoteSegmentation.modelFile}',
      );
      segmentation.parent.createSync(recursive: true);
      segmentation.writeAsStringSync('segmentation');

      final resolved = registry.resolveDiarization();
      expect(resolved, isNotNull);
      // The embedding model ID travels with the vectors it produces.
      expect(resolved!.embeddingModelId, SherpaFileModel.wespeakerResnet34.id);
    });
  });

  group('install', () {
    test('downloads and extracts a recognition archive', () async {
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final archive = buildArchive(<String, String>{
        '${model.unpackedDirName}/${model.encoderFile}': 'encoder',
        '${model.unpackedDirName}/${model.decoderFile}': 'decoder',
        '${model.unpackedDirName}/${model.joinerFile}': 'joiner',
        '${model.unpackedDirName}/${model.tokensFile}': 'tokens',
      });
      final client = _FakeClient({model.archiveUrl: archive});
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      final progress = <double>[];
      final paths = await registry.installRecognition(
        model,
        onProgress: progress.add,
      );

      expect(File(paths.encoder).existsSync(), isTrue);
      expect(File(paths.joiner!).existsSync(), isTrue);
      expect(progress.last, 1);
      expect(client.requested, <String>[model.archiveUrl]);
      // No partial file survives a successful install.
      expect(
        root.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.part'),
        ),
        isEmpty,
      );
    });

    test(
      'is idempotent and skips the network when already installed',
      () async {
        const model = SherpaRecognitionModel.whisperBaseEn;
        final archive = buildArchive(<String, String>{
          '${model.unpackedDirName}/${model.encoderFile}': 'encoder',
          '${model.unpackedDirName}/${model.decoderFile}': 'decoder',
          '${model.unpackedDirName}/${model.tokensFile}': 'tokens',
        });
        final client = _FakeClient({model.archiveUrl: archive});
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => client,
        );

        await registry.installRecognition(model);
        await registry.installRecognition(model);

        expect(client.requested, hasLength(1));
      },
    );

    test('downloads the bare Silero VAD file', () async {
      final client = _FakeClient({
        SherpaFileModel.sileroVad.url: Uint8List.fromList(<int>[1, 2, 3, 4]),
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      final path = await registry.installVad();

      expect(File(path).readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(registry.resolveVad(), path);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('installs the diarization pair from archive plus bare file', () async {
      const segmentation = SherpaArchivedFileModel.pyannoteSegmentation;
      final client = _FakeClient({
        segmentation.archiveUrl: buildArchive(<String, String>{
          segmentation.modelFile: 'segmentation-model',
        }),
        SherpaFileModel.wespeakerResnet34.url: Uint8List.fromList(<int>[9, 9]),
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      final paths = await registry.installDiarization();

      expect(File(paths.segmentation).existsSync(), isTrue);
      expect(File(paths.embedding).existsSync(), isTrue);
      expect(
        client.requested,
        containsAll(<String>[
          segmentation.archiveUrl,
          SherpaFileModel.wespeakerResnet34.url,
        ]),
      );
    });

    test('reports a retryable failure for a server error', () async {
      final client = _FakeClient(const {}, statusCode: 503);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await expectLater(
        registry.installVad(),
        throwsA(
          isA<SpeechFailure>()
              .having((f) => f.code, 'code', 'sherpa_model_download_failed')
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      // A failed download must not leave a partial file behind.
      expect(
        registry.supportDirectory.existsSync()
            ? registry.supportDirectory.listSync().where(
                (e) => e.path.endsWith('.part'),
              )
            : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('reports a non-retryable failure for a client error', () async {
      final client = _FakeClient(const {}, statusCode: 404);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await expectLater(
        registry.installVad(),
        throwsA(
          isA<SpeechFailure>().having((f) => f.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('fails when the archive lacks the expected files', () async {
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final client = _FakeClient({
        model.archiveUrl: buildArchive(<String, String>{
          '${model.unpackedDirName}/README.md': 'nothing useful',
        }),
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_install_incomplete',
          ),
        ),
      );
    });

    test('ignores archive entries that escape the destination', () async {
      final client = _FakeClient({
        SherpaArchivedFileModel.pyannoteSegmentation.archiveUrl:
            buildArchive(<String, String>{
              '../escaped.onnx': 'nope',
              SherpaArchivedFileModel.pyannoteSegmentation.modelFile: 'ok',
            }),
        SherpaFileModel.wespeakerResnet34.url: Uint8List.fromList(<int>[1]),
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await registry.installDiarization();

      expect(File('${root.path}/escaped.onnx').existsSync(), isFalse);
      expect(File('${root.parent.path}/escaped.onnx').existsSync(), isFalse);
    });

    test('uninstall removes an installed model directory', () async {
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final client = _FakeClient({
        model.archiveUrl: buildArchive(<String, String>{
          '${model.unpackedDirName}/${model.encoderFile}': 'e',
          '${model.unpackedDirName}/${model.decoderFile}': 'd',
          '${model.unpackedDirName}/${model.joinerFile}': 'j',
          '${model.unpackedDirName}/${model.tokensFile}': 't',
        }),
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await registry.installRecognition(model);
      expect(registry.resolveRecognition(model), isNotNull);

      await registry.uninstallRecognition(model);
      expect(registry.resolveRecognition(model), isNull);
    });
  });

  group('catalog', () {
    test('preserves the upstream release-tag typo for WeSpeaker', () {
      // The k2-fsa tag really is "recongition"; fixing the spelling 404s.
      expect(
        SherpaFileModel.wespeakerResnet34.url,
        contains('speaker-recongition-models'),
      );
    });

    test('every recognition archive comes from the k2-fsa releases', () {
      for (final model in SherpaRecognitionModel.all) {
        expect(
          model.archiveUrl,
          startsWith('https://github.com/k2-fsa/sherpa-onnx/releases/'),
          reason: model.id,
        );
        expect(model.archiveUrl, endsWith('.tar.bz2'), reason: model.id);
      }
    });

    test('transducers declare a joiner and Whisper models do not', () {
      for (final model in SherpaRecognitionModel.all) {
        switch (model.kind) {
          case SherpaRecognitionModelKind.transducer:
          case SherpaRecognitionModelKind.streamingTransducer:
            expect(model.joinerFile, isNotNull, reason: model.id);
          case SherpaRecognitionModelKind.whisper:
            expect(model.joinerFile, isNull, reason: model.id);
        }
      }
    });
  });
}

/// Serves canned bodies and records which URLs were requested.
final class _FakeClient extends http.BaseClient {
  _FakeClient(this._bodies, {this.statusCode = 200});

  final Map<String, Uint8List> _bodies;
  final int statusCode;
  final List<String> requested = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    requested.add(url);
    final body = _bodies[url] ?? Uint8List(0);
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      statusCode,
      contentLength: body.length,
      request: request,
    );
  }
}
