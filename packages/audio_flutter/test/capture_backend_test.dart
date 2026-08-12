import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test(
    'maps federated backend and source facts into the core contract',
    () async {
      final _FakeCapturePlatform platform = _FakeCapturePlatform(
        sources: <PlatformCaptureSourceInfo>[_applicationSource()],
      );
      final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
        platform: platform,
      );

      final List<CaptureSourceDescriptor> sources = await backend
          .enumerateSources();

      expect(backend.descriptor.backendId, 'test.native');
      expect(
        backend.descriptor.capabilities,
        contains(CaptureCapability.nativeMonotonicClock),
      );
      expect(sources.single.backendId, backend.descriptor.backendId);
      expect(sources.single.kind, CaptureSourceKind.application);
      expect(sources.single.processIds, <int>[42]);
      expect(sources.single.isDefault, isTrue);
    },
  );

  test('does not propose or select an unrequested fallback', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: <PlatformCaptureSourceInfo>[
        const PlatformCaptureSourceInfo(
          sourceId: 'test.application.unavailable',
          kind: PlatformCaptureSourceKind.application,
          displayName: 'Application audio',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          availabilityCode: 'process_capture_unsupported',
          availabilityReason: 'Per-process capture is unavailable.',
        ),
        const PlatformCaptureSourceInfo(
          sourceId: 'test.system-mix',
          kind: PlatformCaptureSourceKind.systemMix,
          displayName: 'System mix',
          availability: PlatformCaptureSourceAvailability.available,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
        ),
      ],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeResult result = await backend.probe(
      CaptureProbeRequest(
        requestId: 'request-no-fallback',
        sourceId: 'test.application.unavailable',
        outputFormat: format,
        fallbackPolicy: CaptureFallbackPolicy.requireExplicitConfirmation,
      ),
    );

    expect(result.status, CaptureProbeStatus.unavailable);
    expect(result.reasonCode, 'process_capture_unsupported');
    expect(result.fallback, isNull);
    expect(platform.prepareCaptureCalls, 0);
  });

  test('probe enforces platform format ranges before allocation', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: const <PlatformCaptureSourceInfo>[
        PlatformCaptureSourceInfo(
          sourceId: 'test.system-mix',
          kind: PlatformCaptureSourceKind.systemMix,
          displayName: 'System mix',
          availability: PlatformCaptureSourceAvailability.available,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          maximumSampleRate: 48000,
          maximumChannelCount: 2,
        ),
      ],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeResult result = await backend.probe(
      CaptureProbeRequest(
        requestId: 'request-format-range',
        sourceId: 'test.system-mix',
        outputFormat: AudioFormat(sampleRate: 96000, channels: 1),
      ),
    );

    expect(result.status, CaptureProbeStatus.unavailable);
    expect(result.reasonCode, 'capture_sample_rate_unsupported');
    expect(platform.prepareCaptureCalls, 0);
  });

  test(
    'rejects process filtering before native allocation when unsupported',
    () async {
      final _FakeCapturePlatform platform = _FakeCapturePlatform(
        sources: const <PlatformCaptureSourceInfo>[
          PlatformCaptureSourceInfo(
            sourceId: 'test.system-mix',
            kind: PlatformCaptureSourceKind.systemMix,
            displayName: 'System mix',
            availability: PlatformCaptureSourceAvailability.available,
            captureKind: PlatformCaptureKind.systemAudio,
            timingQuality: PlatformCaptureTimingQuality.synthesized,
          ),
        ],
      );
      final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
        platform: platform,
      );
      final CaptureProbeResult result = await backend.probe(
        CaptureProbeRequest(
          requestId: 'request-process-filter',
          sourceId: 'test.system-mix',
          outputFormat: format,
          processIds: <int>[7],
        ),
      );

      expect(result.status, CaptureProbeStatus.unavailable);
      expect(result.reasonCode, 'capture_process_filtering_unsupported');
      expect(platform.prepareCaptureCalls, 0);
    },
  );

  test('does not let process IDs retarget an application descriptor', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: <PlatformCaptureSourceInfo>[_applicationSource()],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeResult result = await backend.probe(
      CaptureProbeRequest(
        requestId: 'request-retarget',
        sourceId: 'test.application.42',
        outputFormat: format,
        processIds: <int>[99],
      ),
    );

    expect(result.status, CaptureProbeStatus.unavailable);
    expect(result.reasonCode, 'capture_process_selection_mismatch');
    expect(platform.prepareCaptureCalls, 0);
  });

  test('starts the exact probed source and exposes native timing', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: <PlatformCaptureSourceInfo>[_applicationSource()],
    );
    platform.captureBatches.add(
      PlatformAudioFrameBatch(
        frames: <PlatformAudioFrame>[
          PlatformAudioFrame(
            sessionId: 7,
            sequence: 0,
            sampleOffset: 160,
            timestamp: const Duration(seconds: 3),
            samples: Float32List.fromList(<double>[0.25]),
          ),
        ],
        endOfStream: true,
      ),
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'request-start',
      sourceId: 'test.application.42',
      outputFormat: format,
    );
    final CaptureProbeResult probe = await backend.probe(request);
    final CaptureStartRequest start = probe.authorize(request);
    final FlutterAudioCaptureSession session =
        await backend.start(start) as FlutterAudioCaptureSession;
    final Future<List<AudioFrame>> frames = session.frames.toList();

    await session.start();
    expect(await frames, hasLength(1));

    expect(platform.lastCaptureRequest?.processIds, <int>[42]);
    // The application's identity travels with its process set, so a platform
    // that taps by bundle ID keeps the app across helper respawns.
    expect(platform.lastCaptureRequest?.bundleIds, <String>[
      'com.example.meeting',
    ]);
    expect(session.sourceId, 'test.application.42');
    expect(session.timingQuality, MonotonicTrackTimingQuality.nativeMapped);
    expect(session.timing?.clockId, 'test-host-clock');
    expect(session.timing?.sessionClockId, 'test-host-clock');
    expect(session.timing?.firstSampleOffset, 160);
    expect(session.timing?.startOffset, const Duration(seconds: 3));
    expect(
      session.timing?.sessionTimestampForSample(320),
      const Duration(milliseconds: 3010),
    );

    await expectLater(backend.start(start), throwsStateError);
    await session.stop();
    await session.close();
  });

  test('a source without an application identity names no bundle', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: const <PlatformCaptureSourceInfo>[
        PlatformCaptureSourceInfo(
          sourceId: 'test.system-mix',
          kind: PlatformCaptureSourceKind.systemMix,
          displayName: 'System mix',
          availability: PlatformCaptureSourceAvailability.available,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          capabilities: <PlatformCaptureCapability>{
            PlatformCaptureCapability.systemMix,
          },
        ),
      ],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'request-system-mix',
      sourceId: 'test.system-mix',
      outputFormat: format,
    );
    final CaptureProbeResult probe = await backend.probe(request);
    final AudioSourceSession session = await backend.start(
      probe.authorize(request),
    );

    expect(platform.lastCaptureRequest?.bundleIds, isEmpty);
    expect(platform.lastCaptureRequest?.processIds, isEmpty);
    await session.close();
  });

  test('rejects a source that disappears between probe and start', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: <PlatformCaptureSourceInfo>[_applicationSource()],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
    );
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'request-disappears',
      sourceId: 'test.application.42',
      outputFormat: format,
    );
    final CaptureProbeResult probe = await backend.probe(request);
    platform.sources = const <PlatformCaptureSourceInfo>[];

    await expectLater(
      backend.start(probe.authorize(request)),
      throwsStateError,
    );
    expect(platform.prepareCaptureCalls, 0);
  });

  test('rejects an expired probe before native allocation', () async {
    final _FakeCapturePlatform platform = _FakeCapturePlatform(
      sources: <PlatformCaptureSourceInfo>[_applicationSource()],
    );
    final FlutterCaptureBackend backend = await FlutterCaptureBackend.create(
      platform: platform,
      probeLifetime: const Duration(milliseconds: 1),
    );
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'request-expired',
      sourceId: 'test.application.42',
      outputFormat: format,
    );
    final CaptureProbeResult probe = await backend.probe(request);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await expectLater(
      backend.start(probe.authorize(request)),
      throwsStateError,
    );
    expect(platform.prepareCaptureCalls, 0);
  });
}

