import 'dart:async';
import 'dart:collection';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'failure.dart';
import 'interfaces.dart';

/// Bounded, serialized TTS generation and playback for one active generation.
final class SerializedSynthesisQueue {
  /// Creates a bounded queue.
  SerializedSynthesisQueue({
    required this.synthesizer,
    required this.output,
    this.modelId,
    this.voiceId,
    this.languageTag,
    this.rate = 1,
    this.pitch = 0,
    this.maximumQueuedSentences = 32,
    this.maximumQueuedCharacters = 8192,
    this.beforePlayback,
  }) {
    if (maximumQueuedSentences <= 0) {
      throw ArgumentError.value(
        maximumQueuedSentences,
        'maximumQueuedSentences',
        'Must be positive.',
      );
    }
    if (maximumQueuedCharacters <= 0) {
      throw ArgumentError.value(
        maximumQueuedCharacters,
        'maximumQueuedCharacters',
        'Must be positive.',
      );
    }
  }

  /// Synthesizer owned by this queue.
  final TextToSpeechProvider synthesizer;

  /// Playback output owned by this queue.
  final VoiceSpeechOutput output;

  /// Provider-scoped model ID.
  final String? modelId;

  /// Provider-scoped voice ID.
  final String? voiceId;

  /// Requested BCP-47 language tag.
  final String? languageTag;

  /// Relative speaking rate.
  final double rate;

  /// Relative pitch adjustment.
  final double pitch;

  /// Maximum waiting sentences, excluding active synthesis/playback.
  final int maximumQueuedSentences;

  /// Maximum waiting text characters, excluding active synthesis/playback.
  final int maximumQueuedCharacters;

  /// Called immediately before output starts, and awaited.
  final Future<void> Function(
    int generationId,
    AudioCancellationToken cancellationToken,
  )?
  beforePlayback;

  final ListQueue<_QueuedSentence> _pending = ListQueue<_QueuedSentence>();
  int _pendingCharacters = 0;
  int _generationId = 0;
  int _requestedGenerationId = 0;
  Future<void>? _worker;
  Future<void>? _transitionFuture;
  AudioCancellationController? _activeCancellation;
  Object? _failure;
  StackTrace? _failureStackTrace;
  Future<void>? _closeFuture;
  bool _closing = false;

  /// Active generation.
  int get generationId => _generationId;

  /// Current bounded mailbox depth.
  int get queuedSentences => _pending.length;

  /// Current bounded mailbox character count.
  int get queuedCharacters => _pendingCharacters;

  /// Whether [close] has been requested.
  bool get isClosed => _closing;

  /// Invalidates old work and begins [generationId].
  ///
  /// Concurrent calls coalesce to the newest requested generation. Completion
  /// means cancellation-insensitive work from older generations has joined.
  Future<void> beginGeneration(int generationId) {
    if (isClosed) {
      throw StateError('Synthesis queue is closed.');
    }
    if (generationId < _generationId || generationId < _requestedGenerationId) {
      throw ArgumentError.value(
        generationId,
        'generationId',
        'Must not move backwards.',
      );
    }
    if (generationId == _generationId && _transitionFuture == null) {
      return Future<void>.value();
    }
    _requestedGenerationId = generationId;
    return _transitionFuture ??= _runTransitions().whenComplete(() {
      _transitionFuture = null;
    });
  }

  Future<void> _runTransitions() async {
    while (!_closing && _generationId < _requestedGenerationId) {
      final int target = _requestedGenerationId;
      await _replaceGeneration(target);
    }
  }

  Future<void> _replaceGeneration(int generationId) async {
    _generationId = generationId;
    _clearPending();
    _activeCancellation?.cancel(
      const AudioCancellation(reason: 'generation_replaced'),
    );
    final Future<void>? oldWorker = _worker;
    final _FirstError errors = _FirstError();
    Future<void>? interrupt;
    try {
      interrupt = output.interrupt();
    } catch (error, stackTrace) {
      errors.add(error, stackTrace);
    }
    await errors.capture(() async => oldWorker);
    await errors.capture(() async => interrupt);
    _failure = null;
    _failureStackTrace = null;
    errors.throwIfPresent();
  }

  /// Adds one sentence to the active generation.
  ///
  /// Stale generations are ignored. Call [drain] to observe synthesis errors.
  /// Callers must await [beginGeneration] before enqueueing.
  void enqueue({required int generationId, required String text}) {
    if (isClosed) {
      throw StateError('Synthesis queue is closed.');
    }
    if (_transitionFuture != null) {
      throw StateError('Await beginGeneration before enqueueing speech.');
    }
    final String sentence = text.trim();
    if (sentence.isEmpty || generationId != _generationId) {
      return;
    }
    if (_failure != null) {
      return;
    }
    if (_pending.length >= maximumQueuedSentences ||
        sentence.length > maximumQueuedCharacters - _pendingCharacters) {
      _failOverflow(generationId);
      return;
    }
    _pending.addLast(_QueuedSentence(text: sentence));
    _pendingCharacters += sentence.length;
    _ensureWorker(generationId);
  }

