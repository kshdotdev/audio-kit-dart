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
