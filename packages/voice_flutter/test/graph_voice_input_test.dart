import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_core/speech_core.dart';
import 'package:voice_flutter/voice_flutter.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test('subscribes every branch before starting one shared source', () async {
    final _FakeAudioSource source = _FakeAudioSource(format);
    final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
    final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
    final GraphVoiceInput input = GraphVoiceInput(
      source: source,
      streamingSpeechToText: recognition,
      voiceActivityDetection: activity,
    );
    final List<SpeechRecognitionEvent> transcripts = <SpeechRecognitionEvent>[];
    final List<VoiceActivityEvent> voiceActivity = <VoiceActivityEvent>[];
    final StreamSubscription<SpeechRecognitionEvent> transcriptSubscription =
        input.transcripts.listen(transcripts.add);
    final StreamSubscription<VoiceActivityEvent> activitySubscription = input
        .voiceActivity
        .listen(voiceActivity.add);

    await input.start();
    final _FakeSourceSession capture = source.sessions.single;
    final _FakeRecognitionSession stt = recognition.sessions.single;
    final _FakeVoiceActivitySession vad = activity.sessions.single;
    capture.emit(0);
    await _eventually(() => stt.frames.length == 1 && vad.frames.length == 1);

    stt.emitFinal('hello');
    vad.emitStarted();

    expect(capture.hadFrameListenerAtStart, isTrue);
    expect(capture.hadStatusListenerAtStart, isTrue);
    expect(stt.hadResultListenerAtFirstWrite, isTrue);
    expect(vad.hadEventListenerAtFirstWrite, isTrue);
    expect(
      transcripts.whereType<RecognitionFinal>().single.transcript.text,
      'hello',
    );
    expect(voiceActivity.single, isA<VoiceActivityStarted>());
    expect(input.state, GraphVoiceInputState.active);

    await input.stop();
    expect(input.state, GraphVoiceInputState.idle);
    expect(capture.stopped, isTrue);
    expect(capture.closed, isTrue);
    expect(stt.finished, isTrue);
    expect(vad.finished, isTrue);

    await transcriptSubscription.cancel();
    await activitySubscription.cancel();
    await input.close();
    expect(recognition.closeCount, 0);
    expect(activity.closeCount, 0);
  });

  test(
    'builds and attaches optional routes before identical capture fan-out',
    () async {
      final _FakeAudioSource source = _FakeAudioSource(format);
      final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
      final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
      late final _FakeOptionalSink recorder;
      var builderCalls = 0;
      recorder = _FakeOptionalSink(
        onPrepare: () {
          expect(source.sessions.single.startEntered.isCompleted, isFalse);
        },
      );
      final GraphVoiceInput input = GraphVoiceInput(
        source: source,
        streamingSpeechToText: recognition,
        voiceActivityDetection: activity,
        extraRoutes: (AudioFormat sourceFormat) {
          builderCalls += 1;
          expect(sourceFormat, format);
          return <VoiceInputRoute>[
            VoiceInputRoute(
              id: 'session-recording',
              sink: recorder,
              options: AudioRouteOptions.lossless(capacityFrames: 4),
            ),
          ];
        },
      );

      await input.start();
      final _FakeSourceSession capture = source.sessions.single;
      final _FakeRecognitionSession stt = recognition.sessions.single;
      final _FakeVoiceActivitySession vad = activity.sessions.single;
      capture.emit(0);
      capture.emit(1);
      await _eventually(
        () =>
            stt.frames.length == 2 &&
            vad.frames.length == 2 &&
            recorder.onlySession.frames.length == 2,
      );

      expect(builderCalls, 1);
      expect(recorder.prepareCount, 1);
      expect(
        recorder.onlySession.frames.map((AudioFrame frame) => frame.sequence),
        stt.frames.map((AudioFrame frame) => frame.sequence),
      );
      expect(
        recorder.onlySession.frames.map(
          (AudioFrame frame) => frame.samples.single,
        ),
        vad.frames.map((AudioFrame frame) => frame.samples.single),
      );

      await input.stop();
      expect(recorder.onlySession.finished, isTrue);
      expect(recorder.onlySession.closed, isTrue);
      await input.close();
    },
  );

  test('optional route failure remains isolated from STT and VAD', () async {
    final _FakeAudioSource source = _FakeAudioSource(format);
    final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
    final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
    final _FakeOptionalSink failingAnalysis = _FakeOptionalSink(
      failWrites: true,
    );
    final GraphVoiceInput input = GraphVoiceInput(
      source: source,
      streamingSpeechToText: recognition,
      voiceActivityDetection: activity,
      extraRoutes: (_) => <VoiceInputRoute>[
        VoiceInputRoute(
          id: 'optional-analysis',
          sink: failingAnalysis,
          options: AudioRouteOptions.lossless(capacityFrames: 4),
        ),
      ],
    );
    final List<SpeechRecognitionEvent> transcripts = <SpeechRecognitionEvent>[];
    final StreamSubscription<SpeechRecognitionEvent> subscription = input
        .transcripts
        .listen(transcripts.add);

    await input.start();
    final _FakeSourceSession capture = source.sessions.single;
    final _FakeRecognitionSession stt = recognition.sessions.single;
    final _FakeVoiceActivitySession vad = activity.sessions.single;
    capture.emit(0);
    await _eventually(() => failingAnalysis.onlySession.closed);
    capture.emit(1);
    await _eventually(() => stt.frames.length == 2 && vad.frames.length == 2);
    stt.emitFinal('required branch survived');

    expect(input.state, GraphVoiceInputState.active);
    expect(stt.aborted, isFalse);
    expect(vad.aborted, isFalse);
    expect(
      transcripts.whereType<RecognitionFinal>().single.transcript.text,
      'required branch survived',
    );

    await input.stop();
    await subscription.cancel();
    await input.close();
  });

  for (final ({String name, List<String> ids}) scenario
      in <({String name, List<String> ids})>[
        (name: 'duplicate', ids: <String>['duplicate', 'duplicate']),
        (
          name: 'recognition reserved',
          ids: <String>[GraphVoiceInput.recognitionRouteId],
        ),
        (
          name: 'VAD reserved',
          ids: <String>[GraphVoiceInput.voiceActivityRouteId],
        ),
      ]) {
    test('rejects ${scenario.name} optional route IDs before attach', () async {
      final _FakeAudioSource source = _FakeAudioSource(format);
      final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
      final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
      final List<_FakeOptionalSink> sinks = <_FakeOptionalSink>[
        for (final _ in scenario.ids) _FakeOptionalSink(),
      ];
      final GraphVoiceInput input = GraphVoiceInput(
        source: source,
        streamingSpeechToText: recognition,
        voiceActivityDetection: activity,
        extraRoutes: (_) => <VoiceInputRoute>[
          for (var index = 0; index < scenario.ids.length; index += 1)
            VoiceInputRoute(
              id: scenario.ids[index],
              sink: sinks[index],
              options: AudioRouteOptions.lossless(),
            ),
        ],
      );

      await expectLater(input.start(), throwsArgumentError);

      expect(
        sinks.every((_FakeOptionalSink sink) => sink.prepareCount == 0),
        isTrue,
      );
      expect(recognition.sessions, isEmpty);
      expect(activity.sessions, isEmpty);
      expect(source.sessions.single.aborted, isTrue);
      expect(source.sessions.single.closed, isTrue);
      await input.close();
    });
  }

  test('optional route IDs must not be empty', () {
    expect(
      () => VoiceInputRoute(
        id: ' ',
        sink: _FakeOptionalSink(),
        options: AudioRouteOptions.lossless(),
      ),
      throwsArgumentError,
    );
  });

  test(
    'gating replaces STT while capture and VAD remain active for barge-in',
    () async {
      final _FakeAudioSource source = _FakeAudioSource(format);
      final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
      final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
      final GraphVoiceInput input = GraphVoiceInput(
        source: source,
        streamingSpeechToText: recognition,
        voiceActivityDetection: activity,
      );
      final AudioCancellationController sessionCancellation =
          AudioCancellationController();
      final List<SpeechRecognitionEvent> transcripts =
          <SpeechRecognitionEvent>[];
      final List<VoiceActivityEvent> activityEvents = <VoiceActivityEvent>[];
      final StreamSubscription<SpeechRecognitionEvent> transcriptSubscription =
          input.transcripts.listen(transcripts.add);
      final StreamSubscription<VoiceActivityEvent> activitySubscription = input
          .voiceActivity
          .listen(activityEvents.add);

      await input.start(cancellationToken: sessionCancellation.token);
      expect(sessionCancellation.activeRegistrationCount, 1);
      final _FakeSourceSession capture = source.sessions.single;
      final _FakeRecognitionSession firstStt = recognition.sessions.single;
      final _FakeVoiceActivitySession vad = activity.sessions.single;
      capture.emit(0);
      await _eventually(
        () => firstStt.frames.length == 1 && vad.frames.length == 1,
      );

      await input.setRecognitionEnabled(false);
      expect(input.isRecognitionEnabled, isFalse);
      expect(firstStt.aborted, isTrue);
      expect(firstStt.closed, isTrue);
      expect(vad.aborted, isFalse);
      expect(capture.stopped, isFalse);

      capture.emit(1);
      await _eventually(() => vad.frames.length == 2);
      vad.emitStarted();
      expect(activityEvents.single, isA<VoiceActivityStarted>());
      expect(firstStt.frames, hasLength(1));

      final AudioCancellationController enableCancellation =
          AudioCancellationController();
      await input.setRecognitionEnabled(
        true,
        cancellationToken: enableCancellation.token,
      );
      expect(enableCancellation.activeRegistrationCount, 0);
      expect(input.isRecognitionEnabled, isTrue);
      expect(recognition.sessions, hasLength(2));
      final _FakeRecognitionSession secondStt = recognition.sessions.last;

      capture.emit(2);
      await _eventually(
        () => secondStt.frames.length == 1 && vad.frames.length == 3,
      );
      secondStt.emitFinal('after interruption');
      expect(
        transcripts.whereType<RecognitionFinal>().single.transcript.text,
        'after interruption',
      );
      expect(source.sessions, hasLength(1));
      expect(activity.sessions, hasLength(1));

      await input.stop();
      expect(sessionCancellation.activeRegistrationCount, 0);
      await transcriptSubscription.cancel();
      await activitySubscription.cancel();
      await input.close();
    },
  );

  test('lossless STT overflow fails loudly and aborts the graph', () async {
    final Completer<void> firstWriteGate = Completer<void>();
    final _FakeAudioSource source = _FakeAudioSource(format);
    final _FakeRecognitionProvider recognition = _FakeRecognitionProvider(
      firstWriteGate: firstWriteGate.future,
    );
    final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
    final GraphVoiceInput input = GraphVoiceInput(
      source: source,
      streamingSpeechToText: recognition,
      voiceActivityDetection: activity,
      recognitionQueueCapacityFrames: 1,
      recognitionQueueCapacitySampleFrames: 16,
    );
    final List<RecognitionFailed> failures = <RecognitionFailed>[];
    final StreamSubscription<SpeechRecognitionEvent> subscription = input
        .transcripts
        .where((SpeechRecognitionEvent event) => event is RecognitionFailed)
        .cast<RecognitionFailed>()
        .listen(failures.add);

    await input.start();
    final _FakeSourceSession capture = source.sessions.single;
    final _FakeRecognitionSession stt = recognition.sessions.single;
    capture.emit(0);
    await stt.firstWriteStarted.future;
    capture.emit(1);
    capture.emit(2);
    await _eventually(() => failures.isNotEmpty);
    firstWriteGate.complete();
    await _eventually(() => stt.closed && activity.sessions.single.aborted);

    expect(failures.single.failure.code, 'route_overflow');
    expect(input.state, GraphVoiceInputState.failed);
    expect(stt.aborted, isTrue);
    expect(activity.sessions.single.aborted, isTrue);

    await subscription.cancel();
    await input.close();
  });

  test('recognizer preparation failure releases capture and VAD', () async {
    final _FakeAudioSource source = _FakeAudioSource(format);
    final _FakeRecognitionProvider recognition = _FakeRecognitionProvider(
      prepareFailure: StateError('model unavailable'),
    );
    final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
    final GraphVoiceInput input = GraphVoiceInput(
      source: source,
      streamingSpeechToText: recognition,
      voiceActivityDetection: activity,
    );
    final AudioCancellationController cancellation =
        AudioCancellationController();

    await expectLater(
      input.start(cancellationToken: cancellation.token),
      throwsStateError,
    );

    expect(input.state, GraphVoiceInputState.failed);
    expect(cancellation.activeRegistrationCount, 0);
    expect(source.sessions.single.aborted, isTrue);
    expect(source.sessions.single.closed, isTrue);
    expect(activity.sessions.single.aborted, isTrue);
    expect(activity.sessions.single.closed, isTrue);
    await input.close();
  });

  test(
    'external session cancellation aborts capture and unregisters',
    () async {
      final _FakeAudioSource source = _FakeAudioSource(format);
      final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
      final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
      final GraphVoiceInput input = GraphVoiceInput(
        source: source,
        streamingSpeechToText: recognition,
        voiceActivityDetection: activity,
      );
      final AudioCancellationController cancellation =
          AudioCancellationController();

      await input.start(cancellationToken: cancellation.token);
      expect(cancellation.activeRegistrationCount, 1);
      cancellation.cancel(
        const AudioCancellation(reason: 'conversation_cancelled'),
      );
      await _eventually(() => input.state == GraphVoiceInputState.idle);

      expect(cancellation.activeRegistrationCount, 0);
      expect(source.sessions.single.aborted, isTrue);
      expect(recognition.sessions.single.aborted, isTrue);
      expect(activity.sessions.single.aborted, isTrue);
      await input.close();
    },
  );

  test('stop and close deterministically join an in-flight start', () async {
    final Completer<void> startGate = Completer<void>();
    final _FakeAudioSource source = _FakeAudioSource(
      format,
      startGate: startGate.future,
    );
    final _FakeRecognitionProvider recognition = _FakeRecognitionProvider();
    final _FakeVoiceActivityProvider activity = _FakeVoiceActivityProvider();
    final GraphVoiceInput input = GraphVoiceInput(
      source: source,
      streamingSpeechToText: recognition,
      voiceActivityDetection: activity,
    );
    final AudioCancellationController cancellation =
        AudioCancellationController();

    final Future<void> starting = input.start(
      cancellationToken: cancellation.token,
    );
    await _eventually(() => source.sessions.isNotEmpty);
    await source.sessions.single.startEntered.future;
    final Future<void> firstStop = input.stop();
    final Future<void> secondStop = input.stop();
    expect(identical(firstStop, secondStop), isTrue);
    final Future<void> firstClose = input.close();
    final Future<void> secondClose = input.close();
    expect(identical(firstClose, secondClose), isTrue);
    startGate.complete();

    await expectLater(starting, throwsA(isA<AudioCancelledException>()));
    await firstStop;
    await firstClose;

    expect(input.state, GraphVoiceInputState.closed);
    expect(cancellation.activeRegistrationCount, 0);
    expect(source.sessions.single.closeCount, 1);
    expect(recognition.sessions.single.closeCount, 1);
    expect(activity.sessions.single.closeCount, 1);
  });
}

