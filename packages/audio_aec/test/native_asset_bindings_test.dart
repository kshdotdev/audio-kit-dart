// Contract tests for the code-asset binding that do NOT require a code asset.
//
// The end-to-end proof that a hook-registered asset actually loads lives in
// `example/`, which is a separate package precisely because it needs a
// workspace root of its own to carry the user-defines. What is testable here is
// the part that must hold whether or not an asset exists: probing is honest and
// side-effect free, and an explicit library path still wins.

import 'package:audio_aec/audio_aec.dart';
import 'package:test/test.dart';

void main() {
  group('NativeAssetAecBindings.tryResolve', () {
    test('agrees with available, and is stable across calls', () {
      // Deliberately environment-agnostic: this suite runs both with and
      // without an asset registered, depending on the consumer's user-defines,
      // and neither is a failure. What must never happen is the two disagreeing
      // or the answer changing under repetition — either would mean the probe
      // has a side effect.
      final NativeAssetAecBindings? first = NativeAssetAecBindings.tryResolve();
      final NativeAssetAecBindings? second =
          NativeAssetAecBindings.tryResolve();

      expect(NativeAssetAecBindings.available, first != null);
      expect(second != null, first != null);
    });

    test('never throws, however the asset resolves', () {
      // The whole point of the probe: an absent asset surfaces as an
      // ArgumentError from the FFI resolver on first call, and swallowing it is
      // what lets AecProcessor.create() fall through to the path loader. A
      // throwing probe would take the fallback down with it.
      expect(NativeAssetAecBindings.tryResolve, returnsNormally);
    });

    test('reports a version when it resolves at all', () {
      final NativeAssetAecBindings? bindings =
          NativeAssetAecBindings.tryResolve();
      if (bindings == null) {
        return;
      }
      expect(bindings.version(), contains('aec3'));
    });
  });

  group('resolution precedence', () {
    test('an explicit libraryPath bypasses the code asset entirely', () {
      // The contract is that a non-null libraryPath makes create() delegate
      // straight to the path loader, so the code asset can never be silently
      // substituted for the library a caller named.
      //
      // Asserted as an equivalence rather than as "it throws", because
      // FfiAecBindings.open does NOT stop at libraryPath — it appends the
      // conventional candidates and the bare file name, and a bare name can
      // resolve an image already loaded into this process (see the note on
      // FfiAecBindings.openFrom). Whether that happens depends on what else ran
      // first in this suite. Comparing the two calls is immune to that: both
      // see the same candidate list, so they must agree either way.
      const String missing = '/nonexistent/libaec_ffi.dylib';

      Object? outcomeOf(void Function() call) {
        try {
          call();
          return null;
        } on Object catch (error) {
          return error.runtimeType;
        }
      }

      expect(
        outcomeOf(() => AecProcessor.create(libraryPath: missing).dispose()),
        outcomeOf(() => FfiAecBindings.open(libraryPath: missing)),
      );
    });

    test('the documented candidate order is unchanged by the hook', () {
      // Steps 3-5 of the README's resolution order are what a consumer who
      // ignores build hooks relies on. Nothing in this work may reorder them.
      final List<String> candidates = aecLibraryCandidates(
        libraryPath: '/explicit/lib.dylib',
        environment: <String, String>{
          aecLibraryEnvironmentVariable: '/from/env.dylib',
        },
      );

      expect(candidates.first, '/explicit/lib.dylib');
      expect(candidates[1], '/from/env.dylib');
      expect(candidates.last, platformAecLibraryFileName());
    });
  });
}
