import 'dart:io';

import 'package:audio_aec/audio_aec.dart';
import 'package:test/test.dart';

void main() {
  group('aecLibraryCandidates', () {
    test('tries an explicit path before anything else', () {
      final List<String> candidates = aecLibraryCandidates(
        libraryPath: '/opt/explicit/libaec_ffi.dylib',
        environment: <String, String>{
          aecLibraryEnvironmentVariable: '/opt/from-env/libaec_ffi.dylib',
        },
      );

      expect(candidates.first, '/opt/explicit/libaec_ffi.dylib');
      expect(candidates[1], '/opt/from-env/libaec_ffi.dylib');
    });

    test('falls back to the environment variable when no path is given', () {
      final List<String> candidates = aecLibraryCandidates(
        environment: <String, String>{
          aecLibraryEnvironmentVariable: '/opt/from-env/libaec_ffi.dylib',
        },
      );

      expect(candidates.first, '/opt/from-env/libaec_ffi.dylib');
    });

    test('ends with the bare platform file name for the OS search path', () {
      final List<String> candidates = aecLibraryCandidates(
        environment: const <String, String>{},
      );

      expect(candidates.last, platformAecLibraryFileName());
      expect(candidates.length, greaterThan(1));
    });

    test('offers a location beside the running executable', () {
      final String executableDirectory = File(
        Platform.resolvedExecutable,
      ).parent.path;
      final List<String> candidates = aecLibraryCandidates(
        environment: const <String, String>{},
      );

      expect(
        candidates.any(
          (String path) =>
              path.startsWith(executableDirectory) &&
              path.endsWith(platformAecLibraryFileName()),
        ),
        isTrue,
        reason: 'candidates: $candidates',
      );
    });

    test('does not repeat a candidate that two rungs both produce', () {
      final String name = platformAecLibraryFileName();
      final List<String> candidates = aecLibraryCandidates(
        libraryPath: name,
        environment: <String, String>{aecLibraryEnvironmentVariable: name},
      );

      expect(candidates.where((String path) => path == name).length, 1);
    });

    test('ignores an empty environment value rather than probing ""', () {
      final List<String> candidates = aecLibraryCandidates(
        environment: <String, String>{aecLibraryEnvironmentVariable: ''},
      );

      expect(candidates, isNot(contains('')));
    });
  });

  group('platformAecLibraryFileName', () {
    test('uses the conventional name for this platform', () {
      final String name = platformAecLibraryFileName();
      if (Platform.isMacOS) {
        expect(name, 'libaec_ffi.dylib');
      } else if (Platform.isWindows) {
        expect(name, 'aec_ffi.dll');
      } else {
        expect(name, 'libaec_ffi.so');
      }
    });
  });

  group('FfiAecBindings loading', () {
    // These use openFrom so every candidate is bogus. Going through `open`
    // would leave the bare-name rung in the list, and a bare name resolves to
    // an image the process has already loaded — which, when the native smoke
    // test runs in the same process, is the real library.
    const List<String> bogus = <String>[
      '/definitely/not/here/libaec_ffi.dylib',
      '/nor/here/libaec_ffi.dylib',
    ];

    test('throws AecUnavailable rather than crashing on a bogus path', () {
      expect(
        () => FfiAecBindings.openFrom(bogus),
        throwsA(isA<AecUnavailable>()),
      );
    });

    test('reports every path it tried, in order', () {
      AecUnavailable? failure;
      try {
        FfiAecBindings.openFrom(bogus);
      } on AecUnavailable catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure!.attemptedPaths, bogus);
      expect(failure.cause, isNotNull);
    });

    test('the message tells the caller how to supply a library', () {
      AecUnavailable? failure;
      try {
        FfiAecBindings.openFrom(bogus);
      } on AecUnavailable catch (error) {
        failure = error;
      }

      final String text = failure!.toString();
      expect(text, contains(aecLibraryEnvironmentVariable));
      expect(text, contains('build_native.sh'));
      expect(text, contains('/definitely/not/here/libaec_ffi.dylib'));
    });

    test('an empty candidate list fails the same structured way', () {
      expect(
        () => FfiAecBindings.openFrom(const <String>[]),
        throwsA(isA<AecUnavailable>()),
      );
    });
  });
}
