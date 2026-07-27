import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';
import 'package:voice_core/voice_core.dart';

void main() {
  test('subscribes before input start and exposes separate states', () async {
    final input = _FakeVoiceInput(
      onStart: (input) {
        input.transcriptEvents.add(
          RecognitionPartial(
            transcript: SpeechTranscript(text: 'early'),
            revision: 1,
            at: Duration.zero,
          ),
        );
      },
    );
    final controller = _controller(
      input: input,
      backend: _FakeBackend.immediate(),
    );
    addTearDown(controller.close);

    await controller.start();

    expect(controller.current.sessionState, VoiceSessionState.active);
    expect(controller.current.turnState, VoiceTurnState.listening);
    expect(controller.current.interimTranscript, 'early');
  });

  test('segments backend text and serializes synthesis', () async {
    final input = _FakeVoiceInput();
    final output = _FakeOutput();
    final controller = _controller(
      input: input,
      output: output,
      backend: _FakeBackend(
        (_) => Stream<VoiceBackendEvent>.fromIterable(const [
          VoiceNarrativeStarted(),
          VoiceNarrativeDelta('Hello there. How are you?'),
          VoiceNarrativeEnded(),
          VoiceBackendCompleted(),
        ]),
      ),
    );
    addTearDown(controller.close);
    await controller.start();

    input.finalTranscript('question');
    await _waitFor(
      () =>
          controller.current.turnState == VoiceTurnState.listening &&
          output.spoken.length == 2,
    );

    expect(output.spoken, ['Hello there.', 'How are you?']);
    expect(output.maximumConcurrentPlayback, 1);
    expect(input.recognitionEnabled, containsAllInOrder([false, false, true]));
  });

  test(
    'explicit backend completion settles and cancels an open stream',
    () async {
      final Completer<void> cancelled = Completer<void>();
      final StreamController<VoiceBackendEvent> events =
          StreamController<VoiceBackendEvent>.broadcast(
            sync: true,
            onCancel: () {
              if (!cancelled.isCompleted) {
                cancelled.complete();
              }
            },
          );
      final input = _FakeVoiceInput();
      final output = _FakeOutput();
      final controller = _controller(
        input: input,
        output: output,
        backend: _FakeBackend((_) => events.stream),
      );
      addTearDown(() async {
        await controller.close();
        await events.close();
      });
      await controller.start();

      input.finalTranscript('complete explicitly');
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.thinking,
      );
      events
        ..add(const VoiceNarrativeDelta('Pending sentence without punctuation'))
        ..add(const VoiceBackendCompleted());

      await cancelled.future;
      await _waitFor(
        () =>
            controller.current.turnState == VoiceTurnState.listening &&
            output.spoken.length == 1,
      );
      final String completedText = controller.current.responseText;
      events.add(const VoiceNarrativeDelta(' stale'));
      await pumpEventQueue();

      expect(output.spoken, <String>['Pending sentence without punctuation']);
      expect(controller.current.responseText, completedText);
    },
  );

  test('new final transcript rejects stale backend generation', () async {
    final first = StreamController<VoiceBackendEvent>();
    final input = _FakeVoiceInput();
    final backend = _FakeBackend((request) {
      if (request.transcript == 'first') {
        return first.stream;
      }
      return Stream<VoiceBackendEvent>.fromIterable(const [
        VoiceNarrativeDelta('Fresh response.'),
        VoiceNarrativeEnded(),
      ]);
    });
    final controller = _controller(input: input, backend: backend);
    addTearDown(() async {
      await first.close();
      await controller.close();
    });
    await controller.start();

    input.finalTranscript('first');
    await _waitFor(() => backend.requests.length == 1);
    final firstToken = backend.requests.single.cancellationToken;

    input.finalTranscript('second');
    await _waitFor(
      () =>
          controller.current.turnState == VoiceTurnState.listening &&
          backend.requests.length == 2,
    );
    first.add(const VoiceNarrativeDelta('stale'));
    await pumpEventQueue();

    expect(firstToken.isCancelled, isTrue);
    expect(controller.current.finalTranscript, 'second');
    expect(controller.current.responseText, 'Fresh response.');
  });

  test(
    'overlapping final transcripts cannot move synthesis backwards',
    () async {
      final cancelStarted = Completer<void>();
      final allowCancel = Completer<void>();
      final first = StreamController<VoiceBackendEvent>(
        onCancel: () {
          if (!cancelStarted.isCompleted) {
            cancelStarted.complete();
          }
          return allowCancel.future;
        },
      );
      final input = _FakeVoiceInput();
      final backend = _FakeBackend((request) {
        if (request.transcript == 'first') {
          return first.stream;
        }
        return const Stream<VoiceBackendEvent>.empty();
      });
      final controller = _controller(input: input, backend: backend);
      addTearDown(() async {
        if (!allowCancel.isCompleted) {
          allowCancel.complete();
        }
        await first.close();
        await controller.close();
      });
      await controller.start();

      input.finalTranscript('first');
      await _waitFor(() => backend.requests.length == 1);
      input.finalTranscript('second');
      await cancelStarted.future;
      input.finalTranscript('third');
      await _waitFor(() => controller.current.finalTranscript == 'third');
      allowCancel.complete();
      await _waitFor(
        () =>
            backend.requests.length == 2 &&
            controller.current.turnState == VoiceTurnState.listening,
      );

      expect(
        backend.requests.map((VoiceBackendRequest value) => value.transcript),
        <String>['first', 'third'],
      );
      expect(controller.current.finalTranscript, 'third');
    },
  );

  test('stop wins over a cancellation-insensitive input startup', () async {
    final startGate = Completer<void>();
    final input = _FakeVoiceInput(
      startGate: startGate.future,
      ignoreStartCancellation: true,
    );
    final controller = _controller(
      input: input,
      backend: _FakeBackend.immediate(),
    );
    addTearDown(controller.close);

    final Future<void> starting = controller.start();
    await _waitFor(
      () => controller.current.sessionState == VoiceSessionState.preparing,
    );
    await controller.stop();
    expect(controller.current.sessionState, VoiceSessionState.idle);

    startGate.complete();
    await starting;

    expect(controller.current.sessionState, VoiceSessionState.idle);
    expect(controller.current.turnState, VoiceTurnState.idle);
    expect(input.isCapturing, isFalse);
    expect(input.stopCount, greaterThanOrEqualTo(2));
  });

  test(
    'start after stop queues behind cancellation-insensitive startup',
    () async {
      final Completer<void> startGate = Completer<void>();
      final input = _FakeVoiceInput(
        startGate: startGate.future,
        ignoreStartCancellation: true,
      );
      final controller = _controller(
        input: input,
        backend: _FakeBackend.immediate(),
      );
      addTearDown(controller.close);

      final Future<void> firstStart = controller.start();
      await _waitFor(
        () => controller.current.sessionState == VoiceSessionState.preparing,
      );
      await controller.stop();
      final Future<void> restart = controller.start();
      startGate.complete();
      await Future.wait<void>(<Future<void>>[firstStart, restart]);

      expect(controller.current.sessionState, VoiceSessionState.active);
      expect(controller.current.turnState, VoiceTurnState.listening);
      expect(input.startCount, 2);
      expect(input.isCapturing, isTrue);
    },
  );

  test('close rejects a restart queued behind stale startup', () async {
    final Completer<void> startGate = Completer<void>();
    final input = _FakeVoiceInput(
      startGate: startGate.future,
      ignoreStartCancellation: true,
    );
    final controller = _controller(
      input: input,
      backend: _FakeBackend.immediate(),
    );

    final Future<void> firstStart = controller.start();
    await _waitFor(
      () => controller.current.sessionState == VoiceSessionState.preparing,
    );
    await controller.stop();
    final Future<void> restart = controller.start();
    final Future<void> closing = controller.close();
    startGate.complete();

    await firstStart;
    await expectLater(restart, throwsStateError);
    await closing;
    expect(controller.current.sessionState, VoiceSessionState.closed);
    expect(input.startCount, 1);
    expect(input.closeCount, 1);
  });

  test(
    'VAD barge-in cancels playback but keeps recognition available',
    () async {
      final input = _FakeVoiceInput();
      final output = _FakeOutput(blockPlayback: true);
      final controller = _controller(
        input: input,
        output: output,
        backend: _FakeBackend(
          (_) => Stream<VoiceBackendEvent>.fromIterable(const [
            VoiceNarrativeDelta('A sufficiently complete sentence.'),
            VoiceNarrativeEnded(),
          ]),
        ),
      );
      addTearDown(controller.close);
      await controller.start();

      input.finalTranscript('speak');
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.speaking,
      );
      final speakingGeneration = controller.current.generationId;
      input.activityEvents.add(
        VoiceActivityStarted(probability: 0.95, at: Duration(milliseconds: 10)),
      );
      await _waitFor(
        () =>
            controller.current.turnState == VoiceTurnState.interrupted &&
            input.recognitionEnabled.isNotEmpty &&
            input.recognitionEnabled.last,
      );

      expect(controller.current.generationId, speakingGeneration + 1);
      expect(input.recognitionEnabled.last, isTrue);
      expect(output.interruptCount, greaterThanOrEqualTo(2));

      input.transcriptEvents.add(
        RecognitionSpeechStarted(at: Duration(milliseconds: 20)),
      );
      await pumpEventQueue();
      expect(controller.current.turnState, VoiceTurnState.listening);
    },
  );

  test(
    'barge-in interrupts playback before a slow backend cancellation settles',
    () async {
      final Completer<void> cancellationStarted = Completer<void>();
      final Completer<void> allowCancellation = Completer<void>();
      final StreamController<VoiceBackendEvent> events =
          StreamController<VoiceBackendEvent>(
            onCancel: () {
              if (!cancellationStarted.isCompleted) {
                cancellationStarted.complete();
              }
              return allowCancellation.future;
            },
          );
      final _FakeVoiceInput input = _FakeVoiceInput();
      final _FakeOutput output = _FakeOutput(blockPlayback: true);
      final VoiceConversationController controller = _controller(
        input: input,
        output: output,
        backend: _FakeBackend((_) => events.stream),
      );
      addTearDown(() async {
        if (!allowCancellation.isCompleted) {
          allowCancellation.complete();
        }
        await controller.close();
        await events.close();
      });
      await controller.start();

      input.finalTranscript('speak');
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.thinking,
      );
      events.add(const VoiceNarrativeDelta('A complete spoken sentence.'));
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.speaking,
      );
      final int interruptsBeforeBargeIn = output.interruptCount;

      input.activityEvents.add(
        VoiceActivityStarted(probability: 0.95, at: Duration(milliseconds: 10)),
      );
      await cancellationStarted.future;
      await _waitFor(
        () =>
            output.interruptCount > interruptsBeforeBargeIn &&
            input.recognitionEnabled.isNotEmpty &&
            input.recognitionEnabled.last,
      );

      expect(allowCancellation.isCompleted, isFalse);
      expect(controller.current.turnState, VoiceTurnState.interrupted);

      allowCancellation.complete();
    },
  );

  test('backend failure is safe and recognition resumes', () async {
    final input = _FakeVoiceInput();
    final controller = _controller(
      input: input,
      backend: _FakeBackend(
        (_) => Stream<VoiceBackendEvent>.error(
          StateError('secret provider payload'),
        ),
      ),
    );
    addTearDown(controller.close);
    await controller.start();

    input.finalTranscript('fail');
    await _waitFor(() => controller.current.failure != null);

    expect(controller.current.sessionState, VoiceSessionState.active);
    expect(controller.current.turnState, VoiceTurnState.listening);
    expect(
      controller.current.failure?.message,
      'The voice operation could not be completed.',
    );
    expect(
      controller.current.failure.toString(),
      isNot(contains('secret provider payload')),
    );
    expect(input.recognitionEnabled.last, isTrue);
  });

  test('close is idempotent and closes owned dependencies once', () async {
    final input = _FakeVoiceInput();
    final backend = _FakeBackend.immediate();
    final synthesizer = _FakeSynthesizer();
    final output = _FakeOutput();
    final controller = VoiceConversationController(
      input: input,
      backend: backend,
      synthesizer: synthesizer,
      output: output,
    );
    await controller.start();

    await controller.close();
    await controller.close();

    expect(controller.current.sessionState, VoiceSessionState.closed);
    expect(input.closeCount, 1);
    expect(backend.closeCount, 1);
    expect(synthesizer.closeCount, 1);
    expect(output.closeCount, 1);
  });

  test('paused observers cannot hang controller close', () async {
    final controller = _controller(
      input: _FakeVoiceInput(),
      backend: _FakeBackend.immediate(),
    );
    final StreamSubscription<VoiceConversationSnapshot> snapshotObserver =
        controller.snapshots.listen((_) {});
    final StreamSubscription<VoiceBackendEvent> backendObserver = controller
        .backendEvents
        .listen((_) {});
    snapshotObserver.pause();
    backendObserver.pause();

    await controller.close().timeout(const Duration(seconds: 1));

    expect(controller.current.sessionState, VoiceSessionState.closed);
    await backendObserver.cancel();
    await snapshotObserver.cancel();
  });
}

