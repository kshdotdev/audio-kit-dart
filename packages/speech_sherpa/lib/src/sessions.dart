import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'conversion.dart';
import 'failure.dart';
import 'runtime.dart';

/// Lifecycle base shared by sherpa sink sessions.
abstract base class SherpaManagedSession implements AudioSession {
  /// Creates a managed session.
  SherpaManagedSession({required this.onClosed})
    : _status = const AudioSessionStatus(
        state: AudioSessionState.prepared,
        timestamp: Duration.zero,
      ) {
    _clock.start();
  }

  /// Removes this session from its provider once resources are released.
  final void Function(SherpaManagedSession session) onClosed;

  final Stopwatch _clock = Stopwatch();
  final StreamController<AudioSessionStatus> _statusController =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses =>
      Stream<AudioSessionStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _statusController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);

  /// Whether audio can no longer be written.
  bool get isTerminal => switch (_status.state) {
    AudioSessionState.finished ||
    AudioSessionState.aborted ||
    AudioSessionState.failed ||
    AudioSessionState.closed => true,
    _ => false,
  };

  /// Session-relative timestamp.
  Duration get elapsed => _clock.elapsed;

  /// Emits a lifecycle transition.
  void transition(AudioSessionState state, {AudioFailure? failure}) {
    if (_status.state == AudioSessionState.closed) {
      return;
    }
    if (isTerminal && state != AudioSessionState.closed) {
      return;
    }
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  /// Throws when an operation is issued after a terminal transition.
  void ensureUsable(String operation) {
    if (isTerminal) {
      throw StateError('Cannot $operation a terminal sherpa session.');
    }
  }

  /// Closes the status stream.
  Future<void> closeStatuses() async {
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }
}

/// Streaming recognition session backed by a sherpa `OnlineRecognizer`.
///
/// Every accepted chunk yields a hypothesis for the segment being decoded,
/// emitted as a volatile [RecognitionPartial] that replaces the previous one.
/// When sherpa's endpointer closes the segment the same hypothesis is
/// re-emitted as a confirmed [RecognitionFinal] and the decoder is reset, so a
/// consumer can render partials in place and only ever append finals.
///
/// Speech-boundary events are deliberately not emitted. sherpa's endpointer is
/// a silence timer over decoder state, so treating an endpoint as
/// [RecognitionSpeechEnded] would claim knowledge it does not have; pair this
/// with the Silero voice-activity session, or an end-of-utterance provider,
/// when boundaries matter.
final class SherpaStreamingRecognitionSession extends SherpaManagedSession
    implements StreamingSpeechToTextSession {
  /// Creates a streaming session over [driver].
  SherpaStreamingRecognitionSession({
    required super.onClosed,
    required this.format,
    required SherpaStreamingAsrDriver driver,
    this.languageTag,
    AudioCancellationToken? cancellation,
  }) : _driver = driver, // ignore: prefer_initializing_formals
       _converter = SherpaMonoConverter(format) {
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then<void>((_) => abort()).catchError((
          Object _,
        ) {
          // Terminal status already records the cause.
        }),
      );
    }
  }

  @override
  final AudioFormat format;

  /// BCP-47 tag stamped onto every transcript this session emits.
  final String? languageTag;

  final SherpaStreamingAsrDriver _driver;
  final SherpaMonoConverter _converter;
  final StreamController<SpeechRecognitionEvent> _results =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  Future<void> _writeTail = Future<void>.value();
  int _acceptedSamples = 0;
  int _revision = 0;
  int _segment = 0;
  String _partialText = '';

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  Stream<SpeechRecognitionEvent> get results => _results.stream;

  /// Offset at the end of the audio decoded so far.
  Duration get acceptedDuration => AudioFormat(
    sampleRate: sherpaSampleRate,
    channels: 1,
  ).durationForFrames(_acceptedSamples);

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    ensureUsable('write to');
    cancellationToken?.throwIfCancelled();
    if (status.state == AudioSessionState.prepared) {
      transition(AudioSessionState.active);
    }
    // Serialized because every driver call mutates the decode stream the next
    // one reads: overlapping accepts would interleave audio into one decoder.
    return _writeTail = _writeTail.then((_) => _process(frame));
  }

  Future<void> _process(AudioFrame frame) async {
    if (isTerminal) {
      return;
    }
    try {
      for (final converted in _converter.process(frame)) {
        await _feed(converted);
      }
    } on Object catch (error) {
      await _fail(error);
      rethrow;
    }
  }

  Future<void> _feed(AudioFrame converted) async {
    final update = await _driver.accept(converted.samples);
    _acceptedSamples += converted.frameCount;
    await _handle(update);
  }

  Future<void> _handle(SherpaDriverStreamingUpdate update) async {
    final text = update.transcript.text.trim();
    if (update.isEndpoint) {
      // The endpoint closes whatever the decoder holds, including a hypothesis
      // this session already published as a partial: the final replaces it.
      _emitFinal(text.isEmpty ? _partialText : text);
      _partialText = '';
      await _driver.reset();
      return;
    }
    // sherpa re-reports an unchanged hypothesis on every chunk of silence.
    // Republishing it would make a consumer redraw for no new information.
    if (text.isEmpty || text == _partialText) {
      return;
    }
    _partialText = text;
    _revision += 1;
    _add(
      RecognitionPartial(
        transcript: _transcript(text),
        revision: _revision,
        at: acceptedDuration,
      ),
    );
  }

  void _emitFinal(String text) {
    if (text.isEmpty) {
      return;
    }
    _segment += 1;
    _add(
      RecognitionFinal(
        transcript: _transcript(text),
        segmentId: 'sherpa-$_segment',
        at: acceptedDuration,
      ),
    );
  }

  SpeechTranscript _transcript(String text) =>
      SpeechTranscript(text: text, languageTag: languageTag);

  void _add(SpeechRecognitionEvent event) {
    if (!_results.isClosed) {
      _results.add(event);
    }
  }

  Future<void> _fail(Object error) async {
    _add(
      RecognitionFailed(
        failure: sherpaSpeechFailure(
          'sherpa_streaming_failed',
          'streaming',
          'sherpa-onnx failed to decode the live audio stream.',
          cause: error,
        ),
        at: acceptedDuration,
      ),
    );
    await abort(
      failure: sherpaAudioFailure(
        'sherpa_streaming_failed',
        AudioFailureStage.provider,
        'The sherpa-onnx streaming session failed.',
      ),
    );
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    ensureUsable('finish');
    cancellationToken?.throwIfCancelled();
    await _writeTail;
    if (isTerminal) {
      return;
    }
    try {
      for (final converted in _converter.flush()) {
        await _feed(converted);
      }
      final tail = await _driver.finish();
      final text = tail.transcript.text.trim();
      // An empty tail means the endpointer already closed the last segment;
      // otherwise the drained hypothesis is the segment nobody confirmed yet.
      _emitFinal(text.isEmpty ? _partialText : text);
      _partialText = '';
    } on Object catch (error) {
      await _fail(error);
      rethrow;
    }
    transition(AudioSessionState.finished);
    await close();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (isTerminal) {
      return;
    }
    transition(
      AudioSessionState.aborted,
      failure:
          failure ??
          sherpaAudioFailure(
            'sherpa_streaming_aborted',
            AudioFailureStage.provider,
            'The sherpa-onnx streaming session was aborted.',
          ),
    );
    await close();
  }

  @override
  Future<void> close() async {
    if (status.state == AudioSessionState.closed) {
      return;
    }
    await _driver.close();
    _converter.reset();
    if (!_results.isClosed) {
      await _results.close();
    }
    transition(AudioSessionState.closed);
    await closeStatuses();
    onClosed(this);
  }
}

