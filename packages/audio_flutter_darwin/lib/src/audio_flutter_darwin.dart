import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

import 'messages.g.dart' as pigeon;

/// Registers the Apple implementation selected by audio_flutter's
/// `default_package` declarations.
abstract final class AudioFlutterDarwin {
  static void registerWith() {
    AudioFlutterPlatform.instance = DarwinAudioFlutterPlatform();
  }
}

/// Pigeon-backed Darwin implementation of the federated platform contract.
final class DarwinAudioFlutterPlatform extends AudioFlutterPlatform {
  DarwinAudioFlutterPlatform({
    pigeon.DarwinAudioHostApi? hostApi,
    Stream<pigeon.AudioSessionEventMessage>? events,
  }) : _host = hostApi ?? pigeon.DarwinAudioHostApi(),
       _events = events ?? pigeon.sessionEvents();

  final pigeon.DarwinAudioHostApi _host;
  final Stream<pigeon.AudioSessionEventMessage> _events;

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    final pigeon.CaptureSessionInfoMessage result = await _host.prepareCapture(
      pigeon.CaptureRequestMessage(
        kind: switch (request.kind) {
          PlatformCaptureKind.microphone =>
            pigeon.CaptureKindMessage.microphone,
          PlatformCaptureKind.systemAudio =>
            pigeon.CaptureKindMessage.systemAudio,
        },
        outputFormat: _encodeFormat(request.outputFormat),
        frameDurationMicros: request.frameDuration.inMicroseconds,
        maxBufferedDurationMicros: request.maxBufferedDuration.inMicroseconds,
        overflowPolicy: switch (request.overflowPolicy) {
          PlatformCaptureOverflowPolicy.dropOldest =>
            pigeon.CaptureOverflowPolicyMessage.dropOldest,
          PlatformCaptureOverflowPolicy.dropNewest =>
            pigeon.CaptureOverflowPolicyMessage.dropNewest,
          PlatformCaptureOverflowPolicy.failCapture =>
            pigeon.CaptureOverflowPolicyMessage.failCapture,
        },
        processIds: request.processIds,
        inputDeviceId: request.inputDeviceId,
        rawRecordingPath: request.rawRecordingPath,
      ),
    );
    return PlatformCaptureSessionInfo(
      sessionId: result.sessionId,
      sourceId: result.sourceId,
      trackId: result.trackId,
      clockId: result.clockId,
      format: _decodeFormat(result.format),
    );
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) =>
      _sessionEvents(sessionId);

  @override
  Future<void> startCapture(int sessionId) => _host.startCapture(sessionId);

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final pigeon.AudioFrameBatchMessage result = await _host.readCaptureFrames(
      sessionId,
      maxFrames,
      timeout.inMilliseconds,
    );
    return PlatformAudioFrameBatch(
      frames: result.frames.map(_decodeFrame).toList(growable: false),
      endOfStream: result.endOfStream,
    );
  }

  @override
  Future<void> stopCapture(int sessionId) => _host.stopCapture(sessionId);

  @override
  Future<void> abortCapture(int sessionId) => _host.abortCapture(sessionId);

  @override
  Future<void> disposeCapture(int sessionId) => _host.disposeCapture(sessionId);

  @override
  Future<bool> isSystemAudioCaptureSupported() =>
      _host.isSystemAudioCaptureSupported();

  /// Advisory on macOS: the grant is enforced at delivery, so this preflight
  /// can report `true` for a tap that will only ever deliver silence. Capture
  /// health (a running session with `receivingAudio` false, then
  /// `SystemCaptureDead`) is the authoritative signal.
  @override
  Future<bool> requestSystemAudioCapturePermission() =>
      _host.requestSystemAudioCapturePermission();

  @override
  Future<PlatformMicrophonePermissionStatus>
  microphonePermissionStatus() async =>
      _decodePermission(await _host.microphonePermissionStatus());

  @override
  Future<PlatformMicrophonePermissionStatus>
  requestMicrophonePermission() async =>
      _decodePermission(await _host.requestMicrophonePermission());

  @override
  Future<int> cleanupOrphanedCaptureDevices() =>
      _host.cleanupOrphanedAggregateDevices();

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async {
    final List<pigeon.AudioInputDeviceMessage> devices = await _host
        .listAudioInputDevices();
    return devices
        .map(
          (pigeon.AudioInputDeviceMessage device) => PlatformAudioInputDevice(
            id: device.id,
            label: device.label,
            isDefault: device.isDefault,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async {
    final List<pigeon.AudioProcessMessage> processes = await _host
        .listAudioProcesses();
    return processes
        .map(
          (pigeon.AudioProcessMessage process) => PlatformAudioProcess(
            processId: process.processId,
            bundleId: process.bundleId,
            isProducingAudio: process.isProducingAudio,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async {
    final pigeon.PlaybackSessionInfoMessage result = await _host
        .preparePlayback(
          pigeon.PlaybackRequestMessage(
            inputFormat: _encodeFormat(request.inputFormat),
            maxBufferedDurationMicros:
                request.maxBufferedDuration.inMicroseconds,
          ),
        );
    return PlatformPlaybackSessionInfo(
      sessionId: result.sessionId,
      clockId: result.clockId,
      format: _decodeFormat(result.format),
    );
  }

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) =>
      _sessionEvents(sessionId);

  @override
  Future<void> startPlayback(int sessionId) => _host.startPlayback(sessionId);

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) => _host.writePlaybackFrames(
    sessionId,
    frames.map(_encodeFrame).toList(growable: false),
  );

  @override
  Future<void> finishPlayback(int sessionId) => _host.finishPlayback(sessionId);

  @override
  Future<void> abortPlayback(int sessionId) => _host.abortPlayback(sessionId);

  @override
  Future<void> disposePlayback(int sessionId) =>
      _host.disposePlayback(sessionId);

  Stream<PlatformAudioSessionEvent> _sessionEvents(int sessionId) => _events
      .where(
        (pigeon.AudioSessionEventMessage event) => event.sessionId == sessionId,
      )
      .map(_decodeEvent);
}

pigeon.PcmFormatMessage _encodeFormat(PlatformPcmFormat format) =>
    pigeon.PcmFormatMessage(
      sampleRate: format.sampleRate,
      channelCount: format.channelCount,
    );

PlatformPcmFormat _decodeFormat(pigeon.PcmFormatMessage format) =>
    PlatformPcmFormat(
      sampleRate: format.sampleRate,
      channelCount: format.channelCount,
    );

pigeon.AudioFrameMessage _encodeFrame(PlatformAudioFrame frame) {
  final Float32List samples = frame.samples;
  return pigeon.AudioFrameMessage(
    sessionId: frame.sessionId,
    sequence: frame.sequence,
    sampleOffset: frame.sampleOffset,
    timestampMicros: frame.timestamp.inMicroseconds,
    float32Samples: Uint8List.view(
      samples.buffer,
      samples.offsetInBytes,
      samples.lengthInBytes,
    ),
    droppedFramesBefore: frame.droppedFramesBefore,
  );
}

PlatformAudioFrame _decodeFrame(pigeon.AudioFrameMessage frame) =>
    PlatformAudioFrame(
      sessionId: frame.sessionId,
      sequence: frame.sequence,
      sampleOffset: frame.sampleOffset,
      timestamp: Duration(microseconds: frame.timestampMicros),
      samples: _decodeFloat32(frame.float32Samples),
      droppedFramesBefore: frame.droppedFramesBefore,
      discontinuityReason: switch (frame.discontinuityReason) {
        null => null,
        pigeon.DiscontinuityReasonMessage.droppedFrames =>
          PlatformAudioDiscontinuityReason.droppedFrames,
        pigeon.DiscontinuityReasonMessage.sourceRestart =>
          PlatformAudioDiscontinuityReason.sourceRestart,
        pigeon.DiscontinuityReasonMessage.clockReset =>
          PlatformAudioDiscontinuityReason.clockReset,
        pigeon.DiscontinuityReasonMessage.formatChange =>
          PlatformAudioDiscontinuityReason.formatChange,
        pigeon.DiscontinuityReasonMessage.unknown =>
          PlatformAudioDiscontinuityReason.unknown,
      },
    );

Float32List _decodeFloat32(Uint8List bytes) {
  if (bytes.lengthInBytes % Float32List.bytesPerElement != 0) {
    throw const FormatException(
      'Native float32 payload length is not a multiple of four.',
    );
  }
  final int count = bytes.lengthInBytes ~/ Float32List.bytesPerElement;
  if (Endian.host == Endian.little &&
      bytes.offsetInBytes % Float32List.bytesPerElement == 0) {
    // Pigeon owns the byte payload. The typed view transfers that immutable
    // message buffer directly into the platform frame without another copy.
    return Float32List.view(bytes.buffer, bytes.offsetInBytes, count);
  }

  final ByteData data = ByteData.sublistView(bytes);
  final Float32List result = Float32List(count);
  for (var index = 0; index < count; index++) {
    result[index] = data.getFloat32(
      index * Float32List.bytesPerElement,
      Endian.little,
    );
  }
  return result;
}

PlatformAudioSessionEvent _decodeEvent(pigeon.AudioSessionEventMessage event) =>
    PlatformAudioSessionEvent(
      sessionId: event.sessionId,
      phase: switch (event.phase) {
        pigeon.AudioSessionPhaseMessage.prepared =>
          PlatformAudioSessionPhase.prepared,
        pigeon.AudioSessionPhaseMessage.starting =>
          PlatformAudioSessionPhase.starting,
        pigeon.AudioSessionPhaseMessage.running =>
          PlatformAudioSessionPhase.running,
        pigeon.AudioSessionPhaseMessage.interrupted =>
          PlatformAudioSessionPhase.interrupted,
        pigeon.AudioSessionPhaseMessage.stopping =>
          PlatformAudioSessionPhase.stopping,
        pigeon.AudioSessionPhaseMessage.stopped =>
          PlatformAudioSessionPhase.stopped,
        pigeon.AudioSessionPhaseMessage.failed =>
          PlatformAudioSessionPhase.failed,
      },
      code: event.code,
      message: event.message,
      receivingAudio: event.receivingAudio,
      callbackCount: event.callbackCount,
      peakAmplitude: event.peakAmplitude,
      rms: event.rms,
      nonZeroFramePercent: event.nonZeroFramePercent,
      renderCycles: event.renderCycles,
      firstAudioAtMillis: event.firstAudioAtMillis,
    );

PlatformMicrophonePermissionStatus _decodePermission(
  pigeon.MicrophonePermissionStatusMessage status,
) => switch (status) {
  pigeon.MicrophonePermissionStatusMessage.notDetermined =>
    PlatformMicrophonePermissionStatus.notDetermined,
  pigeon.MicrophonePermissionStatusMessage.granted =>
    PlatformMicrophonePermissionStatus.granted,
  pigeon.MicrophonePermissionStatusMessage.denied =>
    PlatformMicrophonePermissionStatus.denied,
  pigeon.MicrophonePermissionStatusMessage.restricted =>
    PlatformMicrophonePermissionStatus.restricted,
};
