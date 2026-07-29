import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';
import 'package:voice_core/voice_core.dart';

void main() {
  test('half duplex remains the default and still gates recognition', () async {
    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput();
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
    );
    addTearDown(controller.close);

    expect(controller.duplex.mode, VoiceDuplexMode.halfDuplex);
    expect(controller.current.duplexMode, VoiceDuplexMode.halfDuplex);

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(() => output.spoken.isNotEmpty);

    expect(input.recognitionEnabled, contains(false));
  });

  test('full duplex never gates recognition across a whole turn', () async {
    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput();
    final List<VoiceTurnState> turnStates = <VoiceTurnState>[];
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
      duplex: VoiceDuplexConfig.fullDuplex(),
    );
    addTearDown(controller.close);
    final StreamSubscription<VoiceConversationSnapshot> subscription =
        controller.snapshots.listen(
          (VoiceConversationSnapshot snapshot) =>
              turnStates.add(snapshot.turnState),
        );
    addTearDown(subscription.cancel);

    expect(controller.current.duplexMode, VoiceDuplexMode.fullDuplex);

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(() => output.spoken.isNotEmpty);
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.listening,
    );

    // The whole point: the recognizer is never torn down, so the gating call
    // that half duplex depends on is never issued at all.
    expect(input.recognitionEnabled, isEmpty);
    expect(output.spoken, <String>['Hello there.']);
    expect(turnStates, contains(VoiceTurnState.speaking));
  });

  test(
    'voice activity during synthesis does not interrupt full duplex',
    () async {
      final _FakeVoiceInput input = _FakeVoiceInput();
      final _FakeOutput output = _FakeOutput(blockPlayback: true);
      final VoiceConversationController controller = _controller(
        input: input,
        backend: _FakeBackend.narrative('Hello there.'),
        output: output,
        duplex: VoiceDuplexConfig.fullDuplex(),
      );
      addTearDown(() async {
        output.releaseAll();
        await controller.close();
      });

      await controller.start();
      input.finalTranscript('hi');
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.speaking,
      );
      final int generationId = controller.current.generationId;
      // Beginning a turn already interrupts whatever the last one was playing;
      // what matters here is that speaking over the assistant adds nothing.
      final int interrupts = output.interruptCount;

      input.speechStarted();
      input.partialTranscript('talking over');
      await pumpEventQueue();

      expect(controller.current.turnState, VoiceTurnState.speaking);
      expect(controller.current.generationId, generationId);
      expect(output.interruptCount, interrupts);
      // Speaking over the assistant is transcribed rather than gated away.
      expect(controller.current.interimTranscript, 'talking over');
      expect(input.recognitionEnabled, isEmpty);
    },
  );

  test(
    'a committed transcript supersedes live synthesis in full duplex',
    () async {
      final _FakeVoiceInput input = _FakeVoiceInput();
      final _FakeOutput output = _FakeOutput(blockPlayback: true);
      final StreamController<VoiceBackendEvent> first =
          StreamController<VoiceBackendEvent>();
      final StreamController<VoiceBackendEvent> second =
          StreamController<VoiceBackendEvent>();
      final _FakeBackend backend = _FakeBackend(
        (VoiceBackendRequest request) =>
            request.transcript == 'first' ? first.stream : second.stream,
      );
      final VoiceConversationController controller = _controller(
        input: input,
        backend: backend,
        output: output,
        duplex: VoiceDuplexConfig.fullDuplex(),
      );
      addTearDown(() async {
        output.releaseAll();
        await controller.close();
        await first.close();
        await second.close();
      });

      await controller.start();
      input.finalTranscript('first');
      await _waitFor(() => backend.requests.length == 1);
      first
        ..add(const VoiceNarrativeStarted())
        ..add(const VoiceNarrativeDelta('First answer.'));
      await _waitFor(
        () => controller.current.turnState == VoiceTurnState.speaking,
      );
      expect(controller.current.generationId, 1);

      // Recognition never stopped, so a second utterance can be committed while
      // the first answer is still playing. That starts a new turn.
      input.finalTranscript('second');
      await _waitFor(() => backend.requests.length == 2);

      expect(controller.current.generationId, 2);
      expect(backend.requests.last.transcript, 'second');
      expect(backend.requests.first.cancellationToken.isCancelled, isTrue);
      expect(output.interruptCount, greaterThan(0));

      final String supersededResponse = controller.current.responseText;
      first.add(const VoiceNarrativeDelta(' stale'));
      await pumpEventQueue();
      expect(controller.current.responseText, supersededResponse);

      second
        ..add(const VoiceNarrativeStarted())
        ..add(const VoiceNarrativeDelta('Second answer.'));
      await _waitFor(() => output.spoken.length == 2);

      expect(output.spoken, <String>['First answer.', 'Second answer.']);
      expect(input.recognitionEnabled, isEmpty);
    },
  );

  test('sustained speech interrupts full duplex after the dwell', () async {
    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput(blockPlayback: true);
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
      duplex: VoiceDuplexConfig.fullDuplex(
        interruptAfterSustainedSpeech: const Duration(milliseconds: 30),
      ),
    );
    addTearDown(() async {
      output.releaseAll();
      await controller.close();
    });

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.speaking,
    );
    final int generationId = controller.current.generationId;

    input.speechStarted();
    await pumpEventQueue();
    expect(controller.current.turnState, VoiceTurnState.speaking);

    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.interrupted,
    );
    expect(controller.current.generationId, generationId + 1);
    expect(output.interruptCount, greaterThan(0));
    // Even an interrupt leaves the recognizer alone in full duplex.
    expect(input.recognitionEnabled, isEmpty);
  });

  test('speech that stops before the dwell does not interrupt', () async {
    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput(blockPlayback: true);
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
      duplex: VoiceDuplexConfig.fullDuplex(
        interruptAfterSustainedSpeech: const Duration(milliseconds: 40),
      ),
    );
    addTearDown(() async {
      output.releaseAll();
      await controller.close();
    });

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.speaking,
    );
    final int generationId = controller.current.generationId;
    final int interrupts = output.interruptCount;

    input.speechStarted();
    input.speechEnded();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(controller.current.turnState, VoiceTurnState.speaking);
    expect(controller.current.generationId, generationId);
    expect(output.interruptCount, interrupts);
  });

  test('explicit interrupt still stops full duplex playback', () async {
    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput(blockPlayback: true);
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
      duplex: VoiceDuplexConfig.fullDuplex(),
    );
    addTearDown(() async {
      output.releaseAll();
      await controller.close();
    });

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.speaking,
    );
    final int generationId = controller.current.generationId;

    await controller.interruptTurn();

    expect(controller.current.turnState, VoiceTurnState.interrupted);
    expect(controller.current.generationId, generationId + 1);
    expect(output.interruptCount, greaterThan(0));
    expect(input.recognitionEnabled, isEmpty);
  });

  test('full duplex without a canceller falls back to half duplex', () async {
    final VoiceDuplexConfig config = VoiceDuplexConfig.fullDuplex(
      echoCancelled: false,
      interruptAfterSustainedSpeech: const Duration(milliseconds: 30),
    );

    expect(config.requestedMode, VoiceDuplexMode.fullDuplex);
    expect(config.mode, VoiceDuplexMode.halfDuplex);
    expect(config.isDegraded, isTrue);
    expect(config.acceptsEchoRisk, isFalse);
    // A sustained-speech dwell is meaningless once voice activity interrupts
    // immediately again, so the degraded policy drops it.
    expect(config.interruptAfterSustainedSpeech, isNull);

    final _FakeVoiceInput input = _FakeVoiceInput();
    final _FakeOutput output = _FakeOutput(blockPlayback: true);
    final VoiceConversationController controller = _controller(
      input: input,
      backend: _FakeBackend.narrative('Hello there.'),
      output: output,
      duplex: config,
    );
    addTearDown(() async {
      output.releaseAll();
      await controller.close();
    });

    expect(controller.current.duplexMode, VoiceDuplexMode.halfDuplex);

    await controller.start();
    input.finalTranscript('hi');
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.speaking,
    );

    // Degraded means genuinely half duplex: recognition is gated, and voice
    // activity interrupts immediately rather than after a dwell.
    expect(input.recognitionEnabled, contains(false));
    input.speechStarted();
    await _waitFor(
      () => controller.current.turnState == VoiceTurnState.interrupted,
    );
    await _waitFor(() => input.recognitionEnabled.last);
  });

  test(
    'accepting the echo risk keeps full duplex without a canceller',
    () async {
      final VoiceDuplexConfig config = VoiceDuplexConfig.fullDuplex(
        echoCancelled: false,
        fallback: VoiceEchoCancellationFallback.acceptEchoRisk,
      );

      expect(config.mode, VoiceDuplexMode.fullDuplex);
      expect(config.isDegraded, isFalse);
      expect(config.acceptsEchoRisk, isTrue);

      final _FakeVoiceInput input = _FakeVoiceInput();
      final _FakeOutput output = _FakeOutput();
      final VoiceConversationController controller = _controller(
        input: input,
        backend: _FakeBackend.narrative('Hello there.'),
        output: output,
        duplex: config,
      );
      addTearDown(controller.close);

      await controller.start();
      input.finalTranscript('hi');
      await _waitFor(() => output.spoken.isNotEmpty);

      expect(controller.current.duplexMode, VoiceDuplexMode.fullDuplex);
      expect(input.recognitionEnabled, isEmpty);
    },
  );

  test('an echo-cancelled full duplex policy carries no risk flag', () {
    final VoiceDuplexConfig config = VoiceDuplexConfig.fullDuplex();

    expect(config.mode, VoiceDuplexMode.fullDuplex);
    expect(config.isDegraded, isFalse);
    expect(config.acceptsEchoRisk, isFalse);
    expect(config.interruptAfterSustainedSpeech, isNull);
    expect(
      () => VoiceDuplexConfig.fullDuplex(
        interruptAfterSustainedSpeech: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}

VoiceConversationController _controller({
  required _FakeVoiceInput input,
  required _FakeBackend backend,
  required _FakeOutput output,
  VoiceDuplexConfig duplex = const VoiceDuplexConfig.halfDuplex(),
}) => VoiceConversationController(
  input: input,
  backend: backend,
  synthesizer: _FakeSynthesizer(),
  output: output,
  duplex: duplex,
);

Future<void> _waitFor(bool Function() condition) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 2)) {
      fail('Condition was not reached.');
    }
    await pumpEventQueue(times: 1);
  }
}

