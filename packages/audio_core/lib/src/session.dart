import 'dart:async';

import 'cancellation.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'format.dart';
import 'frame.dart';

/// Lifecycle state shared by audio source and sink sessions.
enum AudioSessionState {
  prepared,
  starting,
  active,
  paused,
  finishing,
  finished,
  aborted,
  failed,
  closed,
}

/// Immutable lifecycle update emitted by an audio session.
final class AudioSessionStatus {
  /// Creates a session status.
  const AudioSessionStatus({
    required this.state,
    required this.timestamp,
    this.failure,
  });

  /// Current lifecycle state.
  final AudioSessionState state;

  /// Monotonic time at which the state was entered.
  final Duration timestamp;

  /// Structured failure when [state] is [AudioSessionState.failed].
  final AudioFailure? failure;

  /// Whether no more audio operations may be issued.
  bool get isTerminal =>
      state == AudioSessionState.finished ||
      state == AudioSessionState.aborted ||
      state == AudioSessionState.failed ||
      state == AudioSessionState.closed;
}

/// Common deterministic lifecycle contract for prepared audio sessions.
abstract interface class AudioSession {
  /// Current status.
  AudioSessionStatus get status;

  /// Broadcast lifecycle updates, including the initial prepared state.
  Stream<AudioSessionStatus> get statuses;

  /// Immediately stops pending work and discards buffered data.
  ///
  /// Implementations must safely interrupt an in-flight `write` or `finish`.
  /// Callers may invoke abort concurrently to guarantee prompt shutdown of
  /// realtime playback or provider I/O.
  Future<void> abort({AudioFailure? failure});

  /// Releases resources. Implementations must be asynchronous and idempotent.
  Future<void> close();
}

/// Factory for a two-phase audio source session.
abstract interface class AudioSource {
  /// Allocates a session without starting frame delivery.
  ///
  /// Callers can subscribe to the returned session's streams before `start`.
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  });
}

/// Prepared producer of fixed-format audio frames.
abstract interface class AudioSourceSession implements AudioSession {
  /// Fixed PCM format for this session.
  AudioFormat get format;

  /// Stable source identifier applied to emitted frames.
  String get sourceId;

  /// Stable logical track identifier applied to emitted frames.
  String get trackId;

  /// Stable monotonic clock identifier applied to emitted frames.
  String get clockId;

  /// Source backpressure and realtime characteristics.
  AudioSourceCapabilities get capabilities;

  /// Single-consumer stream that emits only after [start].
  ///
  /// Fan-out belongs in `AudioRouter`. Implementations must reject subscription
  /// pauses when [capabilities] does not support pause so Dart cannot create an
  /// unbounded per-listener buffer.
  Stream<AudioFrame> get frames;

  /// Starts frame delivery.
  Future<void> start({AudioCancellationToken? cancellationToken});

  /// Applies source-level backpressure.
  ///
  /// Implementations that do not advertise `supportsPause` throw
  /// [UnsupportedError].
  Future<void> pause({AudioCancellationToken? cancellationToken});

  /// Resumes a paused source.
  Future<void> resume({AudioCancellationToken? cancellationToken});

  /// Gracefully stops frame delivery.
  Future<void> stop({AudioCancellationToken? cancellationToken});
}

/// Factory for a two-phase audio sink session.
abstract interface class AudioSink {
  /// Allocates a sink for [format] without accepting frames yet.
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  });
}

/// Prepared sequential consumer of fixed-format audio frames.
abstract interface class AudioSinkSession implements AudioSession {
  /// Fixed PCM format accepted by this session.
  AudioFormat get format;

  /// Sink ordering characteristics.
  AudioSinkCapabilities get capabilities;

  /// Writes one frame after all previously returned write futures complete.
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  });

  /// Gracefully drains and finalizes accepted frames.
  Future<void> finish({AudioCancellationToken? cancellationToken});
}
