import 'dart:async';

import 'package:audio_core/audio_core.dart';

import 'conversion.dart';
import 'drivers.dart';
import 'session_support.dart';

/// Cold FluidAudio synthesis source created by the speech provider.
final class FluidTtsAudioSource implements AudioSource {
  FluidTtsAudioSource({
    required this.runtime,
    required this.text,
    required this.voice,
    required this.rate,
    required this.configuration,
    required this.ensureProviderOpen,
    required this.registerSession,
    required this.onSessionClosed,
    this.requestCancellation,
  });

  /// Runtime that creates one native driver per prepared session.
  final FluidAudioRuntime runtime;

  /// Text to synthesize.
  final String text;

  /// Provider voice ID.
  final String? voice;

  /// Relative speaking rate.
  final double rate;

  /// Native synthesis configuration.
  final FluidTtsDriverConfiguration configuration;

  /// Throws when the owning provider has been closed.
  final void Function() ensureProviderOpen;

  /// Registers the prepared session with the provider.
  final void Function(FluidManagedSession session) registerSession;

  /// Unregisters a closed session from the provider.
  final void Function(FluidManagedSession session) onSessionClosed;

  /// Cancellation attached to the synthesis request itself.
  final AudioCancellationToken? requestCancellation;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    ensureProviderOpen();
    requestCancellation?.throwIfCancelled();
    cancellationToken?.throwIfCancelled();
    FluidTtsDriver? driver;
    try {
      driver = await runtime.createTts(configuration);
      requestCancellation?.throwIfCancelled();
      cancellationToken?.throwIfCancelled();
      ensureProviderOpen();
      final session = FluidTtsAudioSourceSession(
        driver: driver,
        text: text,
        voice: voice,
        rate: rate,
        cancellations: <AudioCancellationToken>[
          ?requestCancellation,
          ?cancellationToken,
        ],
        onClosed: onSessionClosed,
      );
      registerSession(session);
      return session;
    } catch (error) {
      await driver?.close();
      if (error case final AudioFailure failure) {
        throw failure;
      }
      if (error is AudioCancelledException) {
        rethrow;
      }
      throw fluidAudioFailure(
        'fluid_tts_prepare_failed',
        AudioFailureStage.preparation,
        'FluidAudio text-to-speech could not be prepared.',
        cause: error,
      );
    }
  }
}

