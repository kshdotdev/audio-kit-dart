import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const PlatformCaptureSessionInfo captureInfo = PlatformCaptureSessionInfo(
    sessionId: 7,
    sourceId: 'microphone-7',
    trackId: 'microphone',
    clockId: 'clock-7',
    format: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
  );
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  FlutterAudioCaptureSource source(
    _FakePermissionPlatform platform, {
    AudioCaptureType type = AudioCaptureType.microphone,
  }) => FlutterAudioCaptureSource(
    FlutterAudioCaptureConfig(type: type, format: format),
    platform: platform,
  );

  group('microphone permission', () {
    test('denied microphone access fails prepare with a typed code', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..permission = PlatformMicrophonePermissionStatus.denied;
      addTearDown(platform.close);

      await expectLater(
        source(platform).prepare(),
        throwsA(
          isA<AudioFailure>()
              .having(
                (AudioFailure failure) => failure.code,
                'code',
                'microphone_permission_denied',
              )
              .having(
                (AudioFailure failure) => failure.stage,
                'stage',
                AudioFailureStage.capture,
              )
              .having(
                (AudioFailure failure) => failure.retryable,
                'retryable',
                isFalse,
              ),
        ),
      );
      expect(platform.prepareCaptureCalls, 0);
    });

    test('restricted microphone access fails prepare as well', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..permission = PlatformMicrophonePermissionStatus.restricted;
      addTearDown(platform.close);

      await expectLater(
        source(platform).prepare(),
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'microphone_permission_denied',
          ),
        ),
      );
    });

    test('an undetermined status still reaches the system prompt', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..permission = PlatformMicrophonePermissionStatus.notDetermined;
      addTearDown(platform.close);

      final FlutterAudioCaptureSession session = await source(
        platform,
      ).prepare();

      expect(platform.prepareCaptureCalls, 1);
      await session.close();
    });

    test('a platform without a permission API is never blocked', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..permissionSupported = false;
      addTearDown(platform.close);

      final FlutterAudioCaptureSession session = await source(
        platform,
      ).prepare();

      expect(platform.prepareCaptureCalls, 1);
      await session.close();
      expect(
        await FlutterMicrophonePermission(platform: platform).status(),
        AudioMicrophonePermissionStatus.unavailable,
      );
    });

    test('system-audio capture is not gated by the microphone', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        const PlatformCaptureSessionInfo(
          sessionId: 7,
          sourceId: 'system-7',
          trackId: 'system',
          clockId: 'clock-7',
          format: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
        ),
      )..permission = PlatformMicrophonePermissionStatus.denied;
      addTearDown(platform.close);

      final FlutterAudioCaptureSession session = await source(
        platform,
        type: AudioCaptureType.systemAudio,
      ).prepare();

      expect(platform.prepareCaptureCalls, 1);
      await session.close();
    });

    test('requesting reports the resulting status', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..permission = PlatformMicrophonePermissionStatus.notDetermined;
      addTearDown(platform.close);
      final FlutterMicrophonePermission permission =
          FlutterMicrophonePermission(platform: platform);

      expect(
        await permission.status(),
        AudioMicrophonePermissionStatus.notDetermined,
      );
      expect(
        await permission.request(),
        AudioMicrophonePermissionStatus.granted,
      );
      expect(platform.requestPermissionCalls, 1);
      expect(
        await permission.status(),
        AudioMicrophonePermissionStatus.granted,
      );
    });

    test('only denied and restricted block a capture', () {
      expect(AudioMicrophonePermissionStatus.denied.blocksCapture, isTrue);
      expect(AudioMicrophonePermissionStatus.restricted.blocksCapture, isTrue);
      expect(AudioMicrophonePermissionStatus.granted.blocksCapture, isFalse);
      expect(
        AudioMicrophonePermissionStatus.notDetermined.blocksCapture,
        isFalse,
      );
      expect(
        AudioMicrophonePermissionStatus.unavailable.blocksCapture,
        isFalse,
      );
    });
  });

  group('orphaned capture devices', () {
    test('cleanup reports how many devices were reclaimed', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..orphanedDevices = 3;
      addTearDown(platform.close);

      expect(
        await FlutterSystemAudio(
          platform: platform,
        ).cleanupOrphanedCaptureDevices(),
        3,
      );
    });

    test('a platform without the sweep reclaims nothing', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      )..cleanupSupported = false;
      addTearDown(platform.close);

      expect(
        await FlutterSystemAudio(
          platform: platform,
        ).cleanupOrphanedCaptureDevices(),
        0,
      );
    });
  });

  group('capture health and continuity', () {
    test('widened native statistics reach the health stream', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      );
      addTearDown(platform.close);
      final FlutterAudioCaptureSession session = await source(
        platform,
      ).prepare();
      final List<FlutterAudioCaptureHealth> health =
          <FlutterAudioCaptureHealth>[];
      final StreamSubscription<FlutterAudioCaptureHealth> subscription = session
          .health
          .listen(health.add);

      platform.events.add(
        const PlatformAudioSessionEvent(
          sessionId: 7,
          phase: PlatformAudioSessionPhase.running,
          receivingAudio: true,
          callbackCount: 40,
          peakAmplitude: 0.42,
          rms: 0.08,
          nonZeroFramePercent: 97.5,
          renderCycles: 41,
          firstAudioAtMillis: 120,
        ),
      );
      await _eventually(
        () => health.any(
          (FlutterAudioCaptureHealth event) =>
              event.phase == FlutterAudioCaptureHealthPhase.running,
        ),
      );

      final FlutterAudioCaptureHealth running = health.lastWhere(
        (FlutterAudioCaptureHealth event) =>
            event.phase == FlutterAudioCaptureHealthPhase.running,
      );
      expect(running.peakAmplitude, 0.42);
      expect(running.rms, 0.08);
      expect(running.nonZeroFramePercent, 97.5);
      expect(running.renderCycles, 41);
      expect(running.firstAudioAtMillis, 120);
      await subscription.cancel();
      await session.close();
    });

    test('a native source restart is reported as sourceRestart', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      );
      addTearDown(platform.close);
      final FlutterAudioCaptureSession session = await source(
        platform,
      ).prepare();
      final Future<AudioFrame> next = session.frames.first;
      platform.captureBatches.add(
        PlatformAudioFrameBatch(
          frames: <PlatformAudioFrame>[
            PlatformAudioFrame(
              sessionId: 7,
              sequence: 9,
              sampleOffset: 14400,
              timestamp: const Duration(milliseconds: 900),
              samples: Float32List.fromList(<double>[0.2]),
              droppedFramesBefore: 2,
              discontinuityReason:
                  PlatformAudioDiscontinuityReason.sourceRestart,
            ),
          ],
          endOfStream: true,
        ),
      );

      await session.start();
      final AudioFrame frame = await next;

      expect(
        frame.discontinuity?.reason,
        AudioDiscontinuityReason.sourceRestart,
      );
      expect(frame.discontinuity?.droppedFrameCount, 2);
      expect(frame.discontinuity?.previousSequence, 6);
      await session.close();
    });

    test('a reason without dropped frames still breaks continuity', () async {
      final _FakePermissionPlatform platform = _FakePermissionPlatform(
        captureInfo,
      );
      addTearDown(platform.close);
      final FlutterAudioCaptureSession session = await source(
        platform,
      ).prepare();
      final Future<AudioFrame> next = session.frames.first;
      platform.captureBatches.add(
        PlatformAudioFrameBatch(
          frames: <PlatformAudioFrame>[
            PlatformAudioFrame(
              sessionId: 7,
              sequence: 3,
              sampleOffset: 4800,
              timestamp: const Duration(milliseconds: 300),
              samples: Float32List.fromList(<double>[0.1]),
              discontinuityReason: PlatformAudioDiscontinuityReason.clockReset,
            ),
          ],
          endOfStream: true,
        ),
      );

      await session.start();
      final AudioFrame frame = await next;

      expect(frame.discontinuity?.reason, AudioDiscontinuityReason.clockReset);
      expect(frame.discontinuity?.droppedFrameCount, 0);
      await session.close();
    });
  });
}