VoiceConversationController _controller({
  required _FakeVoiceInput input,
  required _FakeBackend backend,
  _FakeOutput? output,
}) => VoiceConversationController(
  input: input,
  backend: backend,
  synthesizer: _FakeSynthesizer(),
  output: output ?? _FakeOutput(),
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await pumpEventQueue(times: 1);
  }
  fail('Condition was not reached.');
}

final class _FakeVoiceInput implements VoiceInput {
  _FakeVoiceInput({
    this.onStart,
    this.startGate,
    this.ignoreStartCancellation = false,
  });

  final void Function(_FakeVoiceInput input)? onStart;
  final Future<void>? startGate;
  final bool ignoreStartCancellation;
  final StreamController<SpeechRecognitionEvent> transcriptEvents =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  final StreamController<VoiceActivityEvent> activityEvents =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);
  final List<bool> recognitionEnabled = <bool>[];
  int closeCount = 0;
  int stopCount = 0;
  int startCount = 0;
  bool isCapturing = false;

  @override
  Stream<SpeechRecognitionEvent> get transcripts => transcriptEvents.stream;

  @override
  Stream<VoiceActivityEvent> get voiceActivity => activityEvents.stream;

  void finalTranscript(String text) {
    transcriptEvents.add(
      RecognitionFinal(
        transcript: SpeechTranscript(text: text),
        segmentId: 'segment-$text',
        at: Duration.zero,
      ),
    );
  }

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    startCount++;
    cancellationToken?.throwIfCancelled();
    onStart?.call(this);
    await startGate;
    if (!ignoreStartCancellation) {
      cancellationToken?.throwIfCancelled();
    }
    isCapturing = true;
  }

  @override
  Future<void> setRecognitionEnabled(
    bool enabled, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    recognitionEnabled.add(enabled);
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    stopCount++;
    isCapturing = false;
  }

  @override
  Future<void> close() async {
    closeCount++;
    await transcriptEvents.close();
    await activityEvents.close();
  }
}

