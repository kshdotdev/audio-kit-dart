import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unsupported implementation reports platform capabilities safely',
    () async {
      expect(
        await AudioFlutterPlatform.instance.isSystemAudioCaptureSupported(),
        isFalse,
      );
      expect(
        await AudioFlutterPlatform.instance.listAudioInputDevices(),
        isEmpty,
      );
      expect(await AudioFlutterPlatform.instance.listAudioProcesses(), isEmpty);
      final PlatformCaptureBackendInfo backend = await AudioFlutterPlatform
          .instance
          .captureBackendInfo();
      expect(backend.backendId, 'audio_flutter.unsupported');
      expect(backend.sourceKinds, isEmpty);
      expect(await AudioFlutterPlatform.instance.listCaptureSources(), isEmpty);
      expect(
        () => AudioFlutterPlatform.instance.prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.microphone,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          ),
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'capabilities added after 0.1.0 stay optional for implementations',
    () async {
      // A platform package written against the older contract inherits these
      // rather than failing to compile, so callers must treat the throw as
      // "this platform has no such gate" and not as a denial.
      expect(
        AudioFlutterPlatform.instance.microphonePermissionStatus,
        throwsUnimplementedError,
      );
      expect(
        AudioFlutterPlatform.instance.requestMicrophonePermission,
        throwsUnimplementedError,
      );
      expect(
        AudioFlutterPlatform.instance.cleanupOrphanedCaptureDevices,
        throwsUnimplementedError,
      );
    },
  );

  test('capture requests carry application identity beside process IDs', () {
    const PlatformCaptureRequest processOnly = PlatformCaptureRequest(
      kind: PlatformCaptureKind.systemAudio,
      outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
      processIds: <int>[42],
    );
    const PlatformCaptureRequest identified = PlatformCaptureRequest(
      kind: PlatformCaptureKind.systemAudio,
      outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
      bundleIds: <String>['com.example.meeting'],
    );

    // A request written against the older contract still means what it meant:
    // no identities, so the process list alone decides what is captured.
    expect(processOnly.bundleIds, isEmpty);
    expect(identified.processIds, isEmpty);
    expect(identified.bundleIds, <String>['com.example.meeting']);
  });

  test('platform frames report continuity only when it broke', () {
    final PlatformAudioFrame continuous = PlatformAudioFrame(
      sessionId: 1,
      sequence: 0,
      sampleOffset: 0,
      timestamp: Duration.zero,
      samples: Float32List(1),
    );
    final PlatformAudioFrame restarted = PlatformAudioFrame(
      sessionId: 1,
      sequence: 1,
      sampleOffset: 1,
      timestamp: const Duration(milliseconds: 100),
      samples: Float32List(1),
      discontinuityReason: PlatformAudioDiscontinuityReason.sourceRestart,
    );

    expect(continuous.discontinuityReason, isNull);
    expect(continuous.droppedFramesBefore, 0);
    expect(
      restarted.discontinuityReason,
      PlatformAudioDiscontinuityReason.sourceRestart,
    );
  });

  test('platform PCM format has value semantics', () {
    expect(
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );
  });
}
