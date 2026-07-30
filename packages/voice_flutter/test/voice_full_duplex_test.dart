import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_core/voice_core.dart';
import 'package:voice_flutter/voice_flutter.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test(
    'fans synthesized frames into playback and the reference in order',
    () async {
      final VoiceFarEndTap tap = VoiceFarEndTap(format: format);
      final _RecordingSink playback = _RecordingSink();
      final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
        playbackSink: playback,
        extraRoutes: (AudioFormat _) => <VoiceSpeechOutputRoute>[tap.route()],
      );
      addTearDown(output.close);

      final VoiceFarEndTapSession session = await tap.prepare();
      addTearDown(session.close);
      final List<AudioFrame> tapped = <AudioFrame>[];
      final StreamSubscription<AudioFrame> frames = session.frames.listen(
        tapped.add,
      );
      addTearDown(frames.cancel);
      await session.start();

      final _ControlledSource source = _ControlledSource(
        format,
        id: 'utterance',
      );
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final Future<void> play = output.play(
        source,
        cancellationToken: cancellation.token,
      );
      await source.started;
      source.emit(sequence: 0, sample: 0.25);
      source.emit(sequence: 1, sample: -0.5);
      source.emit(sequence: 2, sample: 0.75);
      await source.finish();
      await play;
      await _eventually(() => tapped.length == 3);

      // The same signal, from one router dispatch, in one order.
      expect(
        playback.onlySession.frames
            .map((AudioFrame frame) => frame.samples.single)
            .toList(),
        <double>[0.25, -0.5, 0.75],
      );
      expect(
        tapped.map((AudioFrame frame) => frame.samples.single).toList(),
        <double>[0.25, -0.5, 0.75],
      );
      expect(tapped.map((AudioFrame frame) => frame.sequence).toList(), <int>[
        0,
        1,
        2,
      ]);
      expect(
        tapped.every((AudioFrame frame) => frame.sourceId == tap.sourceId),
        isTrue,
      );
      expect(session.framesTapped, 3);
      expect(session.framesDiscarded, 0);
      expect(session.utterances, 1);
    },
  );

  test('splices successive utterances into one reference timeline', () async {
    final VoiceFarEndTap tap = VoiceFarEndTap(format: format);
    final _RecordingSink playback = _RecordingSink();
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
      extraRoutes: (AudioFormat _) => <VoiceSpeechOutputRoute>[tap.route()],
    );
    addTearDown(output.close);

    final VoiceFarEndTapSession session = await tap.prepare();
    addTearDown(session.close);
    final List<AudioFrame> tapped = <AudioFrame>[];
    final StreamSubscription<AudioFrame> frames = session.frames.listen(
      tapped.add,
    );
    addTearDown(frames.cancel);
    await session.start();

    for (final String id in <String>['first', 'second']) {
      final _ControlledSource source = _ControlledSource(format, id: id);
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final Future<void> play = output.play(
        source,
        cancellationToken: cancellation.token,
      );
      await source.started;
      source.emit(sequence: 0, sample: 0.25);
      source.emit(sequence: 1, sample: 0.5);
      await source.finish();
      await play;
    }
    await _eventually(() => tapped.length == 4);

    // Each utterance is its own synthesized source restarting at offset zero;
    // the tap is one continuous timeline spliced from all of them.
    expect(tapped.map((AudioFrame frame) => frame.sequence).toList(), <int>[
      0,
      1,
      2,
      3,
    ]);
    expect(tapped.map((AudioFrame frame) => frame.sampleOffset).toList(), <int>[
      0,
      1,
      2,
      3,
    ]);
    expect(
      tapped[2].discontinuity?.reason,
      AudioDiscontinuityReason.sourceRestart,
    );
    expect(tapped[0].discontinuity, isNull);
    expect(tapped[1].discontinuity, isNull);
    expect(tapped[3].discontinuity, isNull);
    expect(session.utterances, 2);
  });

  test('rejects a reference format that does not match capture', () async {
    final VoiceFarEndTap tap = VoiceFarEndTap(format: format);

    await expectLater(
      tap.sink.prepare(AudioFormat(sampleRate: 24000, channels: 1)),
      throwsArgumentError,
    );
    await expectLater(
      tap.sink.prepare(AudioFormat(sampleRate: 16000, channels: 2)),
      throwsArgumentError,
    );
  });

  test('counts playback that happens while the tap is not running', () async {
    final VoiceFarEndTap tap = VoiceFarEndTap(format: format);
    final _RecordingSink playback = _RecordingSink();
    final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
      playbackSink: playback,
      extraRoutes: (AudioFormat _) => <VoiceSpeechOutputRoute>[tap.route()],
    );
    addTearDown(output.close);

    // Prepared but never started: capture is not running, so nothing is
    // bleeding into a microphone and there is nothing to cancel.
    final VoiceFarEndTapSession session = await tap.prepare();
    addTearDown(session.close);
    final List<AudioFrame> tapped = <AudioFrame>[];
    final StreamSubscription<AudioFrame> frames = session.frames.listen(
      tapped.add,
    );
    addTearDown(frames.cancel);

    final _ControlledSource source = _ControlledSource(format, id: 'early');
    final AudioCancellationController cancellation =
        AudioCancellationController();
    final Future<void> play = output.play(
      source,
      cancellationToken: cancellation.token,
    );
    await source.started;
    source.emit(sequence: 0, sample: 0.25);
    source.emit(sequence: 1, sample: 0.5);
    await source.finish();
    await play;
    await _eventually(() => session.framesDiscarded == 2);

    expect(tapped, isEmpty);
    expect(session.framesTapped, 0);
    expect(playback.onlySession.frames, hasLength(2));
  });

  test('compose wires an echo-cancelled microphone and its route', () async {
    final _ManualSource microphone = _ManualSource(format, id: 'mic');
    final VoiceFullDuplexSetup setup = VoiceFullDuplexSetup.compose(
      microphone: microphone,
      captureFormat: format,
      engine: () => _SubtractingEngine(sampleRate: format.sampleRate),
    );

    expect(setup.echoCancellation, VoiceEchoCancellationOutcome.active);
    expect(setup.isEchoCancelled, isTrue);
    expect(setup.unavailable, isNull);
    expect(setup.microphone, isA<AecMicFilter>());
    expect(setup.farEndTap, isNotNull);
    expect(setup.duplex.mode, VoiceDuplexMode.fullDuplex);
    expect(setup.duplex.isDegraded, isFalse);
    expect(setup.outputRoutes(format), hasLength(1));
    expect(setup.outputRoutes(format).single.id, 'voice-aec-reference');
  });

  test('compose falls back to half duplex when no canceller exists', () async {
    final _ManualSource microphone = _ManualSource(format, id: 'mic');
    const AecUnavailable unavailable = AecUnavailable(
      'no library',
      attemptedPaths: <String>['libaec.so'],
    );
    final VoiceFullDuplexSetup setup = VoiceFullDuplexSetup.compose(
      microphone: microphone,
      captureFormat: format,
      engine: () => throw unavailable,
      interruptAfterSustainedSpeech: const Duration(milliseconds: 400),
    );

    expect(
      setup.echoCancellation,
      VoiceEchoCancellationOutcome.unavailableFellBackToHalfDuplex,
    );
    expect(setup.isEchoCancelled, isFalse);
    expect(setup.unavailable, same(unavailable));
    // The degraded path is the ordinary half-duplex path: the raw microphone,
    // not a passthrough wrapper around it.
    expect(setup.microphone, same(microphone));
    expect(setup.farEndTap, isNull);
    expect(setup.outputRoutes(format), isEmpty);
    expect(setup.duplex.mode, VoiceDuplexMode.halfDuplex);
    expect(setup.duplex.requestedMode, VoiceDuplexMode.fullDuplex);
    expect(setup.duplex.isDegraded, isTrue);
    expect(setup.duplex.interruptAfterSustainedSpeech, isNull);
  });

  test('compose keeps full duplex when the echo risk is accepted', () async {
    final _ManualSource microphone = _ManualSource(format, id: 'mic');
    final VoiceFullDuplexSetup setup = VoiceFullDuplexSetup.compose(
      microphone: microphone,
      captureFormat: format,
      engine: () => throw const AecUnavailable('no library'),
      fallback: VoiceEchoCancellationFallback.acceptEchoRisk,
    );

    expect(
      setup.echoCancellation,
      VoiceEchoCancellationOutcome.unavailableEchoRiskAccepted,
    );
    expect(setup.microphone, same(microphone));
    expect(setup.farEndTap, isNull);
    expect(setup.outputRoutes(format), isEmpty);
    expect(setup.duplex.mode, VoiceDuplexMode.fullDuplex);
    expect(setup.duplex.isDegraded, isFalse);
    expect(setup.duplex.acceptsEchoRisk, isTrue);
  });

  test(
    'the composed microphone cancels tapped playback out of capture',
    () async {
      final _SubtractingEngine engine = _SubtractingEngine(
        sampleRate: format.sampleRate,
      );
      final _ManualSource microphone = _ManualSource(format, id: 'mic');
      final VoiceFullDuplexSetup setup = VoiceFullDuplexSetup.compose(
        microphone: microphone,
        captureFormat: format,
        engine: () => engine,
      );
      final _RecordingSink playback = _RecordingSink();
      final GraphVoiceSpeechOutput output = GraphVoiceSpeechOutput(
        playbackSink: playback,
        extraRoutes: setup.outputRoutes,
      );
      addTearDown(output.close);

      final AudioSourceSession capture = await setup.microphone.prepare();
      addTearDown(capture.close);
      final List<AudioFrame> cleaned = <AudioFrame>[];
      final StreamSubscription<AudioFrame> frames = capture.frames.listen(
        cleaned.add,
      );
      addTearDown(frames.cancel);
      // Starting the filter starts the far-end tap it owns.
      await capture.start();

      // The assistant plays one 10 ms block; the microphone hears it as echo on
      // top of the user's own speech.
      final _ControlledSource source = _ControlledSource(format, id: 'speech');
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final Future<void> play = output.play(
        source,
        cancellationToken: cancellation.token,
      );
      await source.started;
      source.emitBlock(
        sequence: 0,
        samples: _constant(engine.blockFrames, 0.5),
      );
      await source.finish();
      await play;
      await _eventually(() => engine.reverseBlocks == 1);

      microphone.push(_constant(engine.blockFrames, 0.75));
      await _eventually(() => cleaned.isNotEmpty);

      expect(engine.captureBlocks, 1);
      expect(cleaned.single.frameCount, engine.blockFrames);
      for (final double sample in cleaned.single.samples) {
        expect(sample, closeTo(0.25, 0.001));
      }
      expect(setup.farEndTap?.session?.framesTapped, 1);
    },
  );
}

