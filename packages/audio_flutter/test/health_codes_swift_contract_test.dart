import 'dart:io';

import 'package:audio_flutter/audio_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The health-code constants are only worth having if they provably match
/// the strings the darwin implementation emits: a rename on either side must
/// fail here, not silently orphan a host's handler.
void main() {
  late String swiftSources;

  setUpAll(() {
    // Test runners differ on the working directory (the package when run
    // directly, the repo root under tool/verify.sh), so probe both.
    const sourcesPath =
        'audio_flutter_darwin/darwin/audio_flutter_darwin/Sources/'
        'audio_flutter_darwin';
    final darwinSources =
        [
          Directory('../$sourcesPath'),
          Directory('packages/$sourcesPath'),
        ].firstWhere(
          (candidate) => candidate.existsSync(),
          orElse: () => Directory('../$sourcesPath'),
        );
    expect(
      darwinSources.existsSync(),
      isTrue,
      reason:
          'the contract test needs the sibling darwin package checkout at '
          '${darwinSources.path}',
    );
    swiftSources = darwinSources
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.swift'))
        .map((file) => file.readAsStringSync())
        .join('\n');
  });

  test('every constant appears verbatim in the darwin Swift sources', () {
    for (final code in AudioCaptureHealthCodes.all) {
      expect(
        swiftSources.contains('"$code"'),
        isTrue,
        reason:
            'AudioCaptureHealthCodes declares "$code" but no darwin Swift '
            'source emits it — the contract has drifted',
      );
    }
  });

  test('the all list carries no duplicates', () {
    expect(
      AudioCaptureHealthCodes.all.toSet().length,
      AudioCaptureHealthCodes.all.length,
    );
  });
}
