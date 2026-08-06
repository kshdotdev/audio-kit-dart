import 'dart:async';

import 'cancellation.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'format.dart';
import 'frame.dart';
import 'frame_stream.dart';
import 'session.dart';

/// A single-consumer realtime source fed synchronously by a host capture graph.
///
/// This is the bridge for graph compositions that must tap one native capture
/// without subscribing to its single-consumer stream twice. The host consumes
/// the native source once, writes its durable track, and calls [add] to feed a
/// second composition such as an echo canceller. There is deliberately no
/// hidden queue: [add] delivers synchronously to the eager consumer or returns
/// `false` when the feed is not active, so realtime input cannot accumulate in
/// memory.
final class RealtimeAudioFeedSource implements AudioSource {
  /// Creates an unprepared realtime feed.
  RealtimeAudioFeedSource({
    required this.format,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
  }) {
    if (sourceId.trim().isEmpty ||
        trackId.trim().isEmpty ||
        clockId.trim().isEmpty) {
      throw ArgumentError('Audio feed identifiers must not be empty.');
    }
  }

  /// Fixed format accepted by [add].
  final AudioFormat format;

  /// Source identifier exposed by the prepared session.
  final String sourceId;

  /// Track identifier exposed by the prepared session.
  final String trackId;

  /// Clock identifier exposed by the prepared session.
  final String clockId;

  _RealtimeAudioFeedSession? _session;

  /// Delivers [frame] synchronously when the feed is active.
  ///
  /// Returns `false` before `start` and after a terminal transition. A format
  /// mismatch remains a programmer error and throws.
  bool add(AudioFrame frame) {
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Feed format must remain $format.',
      );
    }
    return _session?._add(frame) ?? false;
  }

  /// Fails the active feed and closes frame delivery.
  Future<void> fail(AudioFailure failure) async {
    await _session?.abort(failure: failure);
  }

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_session != null) {
      throw StateError('A realtime audio feed can be prepared only once.');
    }
    return _session = _RealtimeAudioFeedSession(this);
  }
}

final class _RealtimeAudioFeedSession implements AudioSourceSession {
  _RealtimeAudioFeedSession(this._source);

  final RealtimeAudioFeedSource _source;
  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>(
    sync: true,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Stopwatch _clock = Stopwatch();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: false,
  );
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  Future<void>? _closeFuture;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.realtime;

  @override
  String get clockId => _source.clockId;

  @override
  AudioFormat get format => _source.format;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  String get sourceId => _source.sourceId;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => Stream.multi((controller) {
    controller.add(_status);
    final subscription = _statuses.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  @override
  String get trackId => _source.trackId;

  bool _add(AudioFrame frame) {
    if (_status.state != AudioSessionState.active || _frames.isClosed) {
      return false;
    }
    _frames.add(frame);
    return true;
  }

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('A realtime feed can only start once.');
    }
    if (!_frames.hasListener) {
      throw StateError('Subscribe to the realtime feed before starting it.');
    }
    _clock.start();
    _transition(AudioSessionState.starting);
    _transition(AudioSessionState.active);
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('A realtime audio feed cannot be paused.');
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('A realtime audio feed cannot be paused.');
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.isTerminal) {
      return;
    }
    _transition(AudioSessionState.finishing);
    await _closeFrames();
    _transition(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_status.isTerminal) {
      return;
    }
    await _closeFrames();
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (!_status.isTerminal) {
      await abort();
    }
    await _closeFrames();
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      await _statuses.close();
    }
    _clock.stop();
  }

  Future<void> _closeFrames() async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }

  void _transition(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}
