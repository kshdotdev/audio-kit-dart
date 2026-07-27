import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:test/test.dart';

void main() {
  final format = AudioFormat(sampleRate: 1000, channels: 1);

  AudioFrame frame(int sequence) => AudioFrame(
    format: format,
    samples: Float32List.fromList(<double>[
      sequence.toDouble(),
      sequence + 0.25,
    ]),
    sourceId: 'source',
    trackId: 'track',
    clockId: 'clock',
    sequence: sequence,
    sampleOffset: sequence * 2,
    timestamp: Duration(milliseconds: sequence * 2),
  );

  AudioFrame sizedFrame(int sequence, int sampleFrames) => AudioFrame(
    format: format,
    samples: Float32List.fromList(
      List<double>.filled(sampleFrames, sequence.toDouble()),
    ),
    sourceId: 'source',
    trackId: 'track',
    clockId: 'clock',
    sequence: sequence,
    sampleOffset: sequence * 100,
    timestamp: Duration(milliseconds: sequence * 100),
  );

  test('fans out identical ordered content to N independent routes', () async {
    final router = AudioRouter(format: format, upstreamPausable: false);
    final sinks = List<_FakeSink>.generate(3, (_) => _FakeSink(format));
    final routes = <AudioRoute>[
      for (var index = 0; index < sinks.length; index += 1)
        router.attach(
          id: 'route-$index',
          sink: sinks[index],
          options: AudioRouteOptions.lossless(),
        ),
    ];

    for (var sequence = 0; sequence < 20; sequence += 1) {
      final report = await router.add(frame(sequence));
      expect(report.acceptedByAll, isTrue);
    }
    await router.finish();

    for (var index = 0; index < sinks.length; index += 1) {
      expect(
        sinks[index].frames.map((value) => value.sequence),
        orderedEquals(List<int>.generate(20, (value) => value)),
      );
      expect(
        sinks[index].frames.expand((value) => value.samples),
        orderedEquals(
          List<double>.generate(
            40,
            (value) =>
                value.isEven ? (value ~/ 2).toDouble() : (value ~/ 2) + 0.25,
          ),
        ),
      );
      expect(routes[index].metrics.deliveredFrames, 20);
      expect(sinks[index].overlappingWrites, isFalse);
      expect(sinks[index].finished, isTrue);
      expect(sinks[index].closed, isTrue);
    }
    await router.close();
  });

  test('paused route observers cannot hold router shutdown open', () async {
    final AudioRouter router = AudioRouter(
      format: format,
      upstreamPausable: false,
    );
    final AudioRoute route = router.attach(
      id: 'observed',
      sink: _FakeSink(format),
      options: AudioRouteOptions.lossless(),
    );
    final StreamSubscription<AudioRouteEvent> routerObserver = router.events
        .listen((_) {});
    final StreamSubscription<AudioRouteEvent> routeObserver = route.events
        .listen((_) {});
    routerObserver.pause();
    routeObserver.pause();

    await router.close().timeout(const Duration(seconds: 1));
    await route.done.timeout(const Duration(seconds: 1));

    expect(route.state, AudioRouteState.finished);
    await routeObserver.cancel();
    await routerObserver.cancel();
  });

  test('sink failure terminates only its route', () async {
    final router = AudioRouter(format: format, upstreamPausable: false);
    final broken = _FakeSink(
      format,
      failWriteWhen: (value) => value.sequence == 1,
    );
    final healthy = _FakeSink(format);
    final brokenRoute = router.attach(
      id: 'broken',
      sink: broken,
      options: AudioRouteOptions.lossless(capacityFrames: 8),
    );
    final healthyRoute = router.attach(
      id: 'healthy',
      sink: healthy,
      options: AudioRouteOptions.lossless(capacityFrames: 8),
    );
    final failureEvents = brokenRoute.events
        .where((event) => event is AudioRouteFailed)
        .cast<AudioRouteFailed>()
        .toList();

    for (var sequence = 0; sequence < 4; sequence += 1) {
      await router.add(frame(sequence));
    }
    await brokenRoute.done;
    await router.finish();

    expect(brokenRoute.state, AudioRouteState.failed);
    expect(
      (await failureEvents).single.failure.code,
      'route_sink_write_failed',
    );
    expect(
      healthy.frames.map((value) => value.sequence),
      orderedEquals(<int>[0, 1, 2, 3]),
    );
    expect(healthyRoute.state, AudioRouteState.finished);
    await router.close();
  });

  test(
    'dropOldest remains bounded and marks the first frame after the gap',
    () async {
      final gate = Completer<void>();
      final sink = _FakeSink(format, firstWriteGate: gate.future);
      final router = AudioRouter(format: format, upstreamPausable: false);
      final route = router.attach(
        id: 'analysis',
        sink: sink,
        options: AudioRouteOptions(
          capacityFrames: 2,
          overflowPolicy: AudioOverflowPolicy.dropOldest,
        ),
      );
      final gaps = route.events
          .where((event) => event is AudioRouteGap)
          .cast<AudioRouteGap>()
          .toList();

      await router.add(frame(0));
      await sink.firstWriteStarted.future;
      await router.add(frame(1));
      await router.add(frame(2));
      await router.add(frame(3));
      expect(route.metrics.currentDepth, 2);
      expect(route.metrics.highWaterMark, 2);
      gate.complete();
      await router.finish();

      expect(
        sink.frames.map((value) => value.sequence),
        orderedEquals(<int>[0, 2, 3]),
      );
      expect(sink.frames[1].discontinuity?.droppedFrameCount, 1);
      expect(route.metrics.droppedFrames, 1);
      expect((await gaps).single.firstSequence, 1);
      await router.close();
    },
  );

  test('live dispatch is admitted synchronously into bounded routes', () async {
    final gate = Completer<void>();
    final sink = _FakeSink(format, firstWriteGate: gate.future);
    final router = AudioRouter(format: format, upstreamPausable: false);
    final route = router.attach(
      id: 'analysis',
      sink: sink,
      options: AudioRouteOptions(
        capacityFrames: 2,
        overflowPolicy: AudioOverflowPolicy.dropOldest,
      ),
    );

    for (var sequence = 0; sequence < 1000; sequence += 1) {
      unawaited(router.add(frame(sequence)));
    }

    // Admission and overflow accounting happen in the source callback's turn;
    // there is no separate unbounded router-dispatch queue ahead of this
    // route's two-frame mailbox.
    expect(route.metrics.currentDepth, 2);
    expect(route.metrics.highWaterMark, 2);
    expect(route.metrics.droppedFrames, 997);

    gate.complete();
    await router.finish();
    expect(
      sink.frames.map((AudioFrame value) => value.sequence),
      orderedEquals(<int>[0, 998, 999]),
    );
    await router.close();
  });

  test(
    'dropNewest reports a gap but does not mark an older queued frame',
    () async {
      final gate = Completer<void>();
      final sink = _FakeSink(format, firstWriteGate: gate.future);
      final router = AudioRouter(format: format, upstreamPausable: false);
      final route = router.attach(
        id: 'meter',
        sink: sink,
        options: AudioRouteOptions(
          capacityFrames: 1,
          overflowPolicy: AudioOverflowPolicy.dropNewest,
        ),
      );

      await router.add(frame(0));
      await sink.firstWriteStarted.future;
      await router.add(frame(1));
      final dropped = await router.add(frame(2));
      expect(dropped.outcomes['meter'], AudioDispatchOutcome.dropped);
      gate.complete();
      await _eventLoop();
      await router.add(frame(3));
      await router.finish();

      expect(
        sink.frames.map((value) => value.sequence),
        orderedEquals(<int>[0, 1, 3]),
      );
      expect(sink.frames[1].discontinuity, isNull);
      expect(sink.frames[2].discontinuity?.droppedFrameCount, 1);
      expect(route.metrics.droppedFrames, 1);
      await router.close();
    },
  );

  test('route loss is merged with an existing source discontinuity', () async {
    final gate = Completer<void>();
    final sink = _FakeSink(format, firstWriteGate: gate.future);
    final router = AudioRouter(format: format, upstreamPausable: false);
    final route = router.attach(
      id: 'merged-gap',
      sink: sink,
      options: AudioRouteOptions(
        capacityFrames: 1,
        overflowPolicy: AudioOverflowPolicy.dropOldest,
      ),
    );

    await router.add(frame(0));
    await sink.firstWriteStarted.future;
    await router.add(frame(1));
    await router.add(
      frame(2).copyWith(
        discontinuity: AudioDiscontinuity(
          reason: AudioDiscontinuityReason.sourceRestart,
          droppedSampleFrameCount: 5,
          description: 'The physical source restarted.',
        ),
      ),
    );
    gate.complete();
    await router.finish();

    final AudioDiscontinuity merged = sink.frames.last.discontinuity!;
    expect(merged.reason, AudioDiscontinuityReason.sourceRestart);
    expect(merged.droppedFrameCount, 1);
    expect(merged.droppedSampleFrameCount, 7);
    expect(merged.description, contains('also discarded'));
    expect(route.metrics.droppedFrames, 1);
    await router.close();
  });

  test(
    'failRoute overflow aborts that route while siblings continue',
    () async {
      final gate = Completer<void>();
      final slow = _FakeSink(format, firstWriteGate: gate.future);
      final healthy = _FakeSink(format);
      final router = AudioRouter(format: format, upstreamPausable: false);
      final failedRoute = router.attach(
        id: 'recorder',
        sink: slow,
        options: AudioRouteOptions.lossless(capacityFrames: 1),
      );
      router.attach(
        id: 'stt',
        sink: healthy,
        options: AudioRouteOptions.lossless(capacityFrames: 8),
      );

      await router.add(frame(0));
      await slow.firstWriteStarted.future;
      await router.add(frame(1));
      final report = await router.add(frame(2));
      expect(report.outcomes['recorder'], AudioDispatchOutcome.routeFailed);
      await failedRoute.done;
      gate.complete();
      await router.add(frame(3));
      await router.finish();

      expect(failedRoute.state, AudioRouteState.failed);
      expect(slow.aborted, isTrue);
      expect(
        healthy.frames.map((value) => value.sequence),
        orderedEquals(<int>[0, 1, 2, 3]),
      );
      await router.close();
    },
  );

  test('blockUpstream is rejected for live sources', () async {
    final sink = _FakeSink(format);
    final router = AudioRouter(format: format, upstreamPausable: false);

    expect(
      () => router.attach(
        id: 'invalid',
        sink: sink,
        options: AudioRouteOptions.blocking(),
      ),
      throwsArgumentError,
    );
    await sink.close();
    await router.close();
  });

  test('blockUpstream waits for bounded mailbox space', () async {
    final gate = Completer<void>();
    final sink = _FakeSink(format, firstWriteGate: gate.future);
    final router = AudioRouter(format: format, upstreamPausable: true);
    final route = router.attach(
      id: 'offline',
      sink: sink,
      options: AudioRouteOptions.blocking(capacityFrames: 1),
    );

    await router.add(frame(0));
    await sink.firstWriteStarted.future;
    await router.add(frame(1));
    var thirdCompleted = false;
    final third = router.add(frame(2)).then((value) {
      thirdCompleted = true;
      return value;
    });
    await _eventLoop();
    expect(thirdCompleted, isFalse);
    expect(route.metrics.currentDepth, 1);
    await expectLater(
      router.add(frame(3)),
      throwsA(isA<AudioRouterStateError>()),
    );
    expect(route.metrics.currentDepth, 1);

    gate.complete();
    await third;
    await router.finish();
    expect(
      sink.frames.map((value) => value.sequence),
      orderedEquals(<int>[0, 1, 2]),
    );
    await router.close();
  });

  test(
    'sample-frame bound rejects oversized audio and caps queue memory',
    () async {
      final gate = Completer<void>();
      final sink = _FakeSink(format, firstWriteGate: gate.future);
      final router = AudioRouter(format: format, upstreamPausable: false);
      final route = router.attach(
        id: 'bounded-analysis',
        sink: sink,
        options: AudioRouteOptions(
          capacityFrames: 10,
          capacitySampleFrames: 3,
          overflowPolicy: AudioOverflowPolicy.dropOldest,
        ),
      );

      await router.add(sizedFrame(0, 2));
      await sink.firstWriteStarted.future;
      await router.add(sizedFrame(1, 2));
      await router.add(sizedFrame(2, 2));
      final AudioDispatchReport oversized = await router.add(sizedFrame(3, 4));

      expect(
        oversized.outcomes['bounded-analysis'],
        AudioDispatchOutcome.dropped,
      );
      expect(route.metrics.currentDepth, 1);
      expect(route.metrics.currentQueuedSampleFrames, 2);
      expect(route.metrics.queuedSampleFramesHighWaterMark, 2);
      expect(route.metrics.droppedFrames, 2);

      gate.complete();
      await router.finish();
      expect(
        sink.frames.map((AudioFrame value) => value.sequence),
        orderedEquals(<int>[0, 2]),
      );
      await router.close();
    },
  );

  test('dynamic detach supports graceful drain and immediate abort', () async {
    final router = AudioRouter(format: format, upstreamPausable: false);
    final drainingSink = _FakeSink(format);
    final abortedSink = _FakeSink(format);
    final draining = router.attach(
      id: 'drain',
      sink: drainingSink,
      options: AudioRouteOptions.lossless(),
    );
    final aborted = router.attach(
      id: 'abort',
      sink: abortedSink,
      options: AudioRouteOptions.lossless(),
    );

    await router.add(frame(0));
    await draining.detach();
    await aborted.detach(drain: false);
    await router.add(frame(1));
    await router.finish();

    expect(drainingSink.frames.map((value) => value.sequence), <int>[0]);
    expect(draining.state, AudioRouteState.finished);
    expect(aborted.state, AudioRouteState.aborted);
    expect(abortedSink.aborted, isTrue);
    await router.close();
  });

  test(
    'route ID remains reserved until detached ownership is disposed',
    () async {
      final finishGate = Completer<void>();
      final firstSink = _FakeSink(format, finishGate: finishGate.future);
      final router = AudioRouter(format: format, upstreamPausable: false);
      final AudioRoute first = router.attach(
        id: 'reusable',
        sink: firstSink,
        options: AudioRouteOptions.lossless(),
      );
      await router.add(frame(0));

      final Future<void> detaching = first.detach();
      await firstSink.finishStarted.future;
      expect(
        () => router.attach(
          id: 'reusable',
          sink: _FakeSink(format),
          options: AudioRouteOptions.lossless(),
        ),
        throwsStateError,
      );

      finishGate.complete();
      await detaching;
      final _FakeSink replacement = _FakeSink(format);
      router.attach(
        id: 'reusable',
        sink: replacement,
        options: AudioRouteOptions.lossless(),
      );
      await router.add(frame(1));
      await router.finish();
      expect(replacement.frames.single.sequence, 1);
      await router.close();
    },
  );

  test('abort is idempotent and discards queued frames', () async {
    final gate = Completer<void>();
    final sink = _FakeSink(format, firstWriteGate: gate.future);
    final router = AudioRouter(format: format, upstreamPausable: false);
    final route = router.attach(
      id: 'route',
      sink: sink,
      options: AudioRouteOptions.lossless(capacityFrames: 4),
    );
    await router.add(frame(0));
    await sink.firstWriteStarted.future;
    await router.add(frame(1));

    final firstAbort = router.abort();
    final secondAbort = router.abort();
    gate.complete();
    await Future.wait(<Future<void>>[firstAbort, secondAbort]);

    expect(route.state, AudioRouteState.aborted);
    expect(sink.abortCalls, 1);
    expect(sink.closeCalls, 1);
    await router.close();
  });

  test('sink close failure marks the route failed before completion', () async {
    final sink = _FakeSink(format, failClose: true);
    final router = AudioRouter(format: format, upstreamPausable: false);
    final route = router.attach(
      id: 'close-failure',
      sink: sink,
      options: AudioRouteOptions.lossless(),
    );
    final Future<List<AudioRouteFailed>> failures = route.events
        .where((AudioRouteEvent event) => event is AudioRouteFailed)
        .cast<AudioRouteFailed>()
        .toList();

    await router.add(frame(0));
    await router.finish();

    expect(route.state, AudioRouteState.failed);
    expect((await failures).single.failure.code, 'route_sink_close_failed');
    expect(sink.closeCalls, 1);
    await router.close();
  });

  test('abort promptly interrupts sink finish before closing it', () async {
    final finishGate = Completer<void>();
    final sink = _FakeSink(format, finishGate: finishGate.future);
    final router = AudioRouter(format: format, upstreamPausable: false);
    final route = router.attach(
      id: 'finish-race',
      sink: sink,
      options: AudioRouteOptions.lossless(),
    );
    await router.add(frame(0));

    final Future<void> finishing = router.finish();
    await sink.finishStarted.future;
    final Future<void> aborting = router.abort();
    await Future.wait<void>(<Future<void>>[finishing, aborting]);

    expect(route.state, AudioRouteState.aborted);
    expect(sink.abortCalls, 1);
    expect(sink.abortOverlappedFinish, isTrue);
    expect(sink.closeCalls, 1);
    if (!finishGate.isCompleted) {
      finishGate.complete();
    }
    await router.close();
  });
}

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);

