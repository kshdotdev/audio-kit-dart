import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'options.dart';
import 'turn_worker.dart';
import 'worker.dart' show MlxWorkerException;

/// Stable model identifier for the pinned Smart Turn v3.2 checkpoint.
const String mlxSmartTurnModelId = 'smart-turn-v3';

/// MLX Audio turn-completion provider.
///
/// Wraps the Smart Turn v3.2 endpoint classifier behind
/// [TurnCompletionScorer]. Inference lives in a long-lived worker
/// ([MlxIsolateTurnWorker] in production) so the model is loaded once and every
/// window is scored off the calling isolate — the Dart equivalent of the
/// Swift's `SmartTurnScorer` actor.
///
/// This is deliberately a separate provider from `MlxSpeechProvider` rather
/// than another capability on it. The two own different checkpoints with
/// different lifecycles: recognition models are chosen per deployment, while
/// Smart Turn is pinned by revision and hash, and a detector usually wants the
/// turn model resident long before (and after) any transcription runs.
final class MlxSmartTurnScorer extends IdempotentSpeechProvider
    implements TurnCompletionScorer {
  MlxSmartTurnScorer({
    required MlxTurnWorker worker,
    this.modelId = mlxSmartTurnModelId,
    String modelDisplayName = 'Smart Turn v3.2',
    this.maximumConcurrentScores = 4,
  }) : // A private named initializing formal would be unusable by consumers.
       // ignore: prefer_initializing_formals
       _worker = worker,
       descriptor = SpeechProviderDescriptor(
         id: mlxSpeechProviderId,
         displayName: 'MLX Audio',
         capabilities: const <SpeechCapability>{
           SpeechCapability.turnCompletion,
         },
         models: <SpeechModelDescriptor>[
           SpeechModelDescriptor(
             id: modelId,
             providerId: mlxSpeechProviderId,
             displayName: modelDisplayName,
             capabilities: const <SpeechCapability>{
               SpeechCapability.turnCompletion,
             },
             isLocal: true,
           ),
         ],
       ) {
    if (maximumConcurrentScores <= 0) {
      throw ArgumentError.value(
        maximumConcurrentScores,
        'maximumConcurrentScores',
        'Must be positive.',
      );
    }
  }

  final MlxTurnWorker _worker;

  /// Stable provider-scoped model identifier.
  final String modelId;

  /// Admission ceiling for in-flight scores.
  ///
  /// A detector fires one score per detected pause and must not queue an
  /// unbounded backlog when the model falls behind: at that point the newest
  /// window matters and the old ones are stale, so a bounded reject is the
  /// honest answer.
  final int maximumConcurrentScores;

  int _activeScores = 0;
  final Set<AudioCancellationController> _scoreCancellations =
      <AudioCancellationController>{};
  final Set<Completer<void>> _scoreCompletions = <Completer<void>>{};

  @override
  final SpeechProviderDescriptor descriptor;

  /// Longest window the classifier reads; longer requests keep their tail.
  Duration get maximumWindow => _worker.maximumWindow;

  @override
  Future<TurnCompletionScore> scoreTurnCompletion(
    TurnCompletionRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();

    final providerOptions = request.providerOptions;
    if (providerOptions != null && providerOptions is! MlxSmartTurnOptions) {
      throw SpeechFailure(
        code: 'invalid_provider_options',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'Turn completion options do not belong to MLX Audio.',
      );
    }
    final options = providerOptions as MlxSmartTurnOptions?;
    if (options != null &&
        options.modelId != null &&
        options.modelId != modelId) {
      throw SpeechFailure(
        code: 'unknown_model',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'The selected MLX turn-completion model is unavailable.',
      );
    }

    final samples = request.audio.samples;
    if (samples.isEmpty) {
      throw SpeechFailure(
        code: 'empty_audio',
        stage: 'capture',
        providerId: mlxSpeechProviderId,
        safeMessage: 'Turn completion requires a non-empty window.',
      );
    }
    final sampleRate = request.audio.format.sampleRate;

    if (_activeScores >= maximumConcurrentScores) {
      throw SpeechFailure(
        code: 'mlx_turn_completion_busy',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        retryable: true,
        safeMessage: 'The local MLX turn-completion queue is full.',
      );
    }
    _activeScores += 1;
    final operationCancellation = AudioCancellationController();
    final operationCompletion = Completer<void>();
    _scoreCancellations.add(operationCancellation);
    _scoreCompletions.add(operationCompletion);
    final requestCancellation = request.cancellation;
    if (requestCancellation != null) {
      if (requestCancellation.isCancelled) {
        operationCancellation.cancel(
          requestCancellation.cancellation ?? const AudioCancellation(),
        );
      } else {
        unawaited(
          requestCancellation.whenCancelled.then(operationCancellation.cancel),
        );
      }
    }

    try {
      final result = await _worker.score(
        MlxTurnWorkerRequest.owned(
          // Cropping the tail here is not a policy decision: the model does
          // exactly this to an over-long window. Doing it before the isolate
          // hop keeps a caller's ten-minute buffer off the wire.
          samples: _tailWindow(samples, sampleRate),
          sampleRate: sampleRate,
          modelId: modelId,
          threshold: request.threshold,
        ),
        cancellation: operationCancellation.token,
      );
      return TurnCompletionScore(
        probability: result.probability,
        isComplete: result.isComplete,
        threshold: result.threshold,
      );
    } on AudioCancelledException {
      rethrow;
    } on SpeechFailure {
      rethrow;
    } on MlxWorkerException catch (error) {
      throw SpeechFailure(
        code: error.code == 'worker_queue_full'
            ? 'mlx_turn_completion_busy'
            : 'inference_failed',
        stage: 'turn_completion',
        providerId: mlxSpeechProviderId,
        retryable: error.code == 'worker_queue_full',
        safeMessage: error.code == 'worker_queue_full'
            ? 'The local MLX turn-completion queue is full.'
            : 'Local turn-completion scoring failed.',
        safeCause: error.safeCause,
      );
    } catch (error) {
      // A scorer never invents a probability to keep a caller running: a
      // made-up 0.5 is indistinguishable from a genuinely uncertain model.
      throw SpeechFailure(
        code: 'inference_failed',
        stage: 'turn_completion',
        providerId: mlxSpeechProviderId,
        safeMessage: 'Local turn-completion scoring failed.',
        safeCause: error.runtimeType.toString(),
      );
    } finally {
      _activeScores -= 1;
      _scoreCancellations.remove(operationCancellation);
      _scoreCompletions.remove(operationCompletion);
      if (!operationCompletion.isCompleted) {
        operationCompletion.complete();
      }
    }
  }

  /// The trailing [maximumWindow] of [samples], copied.
  Float32List _tailWindow(Float32List samples, int sampleRate) {
    final limit =
        (maximumWindow.inMicroseconds * sampleRate) ~/
        Duration.microsecondsPerSecond;
    if (limit <= 0 || samples.length <= limit) {
      return Float32List.fromList(samples);
    }
    return Float32List.fromList(
      Float32List.sublistView(samples, samples.length - limit),
    );
  }

  @override
  Future<void> onClose() async {
    const closeCancellation = AudioCancellation(reason: 'provider_closed');
    for (final cancellation in List<AudioCancellationController>.of(
      _scoreCancellations,
    )) {
      cancellation.cancel(closeCancellation);
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> capture(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await Future.wait<void>(<Future<void>>[
      capture(() async => _worker.close()),
      capture(() async {
        await Future.wait<void>(<Future<void>>[
          for (final completion in List<Completer<void>>.of(_scoreCompletions))
            completion.future,
        ]);
      }),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError!,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}