/// One finite, incremental FluidAudio synthesis session.
final class FluidTtsAudioSourceSession extends FluidManagedSession
    implements AudioSourceSession {
  FluidTtsAudioSourceSession({
    required this.driver,
    required this.text,
    required this.voice,
    required this.rate,
    required super.onClosed,
    Iterable<AudioCancellationToken> cancellations =
        const <AudioCancellationToken>[],
  }) : sourceId = 'fluidaudio-tts-${_nextSessionId++}',
       trackId = 'synthesis',
       clockId = 'fluidaudio-synthesis' {
    for (final cancellation in cancellations) {
      _attachCancellation(cancellation);
    }
  }

  static int _nextSessionId = 1;

  /// Native incremental synthesis driver.
  final FluidTtsDriver driver;

  /// Input text.
  final String text;

  /// Provider voice ID.
  final String? voice;

  /// Relative speaking rate.
  final double rate;

  @override
  final String sourceId;

  @override
  final String trackId;

  @override
  final String clockId;

  @override
  AudioFormat get format => _format;

  static final AudioFormat _format = AudioFormat(
    sampleRate: 24000,
    channels: 1,
  );

  @override
  AudioSourceCapabilities get capabilities =>
      const AudioSourceCapabilities(isRealtime: false);

  final StreamController<AudioFrame> _framesController =
      StreamController<AudioFrame>(sync: true);
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _framesController.stream,
    pauseSupported: false,
  );
  StreamSubscription<FluidDriverTtsChunk>? _chunksSubscription;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  Future<void>? _driverCloseFuture;
  var _sequence = 0;
  var _sampleOffset = 0;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _startFuture ??= _start(cancellationToken);
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    ensureUsable('start');
    if (cancellationToken != null) {
      _attachCancellation(cancellationToken);
    }
    transition(AudioSessionState.starting);
    try {
      final chunks = driver.synthesize(text: text, voice: voice, rate: rate);
      _chunksSubscription = chunks.listen(
        _handleChunk,
        onError: (Object error, StackTrace stackTrace) {
          unawaited(
            _fail(error, stackTrace).catchError((Object _) {
              // The failed lifecycle state retains the primary error.
            }),
          );
        },
        onDone: () {
          unawaited(
            _complete().catchError((Object _) {
              // `_complete` maps cleanup failures onto lifecycle state.
            }),
          );
        },
      );
      cancellationToken?.throwIfCancelled();
      if (isTerminal) {
        final failure = status.failure;
        if (failure != null) {
          throw failure;
        }
        throw StateError(
          'FluidAudio synthesis ended before startup completed.',
        );
      }
      transition(AudioSessionState.active);
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('FluidAudio synthesis cannot be paused.');
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('FluidAudio synthesis cannot be resumed.');
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _stopFuture ??= _stop(cancellationToken);
  }

  Future<void> _stop(AudioCancellationToken? cancellationToken) async {
    if (status.state == AudioSessionState.finished ||
        status.state == AudioSessionState.closed) {
      return;
    }
    ensureUsable('stop');
    transition(AudioSessionState.finishing);
    final _TtsFirstError errors = _TtsFirstError();
    await errors.capture(() async => _chunksSubscription?.cancel());
    try {
      cancellationToken?.throwIfCancelled();
    } catch (error, stackTrace) {
      errors.add(error, stackTrace);
    }
    await errors.capture(_closeDriver);
    await errors.capture(_closeFrames);
    try {
      errors.throwIfPresent();
      if (!isTerminal) {
        transition(AudioSessionState.finished);
      }
    } catch (error, stackTrace) {
      if (!isTerminal) {
        transition(
          AudioSessionState.failed,
          failure: _ttsFailure(error, AudioFailureStage.shutdown),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) =>
      _abortFuture ??= _abort(failure);

  Future<void> _abort(AudioFailure? failure) async {
    if (status.state != AudioSessionState.finished &&
        status.state != AudioSessionState.closed) {
      transition(
        failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
        failure: failure,
      );
    }
    final _TtsFirstError errors = _TtsFirstError();
    await errors.capture(() async => _chunksSubscription?.cancel());
    await errors.capture(_closeDriver);
    await errors.capture(_closeFrames);
    errors.throwIfPresent();
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    final _TtsFirstError errors = _TtsFirstError();
    if (!isTerminal) {
      await errors.capture(abort);
    } else {
      await errors.capture(() async => _chunksSubscription?.cancel());
      await errors.capture(_closeDriver);
      await errors.capture(_closeFrames);
    }
    await errors.capture(closeLifecycle);
    errors.throwIfPresent();
  }

  void _handleChunk(FluidDriverTtsChunk chunk) {
    if (isTerminal || _framesController.isClosed || chunk.samples.isEmpty) {
      return;
    }
    final frame = AudioFrame(
      format: format,
      samples: chunk.samples,
      sourceId: sourceId,
      trackId: trackId,
      clockId: clockId,
      sequence: _sequence,
      sampleOffset: _sampleOffset,
      timestamp: format.durationForFrames(_sampleOffset),
    );
    _sequence += 1;
    _sampleOffset += frame.frameCount;
    _framesController.add(frame);
  }

  Future<void> _complete() async {
    if (isTerminal) {
      return;
    }
    if (_sequence == 0 && text.trim().isNotEmpty) {
      await _failEmptySynthesis();
      return;
    }
    try {
      await _closeDriver();
      if (!isTerminal) {
        transition(AudioSessionState.finished);
      }
    } catch (error, stackTrace) {
      if (!isTerminal) {
        transition(
          AudioSessionState.failed,
          failure: _ttsFailure(error, AudioFailureStage.shutdown),
        );
      }
      await _closeFrames();
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _closeFrames();
  }

  /// Fails a synthesis that ended without ever producing a frame.
  ///
  /// Kokoro answers over-long input with a clean, empty stream: no error, no
  /// audio, a route that finishes normally and renders nothing. That is
  /// indistinguishable from a reply nobody could hear, so the source fails
  /// instead of finishing. Empty input text is not this case — the provider
  /// rejects it up front with `fluid_empty_text` — and still finishes clean.
  Future<void> _failEmptySynthesis() async {
    const message = 'FluidAudio synthesized no audio for the requested text.';
    if (!_framesController.isClosed) {
      _framesController.addError(
        fluidSpeechFailure('fluid_tts_empty_synthesis', 'synthesis', message),
        StackTrace.current,
      );
    }
    await abort(
      failure: fluidAudioFailure(
        'fluid_tts_empty_synthesis',
        AudioFailureStage.provider,
        message,
      ),
    );
  }

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (isTerminal) {
      return;
    }
    final failure = error is AudioFailure
        ? error
        : fluidAudioFailure(
            'fluid_tts_failed',
            AudioFailureStage.provider,
            'FluidAudio text-to-speech generation failed.',
            cause: error,
          );
    await abort(failure: failure);
  }

  AudioFailure _ttsFailure(Object error, AudioFailureStage stage) =>
      error is AudioFailure
      ? error
      : fluidAudioFailure(
          'fluid_tts_cleanup_failed',
          stage,
          'FluidAudio text-to-speech resources could not be released.',
          cause: error,
        );

  void _attachCancellation(AudioCancellationToken cancellation) {
    unawaited(
      cancellation.whenCancelled.then<void>((_) => abort()).catchError((
        Object _,
      ) {
        // The terminal lifecycle status retains cleanup failures.
      }),
    );
  }

  Future<void> _closeDriver() => _driverCloseFuture ??= driver.close();

  Future<void> _closeFrames() {
    if (!_framesController.isClosed) {
      unawaited(_framesController.close());
    }
    return Future<void>.value();
  }
}

final class _TtsFirstError {
  Object? _error;
  StackTrace? _stackTrace;

  void add(Object error, StackTrace stackTrace) {
    _error ??= error;
    _stackTrace ??= stackTrace;
  }

  Future<void> capture(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      add(error, stackTrace);
    }
  }

  void throwIfPresent() {
    final Object? error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}
