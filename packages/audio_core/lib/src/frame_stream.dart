import 'dart:async';

import 'frame.dart';

/// Single-consumer frame stream that makes pause behavior explicit.
///
/// Dart stream subscriptions otherwise buffer without a bound while paused.
/// Audio sources use this wrapper so non-pausable realtime streams reject
/// `pause`, while pausable sources synchronously apply source backpressure.
final class AudioFrameStream extends Stream<AudioFrame> {
  /// Wraps a single-subscription [stream].
  AudioFrameStream(
    this._stream, {
    required this.pauseSupported,
    this.onPause,
    this.onResume,
  });

  final Stream<AudioFrame> _stream;

  /// Whether subscriptions may pause.
  final bool pauseSupported;

  /// Applies source-level backpressure before the subscription pauses.
  final void Function()? onPause;

  /// Releases source-level backpressure when the subscription resumes.
  final void Function()? onResume;

  bool _listened = false;

  @override
  StreamSubscription<AudioFrame> listen(
    void Function(AudioFrame event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError('Audio frame streams accept exactly one listener.');
    }
    _listened = true;
    return _AudioFrameSubscription(
      _stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      pauseSupported: pauseSupported,
      onPause: onPause,
      onResume: onResume,
    );
  }
}

final class _AudioFrameSubscription implements StreamSubscription<AudioFrame> {
  _AudioFrameSubscription(
    this._inner, {
    required this.pauseSupported,
    this.onPause,
    this.onResume,
  });

  final StreamSubscription<AudioFrame> _inner;
  final bool pauseSupported;
  final void Function()? onPause;
  final void Function()? onResume;
  int _pauseDepth = 0;
  bool _cancelled = false;

  @override
  Future<void> cancel() async {
    if (_cancelled) {
      await _inner.cancel();
      return;
    }
    _cancelled = true;
    Object? resumeError;
    StackTrace? resumeStackTrace;
    if (_pauseDepth > 0) {
      _pauseDepth = 0;
      try {
        onResume?.call();
      } catch (error, stackTrace) {
        resumeError = error;
        resumeStackTrace = stackTrace;
      }
    }
    await _inner.cancel();
    if (resumeError != null) {
      Error.throwWithStackTrace(
        resumeError,
        resumeStackTrace ?? StackTrace.current,
      );
    }
  }

  @override
  void onData(void Function(AudioFrame data)? handleData) {
    _inner.onData(handleData);
  }

  @override
  void onError(Function? handleError) {
    _inner.onError(handleError);
  }

  @override
  void onDone(void Function()? handleDone) {
    _inner.onDone(handleDone);
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    if (!pauseSupported) {
      throw UnsupportedError(
        'This audio source cannot be paused; route it through a bounded live '
        'AudioHub instead.',
      );
    }
    if (_pauseDepth == 0) {
      onPause?.call();
    }
    _pauseDepth += 1;
    _inner.pause();
    if (resumeSignal != null) {
      unawaited(
        resumeSignal.then<void>(
          (_) => resume(),
          onError: (Object _, StackTrace _) => resume(),
        ),
      );
    }
  }

  @override
  void resume() {
    if (_cancelled || _pauseDepth == 0) {
      return;
    }
    _inner.resume();
    _pauseDepth -= 1;
    if (_pauseDepth == 0) {
      onResume?.call();
    }
  }

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
