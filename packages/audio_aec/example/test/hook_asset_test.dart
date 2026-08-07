// Proves the build-hook distribution path from the CONSUMER side.
//
// Everything in the parent package's own test suite resolves the library by
// path — `AUDIO_AEC_LIBRARY` or `.native/`. That proves the loader works; it
// proves nothing about whether a published package could hand a consumer a
// binary. This suite is the other half: no environment variable, no explicit
// path, no file the test can see. The only way `aec_version` answers here is if
// `hook/build.dart` ran during `dart test`, registered a code asset, and the
// SDK bundled it.
//
// Run with:
//   packages/audio_aec/tool/build_native.sh   # once, produces ../.native/
//   cd packages/audio_aec/example && dart test
//
// Skips rather than fails when no library was built, so a checkout without a
// C++ toolchain is not a red suite.

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:test/test.dart';

void main() {
  final NativeAssetAecBindings? asset = NativeAssetAecBindings.tryResolve();
  final String? skip = asset == null
      ? 'No code asset was registered. Build one with '
            'packages/audio_aec/tool/build_native.sh, then re-run: the hook '
            'reads hooks.user_defines.audio_aec.prebuilt from this package\'s '
            'pubspec.yaml.'
      : null;

  group('library resolved through the build hook', () {
    setUp(() {
      // Guards the whole point of the suite. If this were set, the assertions
      // below would pass through the ordinary path-based loader and prove
      // nothing at all.
      expect(
        Platform.environment[aecLibraryEnvironmentVariable],
        isNull,
        reason:
            'Unset $aecLibraryEnvironmentVariable before running this suite — '
            'with it set, this test cannot distinguish the hook path from the '
            'environment-variable path.',
      );
    });

    test('the hook-registered asset exports the expected engine', () {
      expect(asset!.version(), 'webrtc-audio-processing-2.1+aec3');
    });

    test('capability probe creates and releases the packaged engine', () {
      final AecRuntimeCapability capability = probeAecRuntime();

      expect(capability.isAvailable, isTrue);
      expect(capability.version, 'webrtc-audio-processing-2.1+aec3');
      expect(capability.failure, isNull);
    });

    test('AecProcessor.create() picks the asset up with no path and no env', () {
      final AecProcessor processor = AecProcessor.create();
      addTearDown(processor.dispose);

      expect(processor.blockFrames, 160);
      expect(processor.version, contains('aec3'));

      // One second of real blocks through both paths, mirroring the parent
      // package's smoke test: the asset is not just loadable, it is the working
      // AEC3 instance.
      final Int16List reference = Int16List.fromList(
        List<int>.generate(160, (int index) => (index % 32) * 400 - 6000),
      );
      final Int16List capture = Int16List.fromList(
        List<int>.generate(160, (int index) => (index % 32) * 400 - 6000),
      );
      for (var block = 0; block < 100; block += 1) {
        processor.processReverse(reference);
        expect(processor.processCapture(capture, 80), hasLength(160));
      }
      expect(processor.metrics().erle, anyOf(isNull, isA<double>()));
    });
  }, skip: skip);
}