PlatformCaptureSourceInfo _applicationSource() =>
    const PlatformCaptureSourceInfo(
      sourceId: 'test.application.42',
      kind: PlatformCaptureSourceKind.application,
      displayName: 'Meeting app',
      availability: PlatformCaptureSourceAvailability.available,
      isDefault: true,
      captureKind: PlatformCaptureKind.systemAudio,
      timingQuality: PlatformCaptureTimingQuality.nativeMapped,
      capabilities: <PlatformCaptureCapability>{
        PlatformCaptureCapability.processFiltering,
        PlatformCaptureCapability.applicationFiltering,
        PlatformCaptureCapability.nativeMonotonicClock,
      },
      processIds: <int>[42],
      applicationId: 'com.example.meeting',
    );

final class _FakeCapturePlatform extends AudioFlutterPlatform {
  _FakeCapturePlatform({required this.sources});

  List<PlatformCaptureSourceInfo> sources;
  final Queue<PlatformAudioFrameBatch> captureBatches =
      Queue<PlatformAudioFrameBatch>();
  PlatformCaptureRequest? lastCaptureRequest;
  var prepareCaptureCalls = 0;

  @override
  Future<PlatformCaptureBackendInfo> captureBackendInfo() async =>
      const PlatformCaptureBackendInfo(
        backendId: 'test.native',
        displayName: 'Test native capture',
        platform: 'test',
        sourceKinds: <PlatformCaptureSourceKind>{
          PlatformCaptureSourceKind.application,
          PlatformCaptureSourceKind.systemMix,
        },
        capabilities: <PlatformCaptureCapability>{
          PlatformCaptureCapability.processFiltering,
          PlatformCaptureCapability.nativeMonotonicClock,
        },
      );