Future<void> _eventually(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > timeout) {
      fail('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// A platform that answers the capture-correctness surface and nothing else.
final class _FakePermissionPlatform extends AudioFlutterPlatform {
  _FakePermissionPlatform(this.captureInfo);

  final PlatformCaptureSessionInfo captureInfo;
  final Queue<PlatformAudioFrameBatch> captureBatches =
      Queue<PlatformAudioFrameBatch>();
  final StreamController<PlatformAudioSessionEvent> events =
      StreamController<PlatformAudioSessionEvent>.broadcast();
  Completer<PlatformAudioFrameBatch>? _pendingRead;

  PlatformMicrophonePermissionStatus permission =
      PlatformMicrophonePermissionStatus.granted;

  /// False models a federated platform endorsed before the API existed.
  bool permissionSupported = true;
  bool cleanupSupported = true;
  int orphanedDevices = 0;
  int prepareCaptureCalls = 0;
  int requestPermissionCalls = 0;

  Future<void> close() => events.close();

  @override
  Future<PlatformMicrophonePermissionStatus>
  microphonePermissionStatus() async {
    if (!permissionSupported) {
      return super.microphonePermissionStatus();
    }
    return permission;
  }

  @override
  Future<PlatformMicrophonePermissionStatus>
  requestMicrophonePermission() async {
    requestPermissionCalls += 1;
    if (!permissionSupported) {
      return super.requestMicrophonePermission();
    }
    if (permission == PlatformMicrophonePermissionStatus.notDetermined) {
      permission = PlatformMicrophonePermissionStatus.granted;
    }
    return permission;
  }

  @override
  Future<int> cleanupOrphanedCaptureDevices() async {
    if (!cleanupSupported) {
      return super.cleanupOrphanedCaptureDevices();
    }
    return orphanedDevices;
  }

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    prepareCaptureCalls += 1;
    return captureInfo;
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) => events
      .stream
      .where((PlatformAudioSessionEvent event) => event.sessionId == sessionId);

  @override
  Future<void> startCapture(int sessionId) async {}

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    if (captureBatches.isNotEmpty) {
      return captureBatches.removeFirst();
    }
    final Completer<PlatformAudioFrameBatch> completer =
        Completer<PlatformAudioFrameBatch>();
    _pendingRead = completer;
    return completer.future;
  }

  @override
  Future<void> stopCapture(int sessionId) async => _completeRead();

  @override
  Future<void> abortCapture(int sessionId) async => _completeRead();

  void _completeRead() {
    final Completer<PlatformAudioFrameBatch>? pending = _pendingRead;
    _pendingRead = null;
    const PlatformAudioFrameBatch batch = PlatformAudioFrameBatch(
      frames: <PlatformAudioFrame>[],
      endOfStream: true,
    );
    if (pending == null) {
      captureBatches.add(batch);
    } else if (!pending.isCompleted) {
      pending.complete(batch);
    }
  }

  @override
  Future<void> disposeCapture(int sessionId) async {}

  @override
  Future<bool> isSystemAudioCaptureSupported() async => true;

  @override
  Future<bool> requestSystemAudioCapturePermission() async => true;

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async =>
      const <PlatformAudioInputDevice>[];

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async =>
      const <PlatformAudioProcess>[];

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async => PlatformPlaybackSessionInfo(
    sessionId: 11,
    clockId: 'playback-11',
    format: request.inputFormat,
  );

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) => events
      .stream
      .where((PlatformAudioSessionEvent event) => event.sessionId == sessionId);

  @override
  Future<void> startPlayback(int sessionId) async {}

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) async {}

  @override
  Future<void> finishPlayback(int sessionId) async {}

  @override
  Future<void> abortPlayback(int sessionId) async {}

  @override
  Future<void> disposePlayback(int sessionId) async {}
}