Future<void> _eventually(bool Function() condition) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 2)) {
      fail('Condition was not reached.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeAudioSource implements AudioSource {
  _FakeAudioSource(this.format, {this.startGate});

  final AudioFormat format;
  final Future<void>? startGate;
  final List<_FakeSourceSession> sessions = <_FakeSourceSession>[];

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final _FakeSourceSession session = _FakeSourceSession(
      format,
      startGate: startGate,
    );
    sessions.add(session);
    return session;
  }
}

final class _FakeSourceSession implements AudioSourceSession {
  _FakeSourceSession(this.format, {this.startGate});

  @override
  final AudioFormat format;
  final Future<void>? startGate;
  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast(sync: true);
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Completer<void> startEntered = Completer<void>();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  bool hadFrameListenerAtStart = false;
  bool hadStatusListenerAtStart = false;
  bool stopped = false;
  bool aborted = false;
  bool closed = false;
  int closeCount = 0;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.realtime;

  @override
  String get clockId => 'voice-clock';

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  String get sourceId => 'voice-source';

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  String get trackId => 'microphone';

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    hadFrameListenerAtStart = _frames.hasListener;
    hadStatusListenerAtStart = _statuses.hasListener;
    if (!startEntered.isCompleted) {
      startEntered.complete();
    }
    await startGate;
    cancellationToken?.throwIfCancelled();
    _setState(AudioSessionState.active);
  }

  void emit(int sequence) {
    if (_frames.isClosed) {
      return;
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: Float32List.fromList(<double>[sequence / 10]),
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: sequence,
        sampleOffset: sequence,
        timestamp: format.durationForFrames(sequence),
      ),
    );
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    stopped = true;
    if (!_frames.isClosed) {
      await _frames.close();
    }
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
    closeCount += 1;
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError('Live test capture cannot pause.');
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError('Live test capture cannot resume.');
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