  void _ensureWorker(int generationId) {
    if (_worker != null || _pending.isEmpty || generationId != _generationId) {
      return;
    }
    late final Future<void> worker;
    worker = _runWorker(generationId).whenComplete(() {
      if (identical(_worker, worker)) {
        _worker = null;
      }
    });
    _worker = worker;
  }

  Future<void> _runWorker(int generationId) async {
    while (!_closing &&
        generationId == _generationId &&
        _failure == null &&
        _pending.isNotEmpty) {
      final _QueuedSentence item = _pending.removeFirst();
      _pendingCharacters -= item.text.length;
      final AudioCancellationController cancellation =
          AudioCancellationController();
      _activeCancellation = cancellation;
      try {
        final AudioSource source = synthesizer.synthesize(
          SpeechSynthesisRequest(
            text: item.text,
            modelId: modelId,
            voiceId: voiceId,
            languageTag: languageTag,
            rate: rate,
            pitch: pitch,
            cancellation: cancellation.token,
          ),
        );
        final callback = beforePlayback;
        if (callback != null) {
          await callback(generationId, cancellation.token);
        }
        cancellation.token.throwIfCancelled();
        if (generationId != _generationId || _closing) {
          continue;
        }
        await output.play(source, cancellationToken: cancellation.token);
      } on AudioCancelledException {
        // A newer generation or close owns the next state.
      } catch (error, stackTrace) {
        if (generationId == _generationId && !_closing) {
          _failure ??= error;
          _failureStackTrace ??= stackTrace;
          _clearPending();
        }
      } finally {
        if (identical(_activeCancellation, cancellation)) {
          _activeCancellation = null;
        }
      }
    }
  }

  void _failOverflow(int generationId) {
    if (generationId != _generationId || _failure != null) {
      return;
    }
    _failure = const VoiceFailure(
      code: 'synthesis_queue_overflow',
      stage: 'synthesis',
      message: 'Speech output could not keep up with the response.',
      retryable: true,
    );
    _failureStackTrace = StackTrace.current;
    _clearPending();
    _activeCancellation?.cancel(
      const AudioCancellation(reason: 'synthesis_queue_overflow'),
    );
    try {
      final Future<void> interrupted = output.interrupt();
      unawaited(
        interrupted.catchError((Object error, StackTrace stackTrace) {
          _failure ??= error;
          _failureStackTrace ??= stackTrace;
        }),
      );
    } catch (error, stackTrace) {
      _failure ??= error;
      _failureStackTrace ??= stackTrace;
    }
  }

  /// Waits for all sentences in [generationId] and surfaces the first failure.
  Future<void> drain(int generationId) async {
    if (generationId != _generationId) {
      return;
    }
    while (generationId == _generationId) {
      final Future<void>? worker = _worker;
      if (worker == null) {
        if (_pending.isEmpty) {
          break;
        }
        _ensureWorker(generationId);
        continue;
      }
      await worker;
    }
    if (generationId != _generationId) {
      return;
    }
    final Object? failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(
        failure,
        _failureStackTrace ?? StackTrace.current,
      );
    }
  }

  /// Cancels playback and invalidates the current generation.
  Future<void> interrupt(int nextGenerationId) =>
      beginGeneration(nextGenerationId);

  /// Interrupts work and closes the synthesizer and output exactly once.
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    return _closeFuture = _close();
  }

  Future<void> _close() async {
    _generationId += 1;
    _requestedGenerationId = _generationId;
    _clearPending();
    _activeCancellation?.cancel(
      const AudioCancellation(reason: 'queue_closed'),
    );
    final Future<void>? transition = _transitionFuture;
    final Future<void>? worker = _worker;
    final _FirstError errors = _FirstError();
    Future<void>? interrupt;
    try {
      interrupt = output.interrupt();
    } catch (error, stackTrace) {
      errors.add(error, stackTrace);
    }
    await errors.capture(() async => transition);
    await errors.capture(() async => worker);
    await errors.capture(() async => interrupt);
    await errors.capture(synthesizer.close);
    await errors.capture(output.close);
    errors.throwIfPresent();
  }

  void _clearPending() {
    _pending.clear();
    _pendingCharacters = 0;
  }
}

final class _QueuedSentence {
  const _QueuedSentence({required this.text});

  final String text;
}

final class _FirstError {
  Object? _error;
  StackTrace? _stackTrace;

  void add(Object error, StackTrace stackTrace) {
    _error ??= error;
    _stackTrace ??= stackTrace;
  }

  Future<void> capture(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      add(error, stackTrace);
    }
  }

  void throwIfPresent() {
    final Object? error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}
