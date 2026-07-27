import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Provider-neutral PCM playback sink.
final class FlutterAudioPlaybackSink implements AudioSink {
  FlutterAudioPlaybackSink({
    this.maxBufferedDuration = const Duration(seconds: 2),
    AudioFlutterPlatform? platform,
  }) : _platform = platform ?? AudioFlutterPlatform.instance {
    if (maxBufferedDuration <= Duration.zero) {
      throw ArgumentError.value(
        maxBufferedDuration,
        'maxBufferedDuration',
        'Must be positive.',
      );
    }
  }

  final Duration maxBufferedDuration;
  final AudioFlutterPlatform _platform;

  @override
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final PlatformPlaybackSessionInfo info;
    try {
      info = await _platform.preparePlayback(
        PlatformPlaybackRequest(
          inputFormat: PlatformPcmFormat(
            sampleRate: format.sampleRate,
            channelCount: format.channels,
          ),
          maxBufferedDuration: maxBufferedDuration,
        ),
      );
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_playbackFailure(error), stackTrace);
    }
    _FlutterAudioPlaybackSession? session;
    try {
      cancellationToken?.throwIfCancelled();
      final AudioFormat preparedFormat = AudioFormat(
        sampleRate: info.format.sampleRate,
        channels: info.format.channelCount,
      );
      if (preparedFormat != format) {
        throw AudioFailure(
          code: 'platform_playback_format_mismatch',
          stage: AudioFailureStage.playback,
          message: 'The platform prepared an unexpected playback format.',
          retryable: false,
        );
      }
      session = _FlutterAudioPlaybackSession(
        platform: _platform,
        info: info,
        format: preparedFormat,
      );
      await session._start(cancellationToken: cancellationToken);
      return session;
    } catch (error, stackTrace) {
      // A cancellation or startup failure after native allocation must not
      // leak an engine/player session that the caller can no longer reach.
      final _FlutterAudioPlaybackSession? allocatedSession = session;
      if (allocatedSession == null) {
        try {
          await _platform.disposePlayback(info.sessionId);
        } catch (_) {
          // Preserve the original preparation failure.
        }
      } else {
        try {
          await allocatedSession.abort();
        } catch (_) {
          // Preserve the original startup failure.
        }
        try {
          await allocatedSession.close();
        } catch (_) {
          // Preserve the original startup failure.
        }
      }
      Error.throwWithStackTrace(
        error is AudioCancelledException ? error : _playbackFailure(error),
        stackTrace,
      );
    }
  }
}

final class _FlutterAudioPlaybackSession implements AudioSinkSession {
  _FlutterAudioPlaybackSession({
    required this._platform,
    required this._info,
    required this.format,
  }) : _status = const AudioSessionStatus(
         state: AudioSessionState.prepared,
         timestamp: Duration.zero,
       ) {
    _events = _platform
        .playbackEvents(_info.sessionId)
        .listen(
          _onEvent,
          onError: (Object error, StackTrace stackTrace) {
            unawaited(
              abort(
                failure: AudioFailure(
                  code: 'platform_playback_failed',
                  stage: AudioFailureStage.playback,
                  message: 'Platform playback failed.',
                  retryable: true,
                  safeCause: error.runtimeType.toString(),
                ),
              ),
            );
          },
        );
  }