/// Voice-activity session backed by a sherpa Silero detector.
final class SherpaVoiceActivitySession extends SherpaManagedSession
    implements VoiceActivityDetectionSession {
  /// Creates a VAD session over [driver].
  SherpaVoiceActivitySession({
    required super.onClosed,
    required this.format,
    required SherpaVadDriver driver,
    AudioCancellationToken? cancellation,
  }) : _driver = driver, // ignore: prefer_initializing_formals
       _converter = SherpaMonoConverter(format) {
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then<void>((_) => abort()).catchError((
          Object _,
        ) {
          // Terminal status already records the cause.
        }),
      );
    }
  }

  @override
  final AudioFormat format;

  final SherpaVadDriver _driver;
  final SherpaMonoConverter _converter;
  final StreamController<VoiceActivityEvent> _events =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);
  Future<void> _writeTail = Future<void>.value();
  bool _speaking = false;
  int _emittedSamples = 0;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  Stream<VoiceActivityEvent> get events => _events.stream;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    ensureUsable('write to');
    cancellationToken?.throwIfCancelled();
    if (status.state == AudioSessionState.prepared) {
      transition(AudioSessionState.active);
    }
    return _writeTail = _writeTail.then((_) => _process(frame));
  }

  Future<void> _process(AudioFrame frame) async {
    if (isTerminal) {
      return;
    }
    for (final converted in _converter.process(frame)) {
      final spans = await _driver.accept(converted.samples);
      _emit(spans);
    }
  }

  void _emit(List<SherpaDriverSpeechSpan> spans) {
    for (final span in spans) {
      // sherpa reports completed spans, so a span implies a start that has
      // already ended: surface both edges in order.
      final start = _sampleOffset(span.startSample);
      final end = _sampleOffset(span.startSample + span.sampleCount);
      if (!_speaking) {
        _speaking = true;
        _add(VoiceActivityStarted(probability: 1, at: start));
      }
      _speaking = false;
      _add(VoiceActivityEnded(probability: 0, at: end));
      _emittedSamples = span.startSample + span.sampleCount;
    }
  }

  Duration _sampleOffset(int samples) => AudioFormat(
    sampleRate: sherpaSampleRate,
    channels: 1,
  ).durationForFrames(samples < 0 ? 0 : samples);

  void _add(VoiceActivityEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    ensureUsable('finish');
    cancellationToken?.throwIfCancelled();
    await _writeTail;
    for (final converted in _converter.flush()) {
      _emit(await _driver.accept(converted.samples));
    }
    _emit(await _driver.flush());
    transition(AudioSessionState.finished);
    await close();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (isTerminal) {
      return;
    }
    transition(
      AudioSessionState.aborted,
      failure:
          failure ??
          sherpaAudioFailure(
            'sherpa_vad_aborted',
            AudioFailureStage.provider,
            'The sherpa-onnx voice-activity session was aborted.',
          ),
    );
    await close();
  }

  @override
  Future<void> close() async {
    if (status.state == AudioSessionState.closed) {
      return;
    }
    await _driver.close();
    _converter.reset();
    if (!_events.isClosed) {
      await _events.close();
    }
    transition(AudioSessionState.closed);
    await closeStatuses();
    onClosed(this);
  }

  /// Samples already reported through a completed span.
  int get emittedSamples => _emittedSamples;
}