final class _FakeSink implements AudioSinkSession {
  _FakeSink(
    this.format, {
    this.firstWriteGate,
    this.finishGate,
    this.failWriteWhen,
    this.failClose = false,
  }) : _status = const AudioSessionStatus(
         state: AudioSessionState.prepared,
         timestamp: Duration.zero,
       );

  @override
  final AudioFormat format;

  final Future<void>? firstWriteGate;
  final Future<void>? finishGate;
  final bool Function(AudioFrame frame)? failWriteWhen;
  final bool failClose;
  final List<AudioFrame> frames = <AudioFrame>[];
  final Completer<void> firstWriteStarted = Completer<void>();
  final Completer<void> finishStarted = Completer<void>();
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status;
  bool _writeActive = false;
  bool overlappingWrites = false;
  bool finished = false;
  bool finishActive = false;
  bool aborted = false;
  bool abortOverlappedFinish = false;
  bool closed = false;
  int abortCalls = 0;
  int closeCalls = 0;

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
    if (_writeActive) {
      overlappingWrites = true;
    }
    _writeActive = true;
    if (!firstWriteStarted.isCompleted) {
      firstWriteStarted.complete();
      await firstWriteGate;
    }
    try {
      if (aborted) {
        throw StateError('sink was aborted');
      }
      if (failWriteWhen?.call(frame) ?? false) {
        throw StateError('deliberate sink failure');
      }
      frames.add(frame);
    } finally {
      _writeActive = false;
    }
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!finishStarted.isCompleted) {
      finishStarted.complete();
    }
    finishActive = true;
    try {
      final Future<void>? gate = finishGate;
      if (gate != null) {
        await Future.any<void>(<Future<void>>[
          gate,
          if (cancellationToken != null)
            cancellationToken.whenCancelled.then<void>((_) {
              cancellationToken.throwIfCancelled();
            }),
        ]);
      }
      cancellationToken?.throwIfCancelled();
      finished = true;
      _setState(AudioSessionState.finished);
    } finally {
      finishActive = false;
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    abortCalls += 1;
    abortOverlappedFinish = finishActive;
    aborted = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    if (closed) {
      return;
    }
    if (failClose) {
      throw StateError('deliberate close failure');
    }
    closed = true;
    _setState(AudioSessionState.closed);
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