final class _FakeVoiceInput implements VoiceInput {
  final StreamController<SpeechRecognitionEvent> transcriptEvents =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  final StreamController<VoiceActivityEvent> activityEvents =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);
  final List<bool> recognitionEnabled = <bool>[];
  int closeCount = 0;
  int _revision = 0;

  void finalTranscript(String text) {
    transcriptEvents.add(
      RecognitionFinal(
        transcript: SpeechTranscript(text: text),
        segmentId: 'segment-$text',
        at: Duration.zero,
      ),
    );
  }

  void partialTranscript(String text) {
    transcriptEvents.add(
      RecognitionPartial(
        transcript: SpeechTranscript(text: text),
        revision: _revision++,
        at: Duration.zero,
      ),
    );
  }

  void speechStarted() {
    activityEvents.add(
      VoiceActivityStarted(probability: 0.95, at: Duration.zero),
    );
  }

  void speechEnded() {
    activityEvents.add(
      VoiceActivityEnded(probability: 0.05, at: Duration.zero),
    );
  }

  @override
  Stream<SpeechRecognitionEvent> get transcripts => transcriptEvents.stream;

  @override
  Stream<VoiceActivityEvent> get voiceActivity => activityEvents.stream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
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
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {}

  @override
  Future<void> close() async {
    closeCount++;
    if (!transcriptEvents.isClosed) {
      unawaited(transcriptEvents.close());
    }
    if (!activityEvents.isClosed) {
      unawaited(activityEvents.close());
    }
  }
}