  @override
  Future<List<PlatformCaptureSourceInfo>> listCaptureSources() async =>
      List<PlatformCaptureSourceInfo>.of(sources);

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    prepareCaptureCalls += 1;
    lastCaptureRequest = request;
    return PlatformCaptureSessionInfo(
      sessionId: 7,
      sourceId: 'native-source',
      trackId: 'them',
      clockId: 'test-host-clock',
      format: request.outputFormat,
    );
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) =>
      const Stream<PlatformAudioSessionEvent>.empty();

  @override
  Future<void> startCapture(int sessionId) async {}

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async => captureBatches.isEmpty
      ? const PlatformAudioFrameBatch(
          frames: <PlatformAudioFrame>[],
          endOfStream: true,
        )
      : captureBatches.removeFirst();

  @override
  Future<void> stopCapture(int sessionId) async {}

  @override
  Future<void> abortCapture(int sessionId) async {}

  @override
  Future<void> disposeCapture(int sessionId) async {}

  @override
  Future<bool> isSystemAudioCaptureSupported() async => true;

  @override
  Future<bool> requestSystemAudioCapturePermission() async => true;

  @override
  Future<PlatformMicrophonePermissionStatus>
  microphonePermissionStatus() async =>
      PlatformMicrophonePermissionStatus.granted;

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async =>
      const <PlatformAudioInputDevice>[];

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async =>
      const <PlatformAudioProcess>[];

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async => throw UnsupportedError('Playback is outside this test.');

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) =>
      const Stream<PlatformAudioSessionEvent>.empty();

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
