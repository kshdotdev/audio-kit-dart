import 'dart:typed_data';

/// Physical source selected for a capture session.
enum PlatformCaptureKind { microphone, systemAudio }

/// Overflow action for the bounded native capture mailbox.
enum PlatformCaptureOverflowPolicy { dropOldest, dropNewest, failCapture }

/// Low-frequency lifecycle state reported independently from audio frames.
enum PlatformAudioSessionPhase {
  prepared,
  starting,
  running,
  interrupted,
  stopping,
  stopped,
  failed,
}

/// Fixed PCM format for one platform capture or playback session.
final class PlatformPcmFormat {
  const PlatformPcmFormat({
    required this.sampleRate,
    required this.channelCount,
  }) : assert(sampleRate > 0),
       assert(channelCount > 0);

  final int sampleRate;
  final int channelCount;

  @override
  bool operator ==(Object other) =>
      other is PlatformPcmFormat &&
      other.sampleRate == sampleRate &&
      other.channelCount == channelCount;

  @override
  int get hashCode => Object.hash(sampleRate, channelCount);
}

/// Fully typed request for a prepared native capture.
final class PlatformCaptureRequest {
  const PlatformCaptureRequest({
    required this.kind,
    required this.outputFormat,
    this.frameDuration = const Duration(milliseconds: 100),
    this.maxBufferedDuration = const Duration(seconds: 2),
    this.overflowPolicy = PlatformCaptureOverflowPolicy.failCapture,
    this.processIds = const <int>[],
    this.inputDeviceId,
    this.rawRecordingPath,
  });

  final PlatformCaptureKind kind;
  final PlatformPcmFormat outputFormat;
  final Duration frameDuration;
  final Duration maxBufferedDuration;
  final PlatformCaptureOverflowPolicy overflowPolicy;

  /// Empty means all system audio except the current process.
  final List<int> processIds;
  final String? inputDeviceId;

  /// Optional source-side recording, finalized by graceful stop.
  final String? rawRecordingPath;
}

/// Opaque prepared capture information.
final class PlatformCaptureSessionInfo {
  const PlatformCaptureSessionInfo({
    required this.sessionId,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.format,
  });

  final int sessionId;
  final String sourceId;
  final String trackId;
  final String clockId;
  final PlatformPcmFormat format;
}

/// One owned interleaved float32 frame returned by a platform pull.
final class PlatformAudioFrame {
  const PlatformAudioFrame({
    required this.sessionId,
    required this.sequence,
    required this.sampleOffset,
    required this.timestamp,
    required this.samples,
    this.droppedFramesBefore = 0,
  }) : assert(droppedFramesBefore >= 0);

  final int sessionId;
  final int sequence;
  final int sampleOffset;
  final Duration timestamp;
  final Float32List samples;

  /// Frames removed by the native mailbox immediately before this frame.
  final int droppedFramesBefore;
}

/// A bounded native mailbox read.
final class PlatformAudioFrameBatch {
  const PlatformAudioFrameBatch({
    required this.frames,
    required this.endOfStream,
  });

  final List<PlatformAudioFrame> frames;
  final bool endOfStream;
}

/// Lifecycle/health event for a capture or playback session.
final class PlatformAudioSessionEvent {
  const PlatformAudioSessionEvent({
    required this.sessionId,
    required this.phase,
    this.code,
    this.message,
    this.receivingAudio,
    this.callbackCount,
  });

  final int sessionId;
  final PlatformAudioSessionPhase phase;
  final String? code;
  final String? message;
  final bool? receivingAudio;
  final int? callbackCount;
}

/// Core Audio process that may be selected for system capture.
final class PlatformAudioProcess {
  const PlatformAudioProcess({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  final int processId;
  final String bundleId;
  final bool isProducingAudio;
}

/// Provider-neutral physical input device exposed by the platform.
final class PlatformAudioInputDevice {
  const PlatformAudioInputDevice({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  /// Stable platform device identifier, such as a Core Audio UID.
  final String id;

  /// Human-readable device name.
  final String label;

  /// Whether the platform currently selects this input by default.
  final bool isDefault;
}

/// Typed request for a PCM playback sink.
final class PlatformPlaybackRequest {
  const PlatformPlaybackRequest({
    required this.inputFormat,
    this.maxBufferedDuration = const Duration(seconds: 2),
  });

  final PlatformPcmFormat inputFormat;
  final Duration maxBufferedDuration;
}

/// Opaque prepared playback information.
final class PlatformPlaybackSessionInfo {
  const PlatformPlaybackSessionInfo({
    required this.sessionId,
    required this.clockId,
    required this.format,
  });

  final int sessionId;
  final String clockId;
  final PlatformPcmFormat format;
}
