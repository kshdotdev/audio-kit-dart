import 'package:audio_aec/audio_aec.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('probeAecBindings', () {
    test('creates and destroys one real-capability handle', () {
      final bindings = FakeAecBindings(
        versionString: 'webrtc-audio-processing-2.1+aec3',
      );

      final capability = probeAecBindings(bindings);

      expect(capability.isAvailable, isTrue);
      expect(capability.version, 'webrtc-audio-processing-2.1+aec3');
      expect(capability.failure, isNull);
      expect(bindings.createCalls, [(sampleRate: 16000, channels: 1)]);
      expect(bindings.destroyCount, 1);
      expect(bindings.calls, ['create', 'version', 'destroy']);
    });

    test('does not claim a library whose engine refuses creation', () {
      final bindings = FakeAecBindings(createReturnsNull: true);

      final capability = probeAecBindings(bindings);

      expect(capability.isAvailable, isFalse);
      expect(capability.failure?.message, contains('aec_create returned null'));
      expect(bindings.destroyCount, 0);
      expect(bindings.calls, ['create']);
    });

    test('destroys the temporary handle when the version call fails', () {
      final bindings = FakeAecBindings(
        versionError: StateError('incompatible version symbol'),
      );

      final capability = probeAecBindings(bindings);

      expect(capability.isAvailable, isFalse);
      expect(
        capability.failure?.cause,
        contains('incompatible version symbol'),
      );
      expect(bindings.destroyCount, 1);
      expect(bindings.calls, ['create', 'version', 'destroy']);
    });

    test('rejects unsupported probe formats before native creation', () {
      final bindings = FakeAecBindings();

      expect(
        () => probeAecBindings(bindings, channels: 2),
        throwsArgumentError,
      );
      expect(
        () => probeAecBindings(bindings, sampleRate: 44100),
        throwsArgumentError,
      );
      expect(bindings.calls, isEmpty);
    });
  });
}