final class _FakeRecognitionProvider implements StreamingSpeechToTextProvider {
  _FakeRecognitionProvider({this.firstWriteGate, this.prepareFailure});

  final Future<void>? firstWriteGate;
  final Object? prepareFailure;
  final List<_FakeRecognitionSession> sessions = <_FakeRecognitionSession>[];
  int closeCount = 0;

  @override
  final SpeechProviderDescriptor descriptor = SpeechProviderDescriptor(
    id: 'fake-stt',
    displayName: 'Fake STT',
    capabilities: const <SpeechCapability>{
      SpeechCapability.streamingSpeechToText,
    },
  );

  @override
  Future<StreamingSpeechToTextSession> prepareStreamingRecognition(
    StreamingRecognitionRequest request,
  ) async {
    request.cancellation?.throwIfCancelled();
    final Object? failure = prepareFailure;
    if (failure != null) {
      throw failure;
    }
    final _FakeRecognitionSession session = _FakeRecognitionSession(
      request.inputFormat,
      cancellation: request.cancellation,
      firstWriteGate: firstWriteGate,
    );
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _FakeVoiceActivityProvider
    implements VoiceActivityDetectionProvider {
  final List<_FakeVoiceActivitySession> sessions =
      <_FakeVoiceActivitySession>[];
  int closeCount = 0;

  @override
  final SpeechProviderDescriptor descriptor = SpeechProviderDescriptor(
    id: 'fake-vad',
    displayName: 'Fake VAD',
    capabilities: const <SpeechCapability>{
      SpeechCapability.voiceActivityDetection,
    },
  );

  @override
  Future<VoiceActivityDetectionSession> prepareVoiceActivityDetection(
    VoiceActivityDetectionRequest request,
  ) async {
    request.cancellation?.throwIfCancelled();
    final _FakeVoiceActivitySession session = _FakeVoiceActivitySession(
      request.inputFormat,
      cancellation: request.cancellation,
    );
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

abstract class _FakeSinkSession implements AudioSinkSession {
  _FakeSinkSession(
    this.format, {
    AudioCancellationToken? cancellation,
    this.firstWriteGate,
  }) : _cancellationRegistration = cancellation?.register((_) {});

  @override
  final AudioFormat format;
  final Future<void>? firstWriteGate;
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Completer<void> firstWriteStarted = Completer<void>();
  AudioCancellationRegistration? _cancellationRegistration;
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  final List<AudioFrame> frames = <AudioFrame>[];
  bool finished = false;
  bool aborted = false;
  bool closed = false;
  int closeCount = 0;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  bool get hasTypedObserver;

  void closeTypedEvents();

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (!firstWriteStarted.isCompleted) {
      firstWriteStarted.complete();
    }
    await firstWriteGate;
    cancellationToken?.throwIfCancelled();
    frames.add(frame.copyWith());
    _setState(AudioSessionState.active);
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    finished = true;
    _setState(AudioSessionState.finishing);
    _setState(AudioSessionState.finished);
    closeTypedEvents();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (finished || closed || aborted) {
      return;
    }
    aborted = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    closeTypedEvents();
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    closeCount += 1;
    _cancellationRegistration?.dispose();
    _cancellationRegistration = null;
    closeTypedEvents();
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

final class _FakeRecognitionSession extends _FakeSinkSession
    implements StreamingSpeechToTextSession {
  _FakeRecognitionSession(
    super.format, {
    super.cancellation,
    super.firstWriteGate,
  });

  final StreamController<SpeechRecognitionEvent> _results =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  bool hadResultListenerAtFirstWrite = false;
  int _segment = 0;

  @override
  Stream<SpeechRecognitionEvent> get results => _results.stream;

  @override
  bool get hasTypedObserver => _results.hasListener;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    if (frames.isEmpty) {
      hadResultListenerAtFirstWrite = _results.hasListener;
    }
    return super.write(frame, cancellationToken: cancellationToken);
  }

  void emitFinal(String text) {
    if (_results.isClosed) {
      return;
    }
    _segment += 1;
    _results.add(
      RecognitionFinal(
        transcript: SpeechTranscript(text: text),
        segmentId: 'segment-$_segment',
        at: Duration.zero,
      ),
    );
  }

  @override
  void closeTypedEvents() {
    if (!_results.isClosed) {
      unawaited(_results.close());
    }
  }
}

final class _FakeVoiceActivitySession extends _FakeSinkSession
    implements VoiceActivityDetectionSession {
  _FakeVoiceActivitySession(super.format, {super.cancellation});

  final StreamController<VoiceActivityEvent> _events =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);
  bool hadEventListenerAtFirstWrite = false;

  @override
  Stream<VoiceActivityEvent> get events => _events.stream;

  @override
  bool get hasTypedObserver => _events.hasListener;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    if (frames.isEmpty) {
      hadEventListenerAtFirstWrite = _events.hasListener;
    }
    return super.write(frame, cancellationToken: cancellationToken);
  }

  void emitStarted() {
    if (!_events.isClosed) {
      _events.add(VoiceActivityStarted(probability: 0.95, at: Duration.zero));
    }
  }

  @override
  void closeTypedEvents() {
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }
}

final class _FakeOptionalSink implements AudioSink {
  _FakeOptionalSink({this.onPrepare, this.failWrites = false});

  final void Function()? onPrepare;
  final bool failWrites;
  final List<_FakeOptionalSession> sessions = <_FakeOptionalSession>[];
  int prepareCount = 0;

  _FakeOptionalSession get onlySession => sessions.single;

  @override
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    onPrepare?.call();
    prepareCount += 1;
    final _FakeOptionalSession session = _FakeOptionalSession(
      format,
      failWrites: failWrites,
    );
    sessions.add(session);
    return session;
  }
}

final class _FakeOptionalSession extends _FakeSinkSession {
  _FakeOptionalSession(super.format, {required this.failWrites});

  final bool failWrites;

  @override
  bool get hasTypedObserver => true;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    if (failWrites) {
      return Future<void>.error(StateError('optional route failed'));
    }
    return super.write(frame, cancellationToken: cancellationToken);
  }

  @override
  void closeTypedEvents() {}
}
