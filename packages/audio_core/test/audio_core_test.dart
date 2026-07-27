import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  group('AudioFormat', () {
    test('validates dimensions and converts timeline units', () {
      final format = AudioFormat(sampleRate: 48000, channels: 2);

      expect(format.bytesPerFrame, 8);
      expect(format.durationForFrames(480), const Duration(milliseconds: 10));
      expect(format.framesForDuration(const Duration(milliseconds: 10)), 480);
      expect(format, AudioFormat(sampleRate: 48000, channels: 2));
      expect(
        () => AudioFormat(sampleRate: 0, channels: 1),
        throwsArgumentError,
      );
      expect(
        () => AudioFormat(sampleRate: 48000, channels: 0),
        throwsArgumentError,
      );
    });
  });

  group('AudioFrame', () {
    final format = AudioFormat(sampleRate: 16000, channels: 2);

    test('copies input by default and exposes timeline helpers', () {
      final input = Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]);
      final frame = AudioFrame(
        format: format,
        samples: input,
        sourceId: 'microphone',
        trackId: 'primary',
        clockId: 'host-time',
        sequence: 4,
        sampleOffset: 20,
        timestamp: const Duration(milliseconds: 5),
      );
      input[0] = 1;

      expect(frame.samples[0], closeTo(0.1, 1e-6));
      expect(frame.frameCount, 2);
      expect(frame.endSampleOffset, 22);
      expect(frame.duration, const Duration(microseconds: 125));
    });

    test('owned constructor preserves the transferred buffer', () {
      final input = Float32List.fromList(<double>[0, 0, 1, 1]);
      final frame = AudioFrame.owned(
        format: format,
        samples: input,
        sourceId: 'source',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
      );

      expect(identical(frame.samples, input), isTrue);
    });

    test('validates identifiers, shape, and nonnegative timeline values', () {
      AudioFrame build({
        Float32List? samples,
        String sourceId = 'source',
        int sequence = 0,
        int sampleOffset = 0,
        Duration timestamp = Duration.zero,
      }) => AudioFrame(
        format: format,
        samples: samples ?? Float32List(2),
        sourceId: sourceId,
        trackId: 'track',
        clockId: 'clock',
        sequence: sequence,
        sampleOffset: sampleOffset,
        timestamp: timestamp,
      );

      expect(() => build(samples: Float32List(3)), throwsArgumentError);
      expect(() => build(sourceId: ' '), throwsArgumentError);
      expect(() => build(sequence: -1), throwsArgumentError);
      expect(() => build(sampleOffset: -1), throwsArgumentError);
      expect(
        () => build(timestamp: const Duration(microseconds: -1)),
        throwsArgumentError,
      );
    });

    test('copyWith creates an independent PCM buffer', () {
      final original = AudioFrame(
        format: format,
        samples: Float32List.fromList(<double>[0.25, -0.25]),
        sourceId: 'source',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
        discontinuity: AudioDiscontinuity(
          reason: AudioDiscontinuityReason.sourceRestart,
        ),
      );
      final copy = original.copyWith(sequence: 1, clearDiscontinuity: true);

      expect(copy.sequence, 1);
      expect(copy.discontinuity, isNull);
      expect(copy.samples, orderedEquals(original.samples));
      expect(identical(copy.samples, original.samples), isFalse);
    });
  });

  group('AudioCancellationController', () {
    test('cancels once and exposes the same typed reason', () async {
      final controller = AudioCancellationController();
      const cancellation = AudioCancellation(reason: 'superseded');

      controller.cancel(cancellation);
      controller.cancel(const AudioCancellation(reason: 'ignored'));

      expect(controller.isCancelled, isTrue);
      expect(controller.token.isCancelled, isTrue);
      expect(await controller.token.whenCancelled, same(cancellation));
      expect(
        controller.token.throwIfCancelled,
        throwsA(
          isA<AudioCancelledException>().having(
            (error) => error.cancellation.reason,
            'reason',
            'superseded',
          ),
        ),
      );
    });

    test('disposable registrations release long-lived token observers', () {
      final controller = AudioCancellationController();
      var notifications = 0;
      final AudioCancellationRegistration registration = controller.token
          .register((AudioCancellation _) => notifications += 1);

      expect(controller.activeRegistrationCount, 1);
      expect(registration.isDisposed, isFalse);

      registration.dispose();
      registration.dispose();
      expect(controller.activeRegistrationCount, 0);
      expect(registration.isDisposed, isTrue);

      controller.cancel();
      expect(notifications, 0);
    });

    test('cancellation notifies and disposes every registration once', () {
      final controller = AudioCancellationController();
      final List<String> notifications = <String>[];
      final AudioCancellationRegistration first = controller.token.register(
        (AudioCancellation value) => notifications.add('first:${value.reason}'),
      );
      final AudioCancellationRegistration second = controller.token.register(
        (AudioCancellation value) =>
            notifications.add('second:${value.reason}'),
      );

      controller.cancel(const AudioCancellation(reason: 'stopped'));
      controller.cancel(const AudioCancellation(reason: 'ignored'));

      expect(notifications, <String>['first:stopped', 'second:stopped']);
      expect(controller.activeRegistrationCount, 0);
      expect(first.isDisposed, isTrue);
      expect(second.isDisposed, isTrue);
    });

    test('throwing registration is isolated from cancellation state', () {
      final controller = AudioCancellationController();
      var healthyNotifications = 0;
      controller.token.register(
        (AudioCancellation _) => throw StateError('observer failed'),
      );
      controller.token.register(
        (AudioCancellation _) => healthyNotifications += 1,
      );

      expect(controller.cancel, returnsNormally);
      expect(controller.isCancelled, isTrue);
      expect(controller.token.isCancelled, isTrue);
      expect(healthyNotifications, 1);
      expect(controller.activeRegistrationCount, 0);
    });

    test('registration after cancellation is notified without retention', () {
      final controller = AudioCancellationController()
        ..cancel(const AudioCancellation(reason: 'already-stopped'));
      AudioCancellation? observed;

      final AudioCancellationRegistration registration = controller.token
          .register((AudioCancellation value) => observed = value);

      expect(observed?.reason, 'already-stopped');
      expect(registration.isDisposed, isTrue);
      expect(controller.activeRegistrationCount, 0);
    });
  });

  test('AudioFailure string contains only structured safe fields', () {
    final failure = AudioFailure(
      code: 'device_lost',
      stage: AudioFailureStage.capture,
      message: 'The input device disconnected.',
      providerId: 'darwin',
      retryable: true,
      safeCause: 'AVAudioEngine stopped',
    );

    expect(failure.toString(), contains('device_lost'));
    expect(failure.toString(), contains('providerId: darwin'));
    expect(failure.toString(), contains('AVAudioEngine stopped'));
  });

  test('AudioSessionStatus identifies every terminal lifecycle', () {
    for (final state in AudioSessionState.values) {
      final status = AudioSessionStatus(state: state, timestamp: Duration.zero);
      expect(
        status.isTerminal,
        <AudioSessionState>{
          AudioSessionState.finished,
          AudioSessionState.aborted,
          AudioSessionState.failed,
          AudioSessionState.closed,
        }.contains(state),
      );
    }
  });
}
