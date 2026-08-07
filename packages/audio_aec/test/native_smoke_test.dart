// The only test that needs a real native library. It is skipped unless one is
// present, because audio_aec does not ship a binary (risk R4) and a suite that
// required one would be a suite nobody can run.
//
// Build it with `tool/build_native.sh`, or point AUDIO_AEC_LIBRARY at an
// existing library, and this group runs.

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:test/test.dart';

void main() {
  final String? libraryPath = _resolveLibrary();
  final String? skipReason = libraryPath == null
      ? 'No native AEC library found. Build one with '
            'packages/audio_aec/tool/build_native.sh or set '
            '$aecLibraryEnvironmentVariable.'
      : null;

  group('native library', () {
    test('runtime capability requires successful engine creation', () {
      final AecRuntimeCapability capability = probeAecRuntime(
        libraryPath: libraryPath,
      );

      expect(capability.isAvailable, isTrue);
      expect(capability.version, 'webrtc-audio-processing-2.1+aec3');
      expect(capability.failure, isNull);
    });

    test('aec_version identifies the engine the ABI was derived from', () {
      final FfiAecBindings bindings = FfiAecBindings.open(
        libraryPath: libraryPath,
      );

      expect(bindings.version(), 'webrtc-audio-processing-2.1+aec3');
    });

    test('a real AEC3 instance accepts the 10 ms block contract', () {
      final AecProcessor processor = AecProcessor.create(
        libraryPath: libraryPath,
      );
      addTearDown(processor.dispose);

      expect(processor.blockFrames, 160);
      expect(processor.version, contains('aec3'));

      // One second of blocks through both paths: the point is that the native
      // instance accepts the contract and returns a same-sized block, not that
      // any particular amount of echo is removed.
      final Int16List reference = Int16List.fromList(
        List<int>.generate(160, (int index) => (index % 32) * 400 - 6000),
      );
      final Int16List capture = Int16List.fromList(
        List<int>.generate(160, (int index) => (index % 32) * 400 - 6000),
      );
      for (var block = 0; block < 100; block += 1) {
        processor.processReverse(reference);
        final Int16List cleaned = processor.processCapture(capture, 80);
        expect(cleaned, hasLength(160));
      }

      // Metrics either carry values or are honestly null; neither is a failure.
      final AecMetrics metrics = processor.metrics();
      expect(metrics.erle, anyOf(isNull, isA<double>()));
    });
  }, skip: skipReason);
}

/// Finds a native library to smoke-test, or `null` to skip.
String? _resolveLibrary() {
  final String? fromEnvironment =
      Platform.environment[aecLibraryEnvironmentVariable];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return fromEnvironment;
  }
  final String fileName = platformAecLibraryFileName();
  for (final String base in <String>[
    '.',
    'packages/audio_aec',
    '..',
    '../..',
  ]) {
    final String candidate = '$base/.native/$fileName';
    if (File(candidate).existsSync()) {
      return File(candidate).absolute.path;
    }
  }
  return null;
}
