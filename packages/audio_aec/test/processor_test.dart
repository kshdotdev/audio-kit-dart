import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('AecProcessor construction', () {
    test('creates the native instance for the requested format', () {
      final FakeAecBindings bindings = FakeAecBindings();
      final AecProcessor processor = AecProcessor.fromBindings(bindings);

      expect(bindings.createCalls, <({int sampleRate, int channels})>[
        (sampleRate: 16000, channels: 1),
      ]);
      expect(processor.sampleRate, 16000);
      expect(processor.blockFrames, kAecBlockFrames);
      expect(processor.blockFrames, 160);

      processor.dispose();
    });

    test('a null handle becomes AecUnavailable, not a silent no-op', () {
      expect(
        () =>
            AecProcessor.fromBindings(FakeAecBindings(createReturnsNull: true)),
        throwsA(isA<AecUnavailable>()),
      );
    });

    test('rejects a rate WebRTC AudioProcessing does not support', () {
      expect(
        () => AecProcessor.fromBindings(FakeAecBindings(), sampleRate: 44100),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects multichannel: the AEC path is mono end to end', () {
      expect(
        () => AecProcessor.fromBindings(FakeAecBindings(), channels: 2),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('block size follows the sample rate at 10 ms', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(),
        sampleRate: 48000,
      );

      expect(processor.blockFrames, 480);
      processor.dispose();
    });

    test('exposes the engine version string', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(versionString: 'webrtc-audio-processing-2.1+aec3'),
      );

      expect(processor.version, 'webrtc-audio-processing-2.1+aec3');
      processor.dispose();
    });
  });

  group('AecProcessor block contract', () {
    late FakeAecBindings bindings;
    late AecProcessor processor;

    setUp(() {
      bindings = FakeAecBindings();
      processor = AecProcessor.fromBindings(bindings);
    });

    tearDown(() => processor.dispose());

    test('rejects a short capture block instead of reading stale scratch', () {
      expect(
        () => processor.processCapture(Int16List(159), 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(bindings.calls, isNot(contains('capture')));
    });

    test('rejects an oversized capture block', () {
      expect(
        () => processor.processCapture(Int16List(320), 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a wrong-sized reverse block', () {
      expect(
        () => processor.processReverse(Int16List(80)),
        throwsA(isA<ArgumentError>()),
      );
      expect(bindings.calls, isNot(contains('reverse')));
    });

    test('passes exactly 160 samples to the native side', () {
      processor
        ..processReverse(Int16List(160))
        ..processCapture(Int16List(160), 0);

      expect(bindings.frameCounts, <int>[160, 160]);
    });
  });

  group('AecProcessor marshalling', () {
    test('subtracts the far-end reference the fake was fed', () {
      final FakeAecBindings bindings = FakeAecBindings();
      final AecProcessor processor = AecProcessor.fromBindings(bindings);
      final Int16List echo = Int16List.fromList(
        List<int>.generate(160, (int index) => 100 + index),
      );
      final Int16List speech = Int16List.fromList(
        List<int>.generate(160, (int index) => index * 3),
      );
      final Int16List microphone = Int16List.fromList(
        List<int>.generate(160, (int index) => speech[index] + echo[index]),
      );

      processor.processReverse(echo);
      final Int16List cleaned = processor.processCapture(microphone, 42);

      expect(cleaned, speech);
      expect(bindings.streamDelays, <int>[42]);
      processor.dispose();
    });

    test('each cleaned block is a fresh copy, not the reused scratch', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(),
      );

      final Int16List first = processor.processCapture(
        Int16List.fromList(List<int>.filled(160, 7)),
        0,
      );
      final Int16List second = processor.processCapture(
        Int16List.fromList(List<int>.filled(160, 9)),
        0,
      );

      expect(first.first, 7, reason: 'the second call overwrote the first');
      expect(second.first, 9);
      expect(identical(first, second), isFalse);
      processor.dispose();
    });

    test('does not mutate the caller\'s input block', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(),
      );
      final Int16List microphone = Int16List.fromList(
        List<int>.filled(160, 500),
      );

      processor
        ..processReverse(Int16List.fromList(List<int>.filled(160, 200)))
        ..processCapture(microphone, 0);

      expect(microphone.every((int value) => value == 500), isTrue);
      processor.dispose();
    });
  });

  group('AecProcessor metrics', () {
    test('maps the native sentinels to null', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(),
      );

      final AecMetrics metrics = processor.metrics();

      expect(metrics.erl, isNull);
      expect(metrics.erle, isNull);
      expect(metrics.residual, isNull);
      expect(metrics.delayMs, isNull);
      processor.dispose();
    });

    test('reports real values once the engine has them', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(erl: 12.5, erle: 8.25, residual: 0.125, delayMs: 90),
      );

      final AecMetrics metrics = processor.metrics();

      expect(metrics.erl, 12.5);
      expect(metrics.erle, 8.25);
      expect(metrics.residual, 0.125);
      expect(metrics.delayMs, 90);
      processor.dispose();
    });
  });

  group('AecProcessor disposal', () {
    test('destroys the native instance exactly once', () {
      final FakeAecBindings bindings = FakeAecBindings();
      final AecProcessor processor = AecProcessor.fromBindings(bindings)
        ..dispose()
        ..dispose();

      expect(bindings.destroyCount, 1);
      expect(processor.isDisposed, isTrue);
    });

    test('destroy is the last native call: nothing runs after the free', () {
      final FakeAecBindings bindings = FakeAecBindings();
      final AecProcessor processor = AecProcessor.fromBindings(bindings)
        ..processReverse(Int16List(160))
        ..processCapture(Int16List(160), 0)
        ..dispose();

      // Calls after disposal must not reach the freed handle.
      processor
        ..processReverse(Int16List(160))
        ..processCapture(Int16List(160), 0)
        ..metrics();

      expect(bindings.calls.last, 'destroy');
      expect(bindings.calls, <String>[
        'create',
        'reverse',
        'capture',
        'destroy',
      ]);
    });

    test('metrics after disposal are empty rather than a native read', () {
      final AecProcessor processor = AecProcessor.fromBindings(
        FakeAecBindings(erle: 9),
      )..dispose();

      expect(processor.metrics().erle, isNull);
    });
  });
}
