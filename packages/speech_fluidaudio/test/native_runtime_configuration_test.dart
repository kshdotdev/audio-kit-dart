import 'package:fluidaudio_dart/fluidaudio_dart.dart' as native;
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_fluidaudio/speech_fluidaudio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FluidNativeRuntime host-managed roots', () {
    test(
      'applies roots and offline mode once, before the first driver',
      () async {
        final models = _RecordingFluidModels();
        final runtime = FluidNativeRuntime(
          modelsRootPath: '/host/models',
          offline: true,
          models: models,
        );

        // Driver creation reaches the real platform channel and fails in a
        // test binding — but configuration must already have been applied.
        await expectLater(
          runtime.createBatchAsr(FluidRecognitionModel.parakeetV3),
          throwsA(anything),
        );
        expect(models.rootsCalls, hasLength(1));
        expect(models.rootsCalls.single?.modelsRoot, '/host/models');
        expect(models.rootsCalls.single?.ttsRoot, isNull);
        expect(models.offlineCalls, <bool>[true]);

        // A second driver does not reconfigure.
        await expectLater(
          runtime.createVad(
            threshold: 0.5,
            minimumSilence: const Duration(milliseconds: 100),
          ),
          throwsA(anything),
        );
        expect(models.rootsCalls, hasLength(1));
        expect(models.offlineCalls, hasLength(1));
        await runtime.close();
      },
    );

    test(
      'performs no configuration calls when nothing was requested',
      () async {
        final models = _RecordingFluidModels();
        final runtime = FluidNativeRuntime(models: models);

        await expectLater(
          runtime.createBatchAsr(FluidRecognitionModel.parakeetV3),
          throwsA(anything),
        );
        expect(models.rootsCalls, isEmpty);
        expect(models.offlineCalls, isEmpty);
        await runtime.close();
      },
    );
  });
}

final class _RecordingFluidModels implements native.FluidModels {
  final List<native.FluidModelRoots?> rootsCalls = <native.FluidModelRoots?>[];
  final List<bool> offlineCalls = <bool>[];

  @override
  Future<void> setModelRoots(native.FluidModelRoots? roots) async {
    rootsCalls.add(roots);
  }

  @override
  Future<native.FluidModelRoots> modelRoots() async =>
      const native.FluidModelRoots();

  @override
  Future<void> setOfflineMode(bool enabled) async {
    offlineCalls.add(enabled);
  }

  @override
  Future<bool> isDownloaded(native.ModelKind kind) async => false;

  @override
  Stream<native.FluidDownloadProgress> download(native.ModelKind kind) =>
      const Stream<native.FluidDownloadProgress>.empty();

  @override
  Future<void> remove(native.ModelKind kind) async {}

  @override
  Future<String> cacheDirectory(native.ModelKind kind) async => '/models';
}