Float32List _constant(int frames, double value) =>
    Float32List(frames)..fillRange(0, frames, value);

Future<void> _eventually(bool Function() predicate) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > const Duration(seconds: 2)) {
      fail('Condition was not met.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// An [AecEngine] that cancels by exact subtraction of the reference block it
/// was paired with, so a test can inject a known echo and assert it is gone.
final class _SubtractingEngine implements AecEngine {
  _SubtractingEngine({required this.sampleRate})
    : blockFrames = sampleRate ~/ 100;

  @override
  final int sampleRate;

  @override
  final int blockFrames;

  final Queue<Int16List> _pending = Queue<Int16List>();
  int reverseBlocks = 0;
  int captureBlocks = 0;
  int disposeCount = 0;

  @override
  void processReverse(Int16List block) {
    reverseBlocks += 1;
    _pending.add(Int16List.fromList(block));
  }

  @override
  Int16List processCapture(Int16List block, int streamDelayMs) {
    captureBlocks += 1;
    final Int16List? reference = _pending.isEmpty
        ? null
        : _pending.removeFirst();
    final Int16List cleaned = Int16List(block.length);
    for (var index = 0; index < block.length; index += 1) {
      final int value = reference == null
          ? block[index]
          : block[index] - reference[index];
      cleaned[index] = value < -32768
          ? -32768
          : (value > 32767 ? 32767 : value);
    }
    return cleaned;
  }

  @override
  AecMetrics metrics() => AecMetrics.empty;

  @override
  void dispose() {
    disposeCount += 1;
  }
}

final class _ManualSource implements AudioSource {
  _ManualSource(this.format, {required String id})
    : session = _ManualSourceSession(format, id: id);

  final AudioFormat format;
  final _ManualSourceSession session;

  void push(Float32List samples) => session.push(samples);

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return session;
  }
}

final class _ManualSourceSession implements AudioSourceSession {
  _ManualSourceSession(this.format, {required String id})
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

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: false,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  int _sequence = 0;
  int _sampleOffset = 0;

  void push(Float32List samples) {
    if (_frames.isClosed) {
      return;
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: samples,
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: _sequence,
        sampleOffset: _sampleOffset,
        timestamp: format.durationForFrames(_sampleOffset),
      ),
    );
    _sequence += 1;
    _sampleOffset += samples.length ~/ format.channels;
  }

  @override
  AudioSourceCapabilities get capabilities =>
      const AudioSourceCapabilities(isRealtime: true);

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _setState(AudioSessionState.active);
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Manual capture cannot pause.');

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Manual capture cannot resume.');

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    _closeFrames();
    _setState(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    _closeFrames();
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    _closeFrames();
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
  }

  void _closeFrames() {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
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

final class _ControlledSource implements AudioSource {
  _ControlledSource(AudioFormat format, {required String id})
    : session = _ControlledSourceSession(format, id: id);

  final _ControlledSourceSession session;

  Future<void> get started => session.started;

  void emit({required int sequence, required double sample}) =>
      session.emitBlock(
        sequence: sequence,
        samples: Float32List.fromList(<double>[sample]),
      );

  void emitBlock({required int sequence, required Float32List samples}) =>
      session.emitBlock(sequence: sequence, samples: samples);

  Future<void> finish() => session.finishNaturally();

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
  int _sampleOffset = 0;

  Future<void> get started => _started.future;

  void emitBlock({required int sequence, required Float32List samples}) {
    if (_status.state != AudioSessionState.active) {
      throw StateError('Source is not active.');
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: samples,
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: sequence,
        sampleOffset: _sampleOffset,
        timestamp: format.durationForFrames(_sampleOffset),
      ),
    );
    _sampleOffset += samples.length ~/ format.channels;
  }

  Future<void> finishNaturally() async {
    await _frames.close();
    _setState(AudioSessionState.finished);
  }

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

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Controlled source cannot pause.');

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Controlled source cannot resume.');

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _setState(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
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
  final List<_RecordingSinkSession> sessions = <_RecordingSinkSession>[];

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
    final _RecordingSinkSession session = _RecordingSinkSession(format);
    sessions.add(session);
    return session;
  }
}

final class _RecordingSinkSession implements AudioSinkSession {
  _RecordingSinkSession(this.format);

  @override
  final AudioFormat format;

  final List<AudioFrame> frames = <AudioFrame>[];
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.active,
    timestamp: Duration.zero,
  );

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
    frames.add(frame.copyWith());
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    _setState(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
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
