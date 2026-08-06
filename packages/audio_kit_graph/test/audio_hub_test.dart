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

  test(
    'a source that fails to stop does not cost a lossless route its queued tail',
    () async {
      final AudioFailure stopFailure = AudioFailure(
        code: 'native_stop_failed',
        stage: AudioFailureStage.capture,
        message: 'The native capture session could not be stopped.',
      );
      final _TestSource source = _TestSource(
        format,
        emitOnStart: false,
        stopFailure: stopFailure,
      );
      final AudioHub hub = await AudioHub.prepare(source);
      final _CollectingSink recorder = _CollectingSink(format, gated: true);
      final AudioRoute route = await hub.attach(
        id: 'recorder',
        sink: recorder,
        options: AudioRouteOptions.lossless(capacityFrames: 8),
      );
      await hub.start();

      const int frames = 5;
      for (var index = 0; index < frames; index++) {
        source.emit(index, 0.1 * (index + 1));
      }
      await _pump();

      // Every frame was admitted and none has reached the sink: one write is
      // in flight against the gate and the tail is queued in the mailbox.
      expect(route.metrics.acceptedFrames, frames);
      expect(route.metrics.currentDepth, frames - 1);
      expect(recorder.session.frames, isEmpty);

      Object? stopError;
      final Future<void> stopping = hub.stop().then<void>(
        (_) {},
        onError: (Object error, StackTrace _) => stopError = error,
      );
      await source.stopAttempted;
      // Let the failure path run as far as it can before the sink is allowed
      // to drain. Aborting the router here — which discards the queue before
      // the sink ever sees it — is exactly the regression this pins.
      await _pump();
      recorder.release();
      await stopping;

      expect(stopError, same(stopFailure));
      expect(hub.state, AudioSessionState.failed);
      expect(recorder.session.frames, hasLength(frames));
      expect(
        recorder.session.frames.map((AudioFrame frame) => frame.sequence),
        <int>[0, 1, 2, 3, 4],
      );
      expect(recorder.session.finished, isTrue);
      expect(recorder.session.abortedFailure, isNull);
      expect(route.state, AudioRouteState.finished);

      await hub.close();
    },
  );

  test(
    'a mid-capture source failure drains accepted frames before aborting',
    () async {
      final _TestSource source = _TestSource(format, emitOnStart: false);
      final AudioHub hub = await AudioHub.prepare(source);
      final _CollectingSink recorder = _CollectingSink(format, gated: true);
      final AudioRoute route = await hub.attach(
        id: 'recorder',
        sink: recorder,
        options: AudioRouteOptions.lossless(capacityFrames: 8),
      );
      await hub.start();

      const int frames = 5;
      for (var index = 0; index < frames; index++) {
        source.emit(index, 0.1 * (index + 1));
      }
      await _pump();

      expect(route.metrics.acceptedFrames, frames);
      expect(route.metrics.currentDepth, frames - 1);
      expect(recorder.session.frames, isEmpty);

      source.fail(StateError('the capture device disappeared'));
      // Same shape as the stop-failure case: the abort must not get to run
      // ahead of the drain.
      await _pump();
      recorder.release();
      await _eventually(() => hub.state == AudioSessionState.failed);

      expect(recorder.session.frames, hasLength(frames));
      expect(
        recorder.session.frames.map((AudioFrame frame) => frame.sequence),
        <int>[0, 1, 2, 3, 4],
      );
      // Every accepted frame was delivered, but the stream did NOT complete
      // normally: the sink is aborted with the stable failure — never
      // finished — so consumers can tell a salvaged tail from a clean stop.
      expect(recorder.session.finished, isFalse);
      expect(recorder.session.abortedFailure?.code, 'hub_source_failed');
      expect(route.state, AudioRouteState.aborted);

      // The dead source is still torn down, with the hub's stable failure.
      expect(source.aborted, isTrue);
      expect(source.status.state, AudioSessionState.failed);
      expect(source.status.failure?.code, 'hub_source_failed');

      await hub.close();
    },
  );
}

/// Yields to the event loop enough times for pending stream deliveries and
/// route work to settle.
Future<void> _pump([int times = 8]) async {
  for (var index = 0; index < times; index++) {
    await Future<void>.delayed(Duration.zero);
  }
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
  _TestSource(this.format, {this.emitOnStart = true, this.stopFailure});

  final AudioFormat format;
  final bool emitOnStart;

  /// Raised by [AudioSourceSession.stop] instead of stopping, modelling a
  /// native session whose teardown call fails.
  final AudioFailure? stopFailure;

  late final _TestSourceSession session = _TestSourceSession(
    format,
    emitOnStart: emitOnStart,
    stopFailure: stopFailure,
  );

  bool get hadListenerAtStart => session.hadListenerAtStart;
  bool get hadStatusListenerAtStart => session.hadStatusListenerAtStart;
  bool get closed => session.closed;
  bool get aborted => session.aborted;
  AudioSessionStatus get status => session.status;

  /// Completes as soon as `stop()` has been called, failing or not.
  Future<void> get stopAttempted => session.stopAttempted.future;

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
  _TestSourceSession(this.format, {required this.emitOnStart, this.stopFailure});

  @override
  final AudioFormat format;
  final bool emitOnStart;
  final AudioFailure? stopFailure;
  final Completer<void> stopAttempted = Completer<void>();
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
  bool aborted = false;

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
    if (!stopAttempted.isCompleted) {
      stopAttempted.complete();
    }
    final AudioFailure? failure = stopFailure;
    if (failure != null) {
      // A native session that cannot be stopped leaves its frame stream open
      // and its status non-terminal; only the hub's failure path tears it down.
      throw failure;
    }
    await _frames.close();
    _setState(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    aborted = true;
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
  _CollectingSink(this.format, {this.gated = false});

  final AudioFormat format;

  /// Holds every write until [release], so frames pile up in the route's
  /// mailbox instead of reaching the sink.
  final bool gated;

  late final _CollectingSinkSession session = _CollectingSinkSession(
    format,
    gated: gated,
  );

  void release() => session.release();

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
  _CollectingSinkSession(this.format, {bool gated = false})
    : _gate = gated ? Completer<void>() : null;

  @override
  final AudioFormat format;
  final Completer<void>? _gate;
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

  void release() {
    final Completer<void>? gate = _gate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    final Completer<void>? gate = _gate;
    if (gate != null) {
      await gate.future;
    }
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
