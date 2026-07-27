import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:test/test.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test(
    'subscribes before source start and fans one source into N sinks',
    () async {
      final _TestSource source = _TestSource(format);
      final AudioHub hub = await AudioHub.prepare(source);
      final _CollectingSink recorder = _CollectingSink(format);
      final _CollectingSink speech = _CollectingSink(format);
      await hub.attach(
        id: 'recorder',
        sink: recorder,
        options: AudioRouteOptions.lossless(capacityFrames: 4),
      );
      await hub.attach(
        id: 'speech',
        sink: speech,
        options: AudioRouteOptions.realtime(capacityFrames: 4),
      );

      await hub.start();
      await hub.stop();

      expect(source.hadListenerAtStart, isTrue);
      expect(source.hadStatusListenerAtStart, isTrue);
      expect(recorder.session.frames, hasLength(2));
      expect(speech.session.frames, hasLength(2));
      expect(
        recorder.session.frames.map((AudioFrame frame) => frame.samples.single),
        <double>[0.25, 0.5],
      );
      expect(
        speech.session.frames.map((AudioFrame frame) => frame.sequence),
        <int>[0, 1],
      );
      expect(recorder.session.finished, isTrue);
      expect(speech.session.finished, isTrue);

      await hub.close();
      expect(source.closed, isTrue);
      expect(recorder.session.closed, isTrue);
      expect(speech.session.closed, isTrue);
    },
  );

  test(
    'can dynamically attach and detach a latest-only analysis branch',
    () async {
      final _TestSource source = _TestSource(format, emitOnStart: false);
      final AudioHub hub = await AudioHub.prepare(source);
      await hub.start();
      final _CollectingSink meter = _CollectingSink(format);
      final AudioRoute route = await hub.attach(
        id: 'meter',
        sink: meter,
        options: AudioRouteOptions.latestOnly(),
      );

      source.emit(0, 0.1);
      await _eventually(() => meter.session.frames.length == 1);
      await route.detach();
      source.emit(1, 0.2);
      await Future<void>.delayed(Duration.zero);

      expect(meter.session.frames, hasLength(1));
      expect(route.state, AudioRouteState.finished);
      await hub.stop();
      await hub.close();
    },
  );

  test('source failure aborts each route with a stable failure', () async {
    final _TestSource source = _TestSource(format, emitOnStart: false);
    final AudioHub hub = await AudioHub.prepare(source);
    final _CollectingSink sink = _CollectingSink(format);
    await hub.attach(
      id: 'speech',
      sink: sink,
      options: AudioRouteOptions.lossless(),
    );
    await hub.start();

    source.fail(StateError('capture failed'));
    await _eventually(() => hub.state == AudioSessionState.failed);

    expect(sink.session.abortedFailure?.code, 'hub_source_failed');
    await hub.close();
  });

  test(
    'terminal failure status wins over an earlier frame-stream EOS',
    () async {
      final _TestSource source = _TestSource(format, emitOnStart: false);
      final AudioHub hub = await AudioHub.prepare(source);
      final _CollectingSink sink = _CollectingSink(format);
      await hub.attach(
        id: 'recorder',
        sink: sink,
        options: AudioRouteOptions.lossless(),
      );
      await hub.start();

      await source.failAfterEnd(
        AudioFailure(
          code: 'native_capture_overflow',
          stage: AudioFailureStage.capture,
          message: 'Native capture overflowed.',
        ),
      );
      await _eventually(() => hub.state == AudioSessionState.failed);

      expect(hub.state, AudioSessionState.failed);
      expect(sink.session.finished, isFalse);
      expect(sink.session.abortedFailure?.code, 'native_capture_overflow');
      await hub.close();
    },
  );
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

final class _TestSource implements AudioSource {
  _TestSource(this.format, {this.emitOnStart = true});

  final AudioFormat format;
  final bool emitOnStart;
  late final _TestSourceSession session = _TestSourceSession(
    format,
    emitOnStart: emitOnStart,
  );

  bool get hadListenerAtStart => session.hadListenerAtStart;
  bool get hadStatusListenerAtStart => session.hadStatusListenerAtStart;
  bool get closed => session.closed;

  void emit(int sequence, double sample) => session.emit(sequence, sample);
  void fail(Object error) => session.fail(error);
  Future<void> failAfterEnd(AudioFailure failure) =>
      session.failAfterEnd(failure);

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async => session;
}

final class _TestSourceSession implements AudioSourceSession {
  _TestSourceSession(this.format, {required this.emitOnStart});

  @override
  final AudioFormat format;
  final bool emitOnStart;
  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast();
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  bool hadListenerAtStart = false;
  bool hadStatusListenerAtStart = false;
  bool closed = false;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.realtime;

  @override
  String get clockId => 'clock';

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  String get sourceId => 'source';

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  String get trackId => 'track';

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    hadListenerAtStart = _frames.hasListener;
    hadStatusListenerAtStart = _statuses.hasListener;
    _setState(AudioSessionState.active);
    if (emitOnStart) {
      emit(0, 0.25);
      emit(1, 0.5);
    }
  }

  void emit(int sequence, double sample) {
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

  void fail(Object error) => _frames.addError(error);

  Future<void> failAfterEnd(AudioFailure failure) async {
    await _frames.close();
    await Future<void>.delayed(Duration.zero);
    _setState(AudioSessionState.failed, failure: failure);
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    await _frames.close();
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
    if (closed) {
      return;
    }
    closed = true;
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _setState(AudioSessionState.closed);
    await _statuses.close();
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {}

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {}

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

final class _CollectingSink implements AudioSink {
  _CollectingSink(this.format);

  final AudioFormat format;
  late final _CollectingSinkSession session = _CollectingSinkSession(format);

  @override
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    expect(format, this.format);
    return session;
  }
}

final class _CollectingSinkSession implements AudioSinkSession {
  _CollectingSinkSession(this.format);

  @override
  final AudioFormat format;
  final List<AudioFrame> frames = <AudioFrame>[];
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.active,
    timestamp: Duration.zero,
  );
  bool finished = false;
  bool closed = false;
  AudioFailure? abortedFailure;

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
    frames.add(frame.copyWith());
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    finished = true;
    _status = const AudioSessionStatus(
      state: AudioSessionState.finished,
      timestamp: Duration.zero,
    );
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    abortedFailure = failure;
    _status = AudioSessionStatus(
      state: AudioSessionState.aborted,
      timestamp: Duration.zero,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    _status = const AudioSessionStatus(
      state: AudioSessionState.closed,
      timestamp: Duration.zero,
    );
    await _statuses.close();
  }
}