final class _FakeBackend implements VoiceBackend {
  _FakeBackend(this.handler);

  factory _FakeBackend.narrative(String text) => _FakeBackend(
    (_) => Stream<VoiceBackendEvent>.fromIterable(<VoiceBackendEvent>[
      const VoiceNarrativeStarted(),
      VoiceNarrativeDelta(text),
      const VoiceNarrativeEnded(),
      const VoiceBackendCompleted(),
    ]),
  );

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
    id: 'full-duplex-tts',
    displayName: 'Full duplex TTS',
    capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
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
    UnsupportedError('The test output consumes the source directly.'),
  );
}

final class _FakeOutput implements VoiceSpeechOutput {
  _FakeOutput({this.blockPlayback = false});

  final bool blockPlayback;
  final List<String> spoken = <String>[];
  final List<Completer<void>> _releases = <Completer<void>>[];
  int interruptCount = 0;
  int closeCount = 0;

  /// Unblocks every in-flight and future play call.
  void releaseAll() {
    for (final Completer<void> release in _releases) {
      if (!release.isCompleted) {
        release.complete();
      }
    }
  }

  @override
  Future<void> play(
    AudioSource source, {
    required AudioCancellationToken cancellationToken,
  }) async {
    spoken.add((source as _TextAudioSource).text);
    if (!blockPlayback) {
      return;
    }
    final Completer<void> release = Completer<void>();
    _releases.add(release);
    await Future.any<void>(<Future<void>>[
      release.future,
      cancellationToken.whenCancelled,
    ]);
    cancellationToken.throwIfCancelled();
  }

  @override
  Future<void> interrupt() async {
    interruptCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
    releaseAll();
  }
}