  final AudioFlutterPlatform _platform;
  final PlatformPlaybackSessionInfo _info;
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  late final StreamSubscription<PlatformAudioSessionEvent> _events;
  late AudioSessionStatus _status;
  final Stopwatch _clock = Stopwatch();
  Future<void>? _finishFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  bool _abortRequested = false;
  bool _closeRequested = false;
  bool _closed = false;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  final AudioFormat format;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => Stream<AudioSessionStatus>.multi((
    MultiStreamController<AudioSessionStatus> controller,
  ) {
    controller.add(_status);
    final StreamSubscription<AudioSessionStatus> subscription = _statuses.stream
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  Future<void> _start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _clock.start();
    _setState(AudioSessionState.starting);
    try {
      await _platform.startPlayback(_info.sessionId);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _playbackFailure(
          error,
          code: 'platform_playback_start_failed',
          message: 'Platform playback could not be started.',
        ),
        stackTrace,
      );
    }
    cancellationToken?.throwIfCancelled();
    if (_abortRequested ||
        _closeRequested ||
        _status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.closed) {
      throw _status.failure ??
          AudioFailure(
            code: 'platform_playback_start_interrupted',
            stage: AudioFailureStage.playback,
            message: 'Platform playback was interrupted while starting.',
            retryable: true,
          );
    }
    _setState(AudioSessionState.active);
  }

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    _ensureActive();
    cancellationToken?.throwIfCancelled();
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Playback format mismatch.',
      );
    }
    try {
      await _platform.writePlaybackFrames(_info.sessionId, <PlatformAudioFrame>[
        PlatformAudioFrame(
          sessionId: _info.sessionId,
          sequence: frame.sequence,
          sampleOffset: frame.sampleOffset,
          timestamp: frame.timestamp,
          samples: frame.samples,
          droppedFramesBefore: frame.discontinuity?.droppedFrameCount ?? 0,
        ),
      ]);
      cancellationToken?.throwIfCancelled();
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _playbackFailure(
        error,
        code: 'platform_playback_write_failed',
        message: 'Platform playback could not accept audio.',
      );
      try {
        await abort(failure: failure);
      } catch (_) {
        // Preserve the write failure.
      }
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) {
    final Future<void>? existing = _finishFuture;
    if (existing != null) {
      return existing;
    }
    if (_status.state == AudioSessionState.finished) {
      return Future<void>.value();
    }
    _ensureActive();
    cancellationToken?.throwIfCancelled();
    return _finishFuture ??= _finish(cancellationToken);
  }

  Future<void> _finish(AudioCancellationToken? cancellationToken) async {
    _setState(AudioSessionState.finishing);
    try {
      await _platform.finishPlayback(_info.sessionId);
      cancellationToken?.throwIfCancelled();
      if (!_abortRequested &&
          _status.state == AudioSessionState.finishing &&
          !_closeRequested) {
        _setState(AudioSessionState.finished);
      }
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _playbackFailure(
        error,
        code: 'platform_playback_finish_failed',
        message: 'Platform playback could not finish cleanly.',
      );
      try {
        await abort(failure: failure);
      } catch (_) {
        // Preserve the graceful-finish failure.
      }
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) {
    if (_closed ||
        _status.state == AudioSessionState.finished ||
        _status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.closed) {
      return Future<void>.value();
    }
    return _abortFuture ??= _abort(failure);
  }

  Future<void> _abort(AudioFailure? failure) async {
    _abortRequested = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    try {
      await _platform.abortPlayback(_info.sessionId);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _playbackFailure(
          error,
          code: 'platform_playback_abort_failed',
          message: 'Platform playback could not be aborted.',
        ),
        stackTrace,
      );
    }
  }

  void _onEvent(PlatformAudioSessionEvent event) {
    if (event.phase == PlatformAudioSessionPhase.failed) {
      unawaited(
        abort(
          failure: AudioFailure(
            code: event.code ?? 'platform_playback_failed',
            stage: AudioFailureStage.playback,
            message: 'Platform playback failed.',
            retryable: true,
          ),
        ),
      );
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closeRequested = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    if (_status.state == AudioSessionState.active ||
        _status.state == AudioSessionState.starting ||
        _status.state == AudioSessionState.finishing) {
      try {
        await abort();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    for (final Future<void>? operation in <Future<void>?>[
      _finishFuture,
      _abortFuture,
    ]) {
      try {
        await operation;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    try {
      await _platform.disposePlayback(_info.sessionId);
    } catch (error, stackTrace) {
      firstError ??= _playbackFailure(
        error,
        code: 'platform_playback_dispose_failed',
        message: 'Platform playback could not be released.',
      );
      firstStackTrace ??= stackTrace;
    }
    try {
      await _events.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _closed = true;
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    _clock.stop();
    if (firstError != null) {
      final AudioFailure failure = _playbackFailure(
        firstError,
        code: 'platform_playback_cleanup_failed',
        message: 'Platform playback could not be cleaned up.',
      );
      Error.throwWithStackTrace(failure, firstStackTrace ?? StackTrace.current);
    }
  }

  void _setState(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }

  void _ensureActive() {
    if (_closed || _closeRequested) {
      throw StateError('Playback session is closed.');
    }
    if (_status.state != AudioSessionState.active) {
      throw StateError('Playback session is not active.');
    }
  }
}

AudioFailure _playbackFailure(
  Object error, {
  String code = 'platform_playback_failed',
  String message = 'Platform playback failed.',
  bool retryable = true,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.playback,
        message: message,
        retryable: retryable,
        safeCause: error.runtimeType.toString(),
      );
