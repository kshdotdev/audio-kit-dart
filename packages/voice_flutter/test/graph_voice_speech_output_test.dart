import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_flutter/voice_flutter.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test('waits for finite source completion and playback drain', () async {
    final _ControlledSource source = _ControlledSource(format, id: 'first');
    final _RecordingSink playback = _RecordingSink(blockFinish: true);
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
    );
    addTearDown(output.close);

    final AudioCancellationController cancellation =
        AudioCancellationController();
    var playCompleted = false;
    final Future<void> play = output
        .play(source, cancellationToken: cancellation.token)
        .whenComplete(() => playCompleted = true);

    await source.started;
    expect(cancellation.activeRegistrationCount, 1);
    source.emit(sequence: 0, sample: 0.25);
    await _eventually(() => playback.onlySession.frames.length == 1);
    expect(playCompleted, isFalse);

    await source.finish();
    await playback.onlySession.finishStarted;
    expect(playCompleted, isFalse);

    playback.onlySession.allowFinish();
    await play;

    expect(playback.onlySession.finished, isTrue);
    expect(playback.onlySession.closed, isTrue);
    expect(source.session.closed, isTrue);
    expect(cancellation.activeRegistrationCount, 0);

    cancellation.cancel(
      const AudioCancellation(reason: 'cancelled-after-playback'),
    );
    expect(playback.onlySession.aborted, isFalse);
  });

  test('interrupt promptly aborts source and device playback', () async {
    final _ControlledSource source = _ControlledSource(format, id: 'interrupt');
    final _RecordingSink playback = _RecordingSink(blockWrites: true);
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
    );
    addTearDown(output.close);

    final AudioCancellationController cancellation =
        AudioCancellationController();
    final Future<void> play = output.play(
      source,
      cancellationToken: cancellation.token,
    );
    final Future<void> playExpectation = expectLater(
      play,
      throwsA(
        isA<AudioCancelledException>().having(
          (AudioCancelledException error) => error.cancellation.reason,
          'reason',
          'playback_interrupted',
        ),
      ),
    );

    await source.started;
    source.emit(sequence: 0, sample: 0.5);
    await playback.onlySession.writeStarted;

    await output.interrupt().timeout(const Duration(seconds: 1));
    await playExpectation;

    expect(source.session.aborted, isTrue);
    expect(playback.onlySession.aborted, isTrue);
    expect(playback.onlySession.closed, isTrue);
  });

  test(
    'external cancellation aborts playback and releases registration',
    () async {
      final _ControlledSource source = _ControlledSource(format, id: 'cancel');
      final _RecordingSink playback = _RecordingSink();
      final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
        playbackSink: playback,
      );
      addTearDown(output.close);
      final AudioCancellationController cancellation =
          AudioCancellationController();

      final Future<void> play = output.play(
        source,
        cancellationToken: cancellation.token,
      );
      final Future<void> playExpectation = expectLater(
        play,
        throwsA(
          isA<AudioCancelledException>().having(
            (AudioCancelledException error) => error.cancellation.reason,
            'reason',
            'turn_cancelled',
          ),
        ),
      );
      await source.started;
      expect(cancellation.activeRegistrationCount, 1);

      cancellation.cancel(const AudioCancellation(reason: 'turn_cancelled'));
      await playExpectation;

      expect(source.session.aborted, isTrue);
      expect(playback.onlySession.aborted, isTrue);
      expect(cancellation.activeRegistrationCount, 0);
    },
  );

  test('surfaces the structured synthesized-source failure', () async {
    final _ControlledSource source = _ControlledSource(format, id: 'failure');
    final _RecordingSink playback = _RecordingSink();
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
    );
    addTearDown(output.close);
    final AudioFailure failure = AudioFailure(
      code: 'test_synthesis_failed',
      stage: AudioFailureStage.provider,
      message: 'Synthesis failed.',
      providerId: 'test',
      retryable: true,
    );

    final AudioCancellationController cancellation =
        AudioCancellationController();
    final Future<void> play = output.play(
      source,
      cancellationToken: cancellation.token,
    );
    final Future<void> playExpectation = expectLater(
      play,
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure value) => value.code,
          'code',
          failure.code,
        ),
      ),
    );

    await source.started;
    await source.fail(failure);
    await playExpectation;

    expect(playback.onlySession.aborted, isTrue);
    expect(playback.onlySession.closed, isTrue);
    expect(source.session.closed, isTrue);
  });

  test('fans identical frames into playback and optional routes', () async {
    final _ControlledSource source = _ControlledSource(format, id: 'fanout');
    final _RecordingSink playback = _RecordingSink();
    final _RecordingSink recorder = _RecordingSink();
    var builderCalls = 0;
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
      extraRoutes: (AudioFormat sourceFormat) {
        builderCalls += 1;
        expect(sourceFormat, format);
        return <VoiceSpeechOutputRoute>[
          VoiceSpeechOutputRoute(
            id: 'recording',
            sink: recorder,
            options: AudioRouteOptions.lossless(capacityFrames: 4),
          ),
        ];
      },
    );
    addTearDown(output.close);

    final AudioCancellationController cancellation =
        AudioCancellationController();
    final Future<void> play = output.play(
      source,
      cancellationToken: cancellation.token,
    );
    await source.started;
    source.emit(sequence: 0, sample: 0.1);
    source.emit(sequence: 1, sample: 0.2);
    await source.finish();
    await play;

    expect(builderCalls, 1);
    expect(
      playback.onlySession.frames.map((AudioFrame frame) => frame.sequence),
      <int>[0, 1],
    );
    expect(
      recorder.onlySession.frames.map((AudioFrame frame) => frame.sequence),
      <int>[0, 1],
    );
    expect(
      recorder.onlySession.frames.map(
        (AudioFrame frame) => frame.samples.single,
      ),
      playback.onlySession.frames.map(
        (AudioFrame frame) => frame.samples.single,
      ),
    );
    expect(playback.onlySession.finished, isTrue);
    expect(recorder.onlySession.finished, isTrue);
    expect(recorder.onlySession.closed, isTrue);
  });

  test('overlap aborts and joins stale playback before replacement', () async {
    final _ControlledSource first = _ControlledSource(format, id: 'old');
    final _ControlledSource second = _ControlledSource(format, id: 'new');
    final _RecordingSink playback = _RecordingSink();
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
    );
    addTearDown(output.close);
    final AudioCancellationController firstCancellation =
        AudioCancellationController();
    final AudioCancellationController secondCancellation =
        AudioCancellationController();

    final Future<void> firstPlay = output.play(
      first,
      cancellationToken: firstCancellation.token,
    );
    final Future<void> firstExpectation = expectLater(
      firstPlay,
      throwsA(
        isA<AudioCancelledException>().having(
          (AudioCancelledException error) => error.cancellation.reason,
          'reason',
          'playback_superseded',
        ),
      ),
    );
    await first.started;
    first.emit(sequence: 0, sample: 0.1);
    await _eventually(() => playback.onlySession.frames.isNotEmpty);

    final Future<void> secondPlay = output.play(
      second,
      cancellationToken: secondCancellation.token,
    );
    await firstExpectation;
    await second.started;

    expect(first.session.aborted, isTrue);
    expect(playback.maximumLiveSessions, 1);

    second.emit(sequence: 0, sample: 0.9);
    await second.finish();
    await secondPlay;

    expect(playback.sessions, hasLength(2));
    expect(playback.sessions.first.aborted, isTrue);
    expect(
      playback.sessions.last.frames.single.samples.single,
      closeTo(0.9, 0.000001),
    );
    expect(playback.sessions.last.finished, isTrue);
    expect(playback.maximumLiveSessions, 1);
  });

  test('close is idempotent and rejects later playback', () async {
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: _RecordingSink(),
    );

    final Future<void> firstClose = output.close();
    final Future<void> secondClose = output.close();
    expect(identical(firstClose, secondClose), isTrue);
    await firstClose;

    final AudioCancellationController cancellation =
        AudioCancellationController();
    expect(
      () => output.play(
        _ControlledSource(format, id: 'closed'),
        cancellationToken: cancellation.token,
      ),
      throwsStateError,
    );
  });
}

