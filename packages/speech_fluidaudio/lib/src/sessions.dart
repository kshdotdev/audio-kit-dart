import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:speech_core/speech_core.dart';

import 'conversion.dart';
import 'drivers.dart';
import 'session_support.dart';

Future<void> _requestObserverClose<T>(StreamController<T> controller) {
  if (!controller.isClosed) {
    unawaited(controller.close());
  }
  return Future<void>.value();
}

abstract base class _FluidConvertedSinkSession extends FluidManagedSession
    implements AudioSinkSession {
  _FluidConvertedSinkSession({
    required super.onClosed,
    required this.format,
    required this.driverClose,
    AudioCancellationToken? cancellation,
  }) : _converter = FluidPcm16MonoConverter(format) {
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then<void>((_) => abort()).catchError((
          Object _,
        ) {
          // The lifecycle status and explicit operation futures retain
          // cleanup failures.
        }),
      );
    }
  }

  @override
  final AudioFormat format;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  final FluidPcm16MonoConverter _converter;
  final Future<void> Function() driverClose;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _finishFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  Future<void>? _driverCloseFuture;
  var _convertedSampleCount = 0;

  /// Number of 16 kHz mono samples accepted by the native driver.
  int get convertedSampleCount => _convertedSampleCount;

  /// Offset at the end of accepted audio.
  Duration get convertedDuration => Duration(
    microseconds:
        (_convertedSampleCount * Duration.microsecondsPerSecond) ~/ 16000,
  );

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    ensureUsable('write to');
    cancellationToken?.throwIfCancelled();
    return _writeFrame(frame, cancellationToken);
  }

  Future<void> _writeFrame(
    AudioFrame frame,
    AudioCancellationToken? cancellationToken,
  ) async {
    try {
      await _serialize(() async {
        ensureUsable('write to');
        cancellationToken?.throwIfCancelled();
        if (status.state == AudioSessionState.prepared) {
          transition(AudioSessionState.active);
        }
        for (final converted in _converter.process(frame)) {
          await feedConverted(converted);
          _convertedSampleCount += converted.frameCount;
        }
      });
    } catch (error, stackTrace) {
      final failure = _operationFailure(error);
      await fail(failure, error, stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _finishFuture ??= _finish(cancellationToken);
  }

  Future<void> _finish(AudioCancellationToken? cancellationToken) async {
    try {
      await _serialize(() async {
        if (isTerminal) {
          if (status.state == AudioSessionState.finished) {
            return;
          }
          ensureUsable('finish');
        }
        transition(AudioSessionState.finishing);
        for (final converted in _converter.flush()) {
          await feedConverted(converted);
          _convertedSampleCount += converted.frameCount;
        }
        cancellationToken?.throwIfCancelled();
        await finishNative(cancellationToken: cancellationToken);
        final _FluidFirstError cleanup = _FluidFirstError();
        await cleanup.capture(cancelNativeEvents);
        await cleanup.capture(closeDriver);
        cleanup.throwIfPresent();
        if (isTerminal) {
          ensureUsable('finish');
        }
        transition(AudioSessionState.finished);
        await closeResultStream();
      });
    } catch (error, stackTrace) {
      final failure = _operationFailure(error);
      await fail(failure, error, stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) =>
      _abortFuture ??= _abortOnce(failure);

  Future<void> _abortOnce(AudioFailure? failure) async {
    if (status.state != AudioSessionState.finished &&
        status.state != AudioSessionState.closed) {
      transition(
        failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
        failure: failure,
      );
    }
    await _writeTail;
    _converter.reset();
    final _FluidFirstError errors = _FluidFirstError();
    await errors.capture(cancelNativeEvents);
    await errors.capture(closeDriver);
    await errors.capture(closeResultStream);
    errors.throwIfPresent();
  }

  @override
  Future<void> close() => _closeFuture ??= _closeOnce();

  Future<void> _closeOnce() async {
    final _FluidFirstError errors = _FluidFirstError();
    if (!isTerminal) {
      await errors.capture(abort);
    } else {
      await errors.capture(() async => _writeTail);
      await errors.capture(cancelNativeEvents);
      await errors.capture(closeDriver);
      await errors.capture(closeResultStream);
    }
    await errors.capture(closeLifecycle);
    errors.throwIfPresent();
  }

  /// Immediately fails the session after a native event-stream error.
  Future<void> fail(
    AudioFailure failure, [
    Object? cause,
    StackTrace? stackTrace,
  ]) async {
    if (isTerminal) {
      return;
    }
    emitProviderFailure(
      fluidSpeechFailure(
        failure.code,
        'streaming',
        failure.message,
        cause: cause,
      ),
    );
    await abort(failure: failure);
  }

  /// Converts one 16 kHz mono frame into provider-specific feeds.
  Future<void> feedConverted(AudioFrame frame);

  /// Flushes provider-specific state after the PCM converter is drained.
  Future<void> finishNative({AudioCancellationToken? cancellationToken});

  /// Cancels the native event subscription.
  Future<void> cancelNativeEvents();

  /// Closes the typed result stream.
  Future<void> closeResultStream();

  /// Emits a provider-specific typed failure event.
  void emitProviderFailure(SpeechFailure failure);

  Future<void> closeDriver() => _driverCloseFuture ??= driverClose();

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _writeTail.then((_) => action());
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  AudioFailure _operationFailure(Object error) {
    if (error case final AudioFailure failure) {
      return failure;
    }
    if (error is AudioCancelledException) {
      return fluidAudioFailure(
        'fluid_cancelled',
        AudioFailureStage.provider,
        'The FluidAudio operation was cancelled.',
        cause: error,
      );
    }
    return fluidAudioFailure(
      'fluid_stream_failed',
      AudioFailureStage.provider,
      'FluidAudio could not process the audio stream.',
      cause: error,
    );
  }
}

final class _FluidFirstError {
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> capture(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      _error ??= error;
      _stackTrace ??= stackTrace;
    }
  }

  void throwIfPresent() {
    final Object? error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}

/// FluidAudio implementation of a streaming recognition sink.
final class FluidStreamingSpeechToTextSession extends _FluidConvertedSinkSession
    implements StreamingSpeechToTextSession {
  FluidStreamingSpeechToTextSession({
    required FluidStreamingAsrDriver driver,
    required super.format,
    required this.languageTag,
    required super.onClosed,
    super.cancellation,
  }) : _driver = driver,
       super(driverClose: driver.close) {
    _updatesSubscription = _driver.updates.listen(
      _handleUpdate,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(
          fail(
            fluidAudioFailure(
              'fluid_asr_event_failed',
              AudioFailureStage.provider,
              'FluidAudio recognition stopped unexpectedly.',
              cause: error,
            ),
            error,
            stackTrace,
          ),
        );
      },
    );
  }

  final FluidStreamingAsrDriver _driver;
  final String? languageTag;
  final StreamController<SpeechRecognitionEvent> _resultsController =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  late final StreamSubscription<FluidDriverTranscriptionUpdate>
  _updatesSubscription;
  Future<void>? _cancelUpdatesFuture;
  Future<void>? _closeResultsFuture;
  var _revision = 0;
  var _segment = 0;
  String _partialText = '';
  List<FluidDriverTokenTiming> _partialTimings =
      const <FluidDriverTokenTiming>[];
  double? _partialConfidence;

  @override
  Stream<SpeechRecognitionEvent> get results => _resultsController.stream;

  @override
  Future<void> feedConverted(AudioFrame frame) => _driver.feed(frame.samples);

  @override
  Future<void> finishNative({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final tail = (await _driver.finish()).trim();
    cancellationToken?.throwIfCancelled();
    final finalText = tail.isEmpty ? _partialText.trim() : tail;
    if (finalText.isNotEmpty) {
      _emitFinal(
        finalText,
        tail == _partialText.trim()
            ? _partialTimings
            : const <FluidDriverTokenTiming>[],
        _partialConfidence,
      );
    }
    _partialText = '';
    _partialTimings = const <FluidDriverTokenTiming>[];
    _partialConfidence = null;
  }

  @override
  Future<void> cancelNativeEvents() =>
      _cancelUpdatesFuture ??= _updatesSubscription.cancel();

  @override
  Future<void> closeResultStream() =>
      _closeResultsFuture ??= _requestObserverClose(_resultsController);

  @override
  void emitProviderFailure(SpeechFailure failure) {
    if (!_resultsController.isClosed) {
      _resultsController.add(
        RecognitionFailed(failure: failure, at: convertedDuration),
      );
    }
  }

  void _handleUpdate(FluidDriverTranscriptionUpdate update) {
    if (isTerminal || _resultsController.isClosed) {
      return;
    }
    if (update.promotesPreviousHypothesis && _partialText.trim().isNotEmpty) {
      _emitFinal(_partialText.trim(), _partialTimings, _partialConfidence);
    }

    _partialText = update.text;
    _partialTimings = update.timings;
    _partialConfidence = _safeConfidence(update.confidence);
    if (_partialText.trim().isNotEmpty) {
      _revision += 1;
      _resultsController.add(
        RecognitionPartial(
          transcript: _transcript(
            _partialText,
            _partialTimings,
            _partialConfidence,
          ),
          revision: _revision,
          at: _eventTime(_partialTimings),
        ),
      );
    }
  }

  void _emitFinal(
    String text,
    List<FluidDriverTokenTiming> timings,
    double? confidence,
  ) {
    if (_resultsController.isClosed || text.trim().isEmpty) {
      return;
    }
    _segment += 1;
    _resultsController.add(
      RecognitionFinal(
        transcript: _transcript(text, timings, confidence),
        segmentId: 'fluid-$_segment',
        at: _eventTime(timings),
      ),
    );
  }

  SpeechTranscript _transcript(
    String text,
    List<FluidDriverTokenTiming> timings,
    double? confidence,
  ) => SpeechTranscript(
    text: text,
    languageTag: languageTag,
    confidence: confidence,
    words: <SpeechWord>[
      for (final timing in timings)
        if (!timing.start.isNegative && timing.end >= timing.start)
          SpeechWord(
            text: timing.text,
            range: SpeechTimeRange(start: timing.start, end: timing.end),
            confidence: _safeConfidence(timing.confidence),
          ),
    ],
  );

  Duration _eventTime(List<FluidDriverTokenTiming> timings) {
    var at = convertedDuration;
    for (final timing in timings) {
      if (timing.end > at) {
        at = timing.end;
      }
    }
    return at;
  }
}

/// FluidAudio implementation of a streaming VAD sink.
final class FluidVoiceActivityDetectionSession
    extends _FluidConvertedSinkSession
    implements VoiceActivityDetectionSession {
  FluidVoiceActivityDetectionSession({
    required FluidVadDriver driver,
    required super.format,
    required this.startThreshold,
    required this.endThreshold,
    required this.minimumSpeech,
    required this.minimumSilence,
    required super.onClosed,
    super.cancellation,
  }) : _driver = driver,
       super(driverClose: driver.close) {
    _eventsSubscription = _driver.events.listen(
      _handleEvent,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(
          fail(
            fluidAudioFailure(
              'fluid_vad_event_failed',
              AudioFailureStage.provider,
              'FluidAudio voice activity detection stopped unexpectedly.',
              cause: error,
            ),
            error,
            stackTrace,
          ),
        );
      },
    );
  }

  static const int _chunkSize = 4096;
  static const Duration _chunkDuration = Duration(milliseconds: 256);

  final FluidVadDriver _driver;
  final double startThreshold;
  final double endThreshold;
  final Duration minimumSpeech;
  final Duration minimumSilence;
  final AudioRechunker _rechunker = AudioRechunker(
    targetFrameCount: _chunkSize,
  );
  final StreamController<VoiceActivityEvent> _eventsController =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);
  late final StreamSubscription<FluidDriverVadEvent> _eventsSubscription;
  Future<void>? _cancelEventsFuture;
  Future<void>? _closeEventsFuture;
  var _isSpeech = false;
  var _speechCandidate = Duration.zero;
  var _silenceCandidate = Duration.zero;

  @override
  Stream<VoiceActivityEvent> get events => _eventsController.stream;

  @override
  Future<void> feedConverted(AudioFrame frame) async {
    for (final chunk in _rechunker.process(frame)) {
      await _driver.feed(chunk.samples);
    }
  }

  @override
  Future<void> finishNative({AudioCancellationToken? cancellationToken}) async {
    for (final partial in _rechunker.flush()) {
      cancellationToken?.throwIfCancelled();
      final padded = Float32List(_chunkSize)
        ..setRange(0, partial.samples.length, partial.samples);
      await _driver.feed(padded);
    }
    if (_isSpeech && !_eventsController.isClosed) {
      _isSpeech = false;
      _eventsController.add(
        VoiceActivityEnded(probability: 0, at: convertedDuration),
      );
    }
  }

  @override
  Future<void> cancelNativeEvents() =>
      _cancelEventsFuture ??= _eventsSubscription.cancel();

  @override
  Future<void> closeResultStream() =>
      _closeEventsFuture ??= _requestObserverClose(_eventsController);

  @override
  void emitProviderFailure(SpeechFailure failure) {
    // VAD has no failure event in speech_core; lifecycle status carries it.
  }

  void _handleEvent(FluidDriverVadEvent event) {
    if (isTerminal || _eventsController.isClosed) {
      return;
    }
    final probability = _safeConfidence(event.probability) ?? 0;
    final at = _vadEventTime(event);
    if (_isSpeech) {
      if (probability <= endThreshold) {
        _silenceCandidate += _chunkDuration;
        if (_silenceCandidate >= minimumSilence) {
          _isSpeech = false;
          _silenceCandidate = Duration.zero;
          _speechCandidate = Duration.zero;
          _eventsController.add(
            VoiceActivityEnded(probability: probability, at: at),
          );
        }
      } else {
        _silenceCandidate = Duration.zero;
      }
    } else if (probability >= startThreshold) {
      _speechCandidate += _chunkDuration;
      if (_speechCandidate >= minimumSpeech) {
        _isSpeech = true;
        _speechCandidate = Duration.zero;
        _silenceCandidate = Duration.zero;
        _eventsController.add(
          VoiceActivityStarted(probability: probability, at: at),
        );
      }
    } else {
      _speechCandidate = Duration.zero;
    }

    _eventsController.add(
      VoiceActivityProbability(
        probability: probability,
        isSpeech: _isSpeech,
        at: at,
      ),
    );
  }

  Duration _vadEventTime(FluidDriverVadEvent event) {
    final time = event.time;
    if (time != null && !time.isNegative) {
      return time;
    }
    final sampleIndex = event.sampleIndex;
    if (sampleIndex != null && sampleIndex >= 0) {
      return Duration(
        microseconds: (sampleIndex * Duration.microsecondsPerSecond) ~/ 16000,
      );
    }
    return convertedDuration;
  }
}

/// FluidAudio implementation of a streaming EOU sink.
final class FluidEndOfUtteranceSession extends _FluidConvertedSinkSession
    implements EndOfUtteranceSession {
  FluidEndOfUtteranceSession({
    required FluidEndOfUtteranceDriver driver,
    required super.format,
    required super.onClosed,
    super.cancellation,
  }) : _driver = driver,
       super(driverClose: driver.close) {
    _updatesSubscription = _driver.updates.listen(
      _handleUpdate,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(
          fail(
            fluidAudioFailure(
              'fluid_eou_event_failed',
              AudioFailureStage.provider,
              'FluidAudio turn detection stopped unexpectedly.',
              cause: error,
            ),
            error,
            stackTrace,
          ),
        );
      },
    );
  }

  final FluidEndOfUtteranceDriver _driver;
  final StreamController<EndOfUtteranceEvent> _eventsController =
      StreamController<EndOfUtteranceEvent>.broadcast(sync: true);
  late final StreamSubscription<FluidDriverEndOfUtteranceUpdate>
  _updatesSubscription;
  Future<void>? _cancelUpdatesFuture;
  Future<void>? _closeEventsFuture;
  String _lastFinalText = '';

  @override
  Stream<EndOfUtteranceEvent> get events => _eventsController.stream;

  @override
  Future<void> feedConverted(AudioFrame frame) => _driver.feed(frame.samples);

  @override
  Future<void> finishNative({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final tail = (await _driver.finish()).trim();
    if (tail.isNotEmpty && tail != _lastFinalText) {
      _lastFinalText = tail;
      _emitFinal();
    }
  }

  @override
  Future<void> cancelNativeEvents() =>
      _cancelUpdatesFuture ??= _updatesSubscription.cancel();

  @override
  Future<void> closeResultStream() =>
      _closeEventsFuture ??= _requestObserverClose(_eventsController);

  @override
  void emitProviderFailure(SpeechFailure failure) {
    // EOU has no failure event in speech_core; lifecycle status carries it.
  }

  void _handleUpdate(FluidDriverEndOfUtteranceUpdate update) {
    if (isTerminal || _eventsController.isClosed || !update.isFinal) {
      return;
    }
    _lastFinalText = update.text.trim();
    _emitFinal();
  }

  void _emitFinal() {
    _eventsController.add(
      EndOfUtteranceEvent(probability: 1, at: convertedDuration, isFinal: true),
    );
  }
}

double? _safeConfidence(double? value) {
  if (value == null || !value.isFinite) {
    return null;
  }
  return math.max(0, math.min(1, value));
}
