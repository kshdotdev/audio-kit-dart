import 'dart:convert';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'capture descriptors normalize ordering and round-trip through JSON',
    () {
      final CaptureBackendDescriptor backend = CaptureBackendDescriptor(
        backendId: 'darwin-core-audio',
        displayName: 'Core Audio',
        platform: 'macos',
        sourceKinds: <CaptureSourceKind>{
          CaptureSourceKind.browser,
          CaptureSourceKind.application,
          CaptureSourceKind.systemMix,
        },
        capabilities: <CaptureCapability>{
          CaptureCapability.nativeMonotonicClock,
          CaptureCapability.processFiltering,
        },
      );
      final CaptureSourceDescriptor source = CaptureSourceDescriptor(
        sourceId: 'app:com.example.meeting',
        backendId: backend.backendId,
        kind: CaptureSourceKind.application,
        displayName: 'Meeting App',
        availability: CaptureSourceAvailability.available,
        isDefault: true,
        capabilities: <CaptureCapability>{
          CaptureCapability.processFiltering,
          CaptureCapability.nativeMonotonicClock,
        },
        supportedSampleRates: <int>[48000, 16000],
        supportedChannelCounts: <int>[2, 1],
        processIds: <int>[42, 7],
        applicationId: 'com.example.meeting',
      );

      expect(
        _jsonRoundTrip(
          backend.toJson(),
          CaptureBackendDescriptor.fromJson,
          (CaptureBackendDescriptor value) => value.toJson(),
        ),
        backend.toJson(),
      );
      expect(
        _jsonRoundTrip(
          source.toJson(),
          CaptureSourceDescriptor.fromJson,
          (CaptureSourceDescriptor value) => value.toJson(),
        ),
        source.toJson(),
      );
      expect(source.supportedSampleRates, <int>[16000, 48000]);
      expect(source.processIds, <int>[7, 42]);
      expect(source.isDefault, isTrue);
      expect(source.toJson()['isDefault'], isTrue);
      expect(backend.toJson()['sourceKinds'], <String>[
        'application',
        'browser',
        'systemMix',
      ]);
    },
  );

  test('fallback cannot start without exact explicit confirmation', () {
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'capture-1',
      sourceId: 'application:meeting',
      outputFormat: AudioFormat(sampleRate: 48000, channels: 2),
      fallbackPolicy: CaptureFallbackPolicy.requireExplicitConfirmation,
    );
    final CaptureFallbackProposal proposal = CaptureFallbackProposal(
      confirmationId: 'confirm-system-mix',
      requestedSourceId: request.sourceId,
      fallbackSourceId: 'system:default-mix',
      reasonCode: 'application_capture_unavailable',
      message: 'Only the full system mix is available.',
    );
    final CaptureProbeResult probe = CaptureProbeResult(
      probeId: 'probe-1',
      requestId: request.requestId,
      backendId: 'windows-wasapi',
      requestedSourceId: request.sourceId,
      status: CaptureProbeStatus.fallbackProposed,
      fallback: proposal,
    );

    expect(
      _jsonRoundTrip(
        probe.toJson(),
        CaptureProbeResult.fromJson,
        (CaptureProbeResult value) => value.toJson(),
      ),
      probe.toJson(),
    );

    expect(() => probe.authorize(request), throwsStateError);
    expect(
      () => probe.authorize(
        request,
        confirmation: CaptureFallbackConfirmation(
          confirmationId: proposal.confirmationId,
          acceptedSourceId: 'system:another-mix',
        ),
      ),
      throwsStateError,
    );

    final CaptureStartRequest start = probe.authorize(
      request,
      confirmation: CaptureFallbackConfirmation(
        confirmationId: proposal.confirmationId,
        acceptedSourceId: proposal.fallbackSourceId,
      ),
    );
    expect(start.selectedSourceId, proposal.fallbackSourceId);
    expect(
      _jsonRoundTrip(
        start.toJson(),
        CaptureStartRequest.fromJson,
        (CaptureStartRequest value) => value.toJson(),
      ),
      start.toJson(),
    );
  });

  test('ready and blocked probes enforce their state invariants', () {
    final CaptureProbeRequest request = CaptureProbeRequest(
      requestId: 'capture-2',
      sourceId: 'pulse:monitor:default',
      outputFormat: AudioFormat(sampleRate: 48000, channels: 2),
    );
    final CaptureProbeResult ready = CaptureProbeResult(
      probeId: 'probe-2',
      requestId: request.requestId,
      backendId: 'linux-pulse',
      requestedSourceId: request.sourceId,
      status: CaptureProbeStatus.ready,
      resolvedSourceId: request.sourceId,
    );

    expect(ready.authorize(request).selectedSourceId, request.sourceId);
    expect(
      () => CaptureProbeResult(
        probeId: 'probe-3',
        requestId: request.requestId,
        backendId: 'linux-pipewire',
        requestedSourceId: request.sourceId,
        status: CaptureProbeStatus.unavailable,
      ),
      throwsArgumentError,
    );
  });

  test('monotonic timing maps sample offsets and integrates with manifest', () {
    final MonotonicTrackTiming timing = MonotonicTrackTiming(
      trackId: 'system',
      clockId: 'pipewire.node.7',
      sessionClockId: 'meeting-9.monotonic',
      sampleRate: 1000,
      startOffset: const Duration(milliseconds: 25),
      firstSampleOffset: 100,
      quality: MonotonicTrackTimingQuality.synchronized,
    );
    final CapturedAudioTrackManifest track = CapturedAudioTrackManifest(
      trackId: 'system',
      artifactId: 'audio:meeting-9:system',
      source: AudioCaptureSourceIdentity(
        sourceId: 'pulse:monitor:default',
        kind: AudioCaptureSourceKind.systemAudio,
      ),
      format: AudioFormat(sampleRate: 1000, channels: 2),
      startOffset: const Duration(milliseconds: 25),
      timing: timing,
    );

    expect(
      timing.sessionTimestampForSample(110),
      const Duration(milliseconds: 35),
    );
    expect(
      MonotonicTrackTiming.fromJson(timing.toJson()).toJson(),
      timing.toJson(),
    );
    expect(
      CapturedAudioTrackManifest.fromJson(track.toJson()).toJson(),
      track.toJson(),
    );
    expect(() => timing.sessionTimestampForSample(99), throwsRangeError);
  });
}

Map<String, Object?> _jsonRoundTrip<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?> json) decode,
  Map<String, Object?> Function(T value) encode,
) {
  final Map<String, Object?> encoded =
      (jsonDecode(jsonEncode(json)) as Map<String, dynamic>)
          .cast<String, Object?>();
  return encode(decode(encoded));
}