Future<void> _eventually(bool Function() predicate) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > const Duration(seconds: 1)) {
      fail('Condition was not met.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _ControlledSource implements AudioSource {
  _ControlledSource(AudioFormat format, {required String id})
    : session = _ControlledSourceSession(format, id: id);

  final _ControlledSourceSession session;

  Future<void> get started => session.started;

  void emit({required int sequence, required double sample}) =>
      session.emit(sequence: sequence, sample: sample);

  Future<void> finish() => session.finishNaturally();

  Future<void> fail(AudioFailure failure) => session.fail(failure);

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return session;
  }
}

final class _ControlledSourceSession implements AudioSourceSession {
  _ControlledSourceSession(this.format, {required String id})
    : sourceId = 'source-$id',
      trackId = 'track-$id',
      clockId = 'clock-$id';

  @override
  final AudioFormat format;

  @override
  final String sourceId;

  @override
  final String trackId;

  @override
  final String clockId;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>(
    sync: true,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Completer<void> _started = Completer<void>();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  var closed = false;
  var aborted = false;

  Future<void> get started => _started.future;

  @override
  AudioSourceCapabilities get capabilities =>
      const AudioSourceCapabilities(isRealtime: false);

  @override
  Stream<AudioFrame> get frames => _frames.stream;

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

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('Source already started.');
    }
    _setState(AudioSessionState.active);
    if (!_started.isCompleted) {
      _started.complete();
    }
  }

  void emit({required int sequence, required double sample}) {
    if (_status.state != AudioSessionState.active) {
      throw StateError('Source is not active.');
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: Float32List.fromList(<double>[sample]),
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: sequence,
        sampleOffset: sequence,
        timestamp: format.durationForFrames(sequence),
      ),
    );
  }

  Future<void> finishNaturally() async {
    if (_status.isTerminal) {
      return;
    }
    await _closeFrames();
    _setState(AudioSessionState.finished);
  }

  Future<void> fail(AudioFailure failure) async {
    if (_status.isTerminal) {
      return;
    }
    _setState(AudioSessionState.failed, failure: failure);
    await _closeFrames();
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    await finishNaturally();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_status.state == AudioSessionState.closed ||
        _status.state == AudioSessionState.finished) {
      return;
    }
    aborted = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    await _closeFrames();
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    if (!_status.isTerminal) {
      await abort();
    }
    await _closeFrames();
    _setState(AudioSessionState.closed);
    await _statuses.close();
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError('Controlled source cannot pause.');
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError('Controlled source cannot resume.');
  }

  Future<void> _closeFrames() async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }

  void _setState(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: Duration.zero,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}

