import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';
import 'package:voice_core/voice_core.dart';

void main() {
  test('bounds pending speech when the backend outpaces playback', () async {
    final _BlockingOutput output = _BlockingOutput();
    final _FakeSynthesizer synthesizer = _FakeSynthesizer();
    final SerializedSynthesisQueue queue = SerializedSynthesisQueue(
      synthesizer: synthesizer,
      output: output,
      maximumQueuedSentences: 1,
      maximumQueuedCharacters: 16,
    );
    addTearDown(() async {
      output.release();
      await queue.close();
    });

    await queue.beginGeneration(1);
    queue.enqueue(generationId: 1, text: 'active');
    await output.started.future;
    queue.enqueue(generationId: 1, text: 'pending');

    expect(queue.queuedSentences, 1);
    expect(queue.queuedCharacters, 7);

    queue.enqueue(generationId: 1, text: 'overflow');

    expect(queue.queuedSentences, 0);
    expect(queue.queuedCharacters, 0);
    expect(output.interruptCount, greaterThanOrEqualTo(2));

    output.release();
    await expectLater(
      queue.drain(1),
      throwsA(
        isA<VoiceFailure>().having(
          (VoiceFailure failure) => failure.code,
          'code',
          'synthesis_queue_overflow',
        ),
      ),
    );
  });

  test(
    'generation transition joins cancellation-insensitive playback',
    () async {
      final _BlockingOutput output = _BlockingOutput();
      final SerializedSynthesisQueue queue = SerializedSynthesisQueue(
        synthesizer: _FakeSynthesizer(),
        output: output,
      );
      addTearDown(() async {
        output.release();
        await queue.close();
      });

      await queue.beginGeneration(1);
      queue.enqueue(generationId: 1, text: 'old');
      await output.started.future;

      var transitioned = false;
      final Future<void> transition = queue.beginGeneration(2).then((_) {
        transitioned = true;
      });
      await pumpEventQueue();

      expect(transitioned, isFalse);
      expect(queue.generationId, 2);

      output.release();
      await transition;
      queue.enqueue(generationId: 2, text: 'new');
      await queue.drain(2);

      expect(output.spoken, <String>['old', 'new']);
      expect(output.maximumConcurrentPlayback, 1);
    },
  );

  test('close releases both dependencies when the first close fails', () async {
    final _FakeSynthesizer synthesizer = _FakeSynthesizer(failClose: true);
    final _BlockingOutput output = _BlockingOutput()..release();
    final SerializedSynthesisQueue queue = SerializedSynthesisQueue(
      synthesizer: synthesizer,
      output: output,
    );

    await expectLater(queue.close(), throwsStateError);
    await expectLater(queue.close(), throwsStateError);

    expect(synthesizer.closeCount, 1);
    expect(output.closeCount, 1);
  });
}

final class _FakeSynthesizer implements TextToSpeechProvider {
  _FakeSynthesizer({this.failClose = false});

  final bool failClose;
  int closeCount = 0;

  @override
  final SpeechProviderDescriptor descriptor = SpeechProviderDescriptor(
    id: 'queue-test-tts',
    displayName: 'Queue test TTS',
    capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
  );

  @override
  AudioSource synthesize(SpeechSynthesisRequest request) =>
      _TextSource(request.text);

  @override
  Future<void> close() async {
    closeCount++;
    if (failClose) {
      throw StateError('synthesizer close failed');
    }
  }
}

final class _TextSource implements AudioSource {
  const _TextSource(this.text);

  final String text;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) => throw UnsupportedError('The test output consumes text directly.');
}

final class _BlockingOutput implements VoiceSpeechOutput {
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  final List<String> spoken = <String>[];
  int activePlayback = 0;
  int maximumConcurrentPlayback = 0;
  int interruptCount = 0;
  int closeCount = 0;

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<void> play(
    AudioSource source, {
    required AudioCancellationToken cancellationToken,
  }) async {
    activePlayback++;
    maximumConcurrentPlayback = activePlayback > maximumConcurrentPlayback
        ? activePlayback
        : maximumConcurrentPlayback;
    spoken.add((source as _TextSource).text);
    if (!started.isCompleted) {
      started.complete();
    }
    try {
      await _release.future;
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