final class _FakeBackend implements VoiceBackend {
  _FakeBackend(this.handler);

  factory _FakeBackend.immediate() =>
      _FakeBackend((_) => const Stream<VoiceBackendEvent>.empty());

  final Stream<VoiceBackendEvent> Function(VoiceBackendRequest request) handler;
  final List<VoiceBackendRequest> requests = <VoiceBackendRequest>[];
  int closeCount = 0;

  @override
  Stream<VoiceBackendEvent> respond(VoiceBackendRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

final class _FakeSynthesizer implements TextToSpeechProvider {
  int closeCount = 0;

  @override
  final SpeechProviderDescriptor descriptor = SpeechProviderDescriptor(
    id: 'fake-tts',
    displayName: 'Fake TTS',
    capabilities: const {SpeechCapability.textToSpeech},
  );

  @override
  AudioSource synthesize(SpeechSynthesisRequest request) =>
      _TextAudioSource(request.text);

  @override
  Future<void> close() async {
    closeCount++;
  }
}

final class _TextAudioSource implements AudioSource {
  const _TextAudioSource(this.text);

  final String text;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) => Future<AudioSourceSession>.error(
    UnsupportedError('Fake output consumes the source directly.'),
  );
}

final class _FakeOutput implements VoiceSpeechOutput {
  _FakeOutput({this.blockPlayback = false});

  final bool blockPlayback;
  final List<String> spoken = <String>[];
  int activePlayback = 0;
  int maximumConcurrentPlayback = 0;
  int interruptCount = 0;
  int closeCount = 0;

  @override
  Future<void> play(
    AudioSource source, {
    required AudioCancellationToken cancellationToken,
  }) async {
    final textSource = source as _TextAudioSource;
    activePlayback++;
    maximumConcurrentPlayback = activePlayback > maximumConcurrentPlayback
        ? activePlayback
        : maximumConcurrentPlayback;
    spoken.add(textSource.text);
    try {
      if (blockPlayback) {
        await cancellationToken.whenCancelled;
        cancellationToken.throwIfCancelled();
      } else {
        await Future<void>.value();
      }
    } finally {
      activePlayback--;
    }
  }

  @override
  Future<void> interrupt() async {
    interruptCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}
