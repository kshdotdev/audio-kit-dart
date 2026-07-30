// Prints which native library, if any, this build resolved — and how.
//
// The useful part is the "how": a library reached through a build hook and one
// reached through $AUDIO_AEC_LIBRARY behave identically at runtime, which makes
// it easy to believe the hook is working when it is not. This distinguishes
// them.
//
//   dart run bin/aecinfo.dart            # hooks run
//   dart build cli --target bin/aecinfo.dart
//   dart compile exe bin/aecinfo.dart    # FAILS: hooks are unsupported there

import 'dart:io';

import 'package:audio_aec/audio_aec.dart';

void main() {
  final NativeAssetAecBindings? asset = NativeAssetAecBindings.tryResolve();
  if (asset != null) {
    stdout.writeln('code asset (hook/build.dart): ${asset.version()}');
    return;
  }
  stdout.writeln('No code asset was registered by the build hook.');

  final String? fromEnvironment =
      Platform.environment[aecLibraryEnvironmentVariable];
  stdout.writeln(
    '$aecLibraryEnvironmentVariable=${fromEnvironment ?? '(unset)'}',
  );
  try {
    final FfiAecBindings bindings = FfiAecBindings.open();
    stdout.writeln('fell back to the path loader: ${bindings.version()}');
  } on AecUnavailable catch (error) {
    stdout.writeln(error.toString());
    exitCode = 1;
  }
}