final class _RecordingSink implements AudioSink {
  _RecordingSink({this.blockWrites = false, this.blockFinish = false});

  final bool blockWrites;
  final bool blockFinish;
  final List<_RecordingSinkSession> sessions = <_RecordingSinkSession>[];
  var _liveSessions = 0;
  var maximumLiveSessions = 0;

  _RecordingSinkSession get onlySession {
    expect(sessions, hasLength(1));
    return sessions.single;
  }

  @override
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    _liveSessions += 1;
    if (_liveSessions > maximumLiveSessions) {
      maximumLiveSessions = _liveSessions;
    }
    late final _RecordingSinkSession session;
    session = _RecordingSinkSession(
      format,
      blockWrites: blockWrites,
      blockFinish: blockFinish,
      onClose: () => _liveSessions -= 1,
    );
    sessions.add(session);
    return session;
  }
}

final class _RecordingSinkSession implements AudioSinkSession {
  _RecordingSinkSession(
    this.format, {
    required this.blockWrites,
    required this.blockFinish,
    required this._onClose,
  });

  @override
  final AudioFormat format;
  final bool blockWrites;
  final bool blockFinish;
  final void Function() _onClose;
  final List<AudioFrame> frames = <AudioFrame>[];
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Completer<void> _writeStarted = Completer<void>();
  final Completer<void> _writeGate = Completer<void>();
  final Completer<void> _finishStarted = Completer<void>();
  final Completer<void> _finishGate = Completer<void>();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.active,
    timestamp: Duration.zero,
  );
  var finished = false;
  var aborted = false;
  var closed = false;

  Future<void> get writeStarted => _writeStarted.future;

  Future<void> get finishStarted => _finishStarted.future;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (closed || aborted) {
      throw StateError('Sink is not active.');
    }
    if (!_writeStarted.isCompleted) {
      _writeStarted.complete();
    }
    if (blockWrites) {
      await _writeGate.future;
    }
    if (aborted) {
      throw const AudioCancelledException(
        AudioCancellation(reason: 'sink_aborted'),
      );
    }
    frames.add(frame.copyWith());
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    if (finished) {
      return;
    }
    cancellationToken?.throwIfCancelled();
    if (!_finishStarted.isCompleted) {
      _finishStarted.complete();
    }
    if (blockFinish) {
      await Future.any<void>(<Future<void>>[
        _finishGate.future,
        cancellationToken?.whenCancelled ?? Completer<void>().future,
      ]);
      cancellationToken?.throwIfCancelled();
    }
    if (aborted) {
      return;
    }
    finished = true;
    _setState(AudioSessionState.finished);
  }

  void allowFinish() {
    if (!_finishGate.isCompleted) {
      _finishGate.complete();
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (closed || aborted) {
      return;
    }
    aborted = true;
    if (!_writeGate.isCompleted) {
      _writeGate.complete();
    }
    if (!_finishGate.isCompleted) {
      _finishGate.complete();
    }
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    if (!finished && !aborted) {
      await abort();
    }
    closed = true;
    _setState(AudioSessionState.closed);
    _onClose();
    await _statuses.close();
  }

  void _setState(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: Duration.zero,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}
