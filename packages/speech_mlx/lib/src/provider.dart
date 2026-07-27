import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'options.dart';
import 'tts_provider.dart';
import 'tts_worker.dart';
import 'worker.dart';

/// Unified MLX Audio provider.
///
/// Recognition remains deliberately batch-only. When a TTS worker is supplied,
/// the same stable provider also exposes incremental on-device synthesis.
final class MlxSpeechProvider extends IdempotentSpeechProvider
    implements BatchSpeechToTextProvider, TextToSpeechProvider {
  MlxSpeechProvider({
    MlxBatchWorker? worker,
    MlxTtsWorker? ttsWorker,
    this.modelId = 'default',
    String modelDisplayName = 'MLX local model',
    this.ttsModelId = 'pocket-tts',
    String ttsModelDisplayName = 'PocketTTS',
    this.defaultVoiceId = 'alba',
    Iterable<String> voiceIds = const <String>['alba'],
    this.maximumConcurrentTranscriptions = 2,
    this.maximumInputSamples = 67108864,
  }) : // A private named initializing formal would be unusable by consumers.
       // ignore: prefer_initializing_formals
       _worker = worker,
       _ttsWorker = ttsWorker,
       descriptor = SpeechProviderDescriptor(
         id: mlxSpeechProviderId,
         displayName: 'MLX Audio',
         capabilities: <SpeechCapability>{
           if (worker != null) SpeechCapability.batchSpeechToText,
           if (ttsWorker != null) SpeechCapability.textToSpeech,
         },
         models: <SpeechModelDescriptor>[
           if (worker != null)
             SpeechModelDescriptor(
               id: modelId,
               providerId: mlxSpeechProviderId,
               displayName: modelDisplayName,
               capabilities: const <SpeechCapability>{
                 SpeechCapability.batchSpeechToText,
               },
               isLocal: true,
             ),
           if (ttsWorker != null)
             SpeechModelDescriptor(
               id: ttsModelId,
               providerId: mlxSpeechProviderId,
               displayName: ttsModelDisplayName,
               capabilities: const <SpeechCapability>{
                 SpeechCapability.textToSpeech,
               },
               isLocal: true,
             ),
         ],
         voices: <SpeechVoiceDescriptor>[
           if (ttsWorker != null)
             for (final voiceId in voiceIds)
               SpeechVoiceDescriptor(
                 id: voiceId,
                 providerId: mlxSpeechProviderId,
                 displayName: mlxVoiceDisplayName(voiceId),
                 isLocal: true,
               ),
         ],
       ) {
    if (worker == null && ttsWorker == null) {
      throw ArgumentError('At least one MLX inference worker is required.');
    }
    if (maximumConcurrentTranscriptions <= 0) {
      throw ArgumentError.value(
        maximumConcurrentTranscriptions,
        'maximumConcurrentTranscriptions',
        'Must be positive.',
      );
    }
    if (maximumInputSamples <= 0) {
      throw ArgumentError.value(
        maximumInputSamples,
        'maximumInputSamples',
        'Must be positive.',
      );
    }
    _tts = ttsWorker == null
        ? null
        : MlxTtsCoordinator(
            worker: ttsWorker,
            ensureProviderOpen: ensureOpen,
            modelId: ttsModelId,
            defaultVoiceId: defaultVoiceId,
            voiceIds: voiceIds,
          );
  }

  final MlxBatchWorker? _worker;
  final MlxTtsWorker? _ttsWorker;
  late final MlxTtsCoordinator? _tts;
  final String modelId;
  final String ttsModelId;
  final String defaultVoiceId;
  final int maximumConcurrentTranscriptions;
  final int maximumInputSamples;
  int _activeTranscriptions = 0;
  final Set<AudioCancellationController> _recognitionCancellations =
      <AudioCancellationController>{};
  final Set<Completer<void>> _recognitionCompletions = <Completer<void>>{};

  @override
  final SpeechProviderDescriptor descriptor;

  @override
  Future<BatchRecognitionResult> transcribe(
    BatchRecognitionRequest request,
  ) async {
    ensureOpen();
    final worker = _worker;
    if (worker == null) {
      throw SpeechFailure(
        code: 'mlx_batch_stt_unavailable',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'This MLX provider has no speech recognition worker.',
      );
    }
    request.cancellation?.throwIfCancelled();
    if (request.options.modelId != null && request.options.modelId != modelId) {
      throw SpeechFailure(
        code: 'unknown_model',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'The selected MLX speech model is unavailable.',
      );
    }
    final providerOptions = request.options.providerOptions;
    if (providerOptions != null && providerOptions is! MlxRecognitionOptions) {
      throw SpeechFailure(
        code: 'invalid_provider_options',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'Recognition options do not belong to MLX Audio.',
      );
    }
    final options = providerOptions as MlxRecognitionOptions?;
    if (options != null &&
        (options.maxTokens <= 0 ||
            !options.temperature.isFinite ||
            options.temperature < 0 ||
            !options.topP.isFinite ||
            options.topP < 0 ||
            options.topP > 1 ||
            options.topK < 0 ||
            !options.repetitionPenalty.isFinite ||
            options.repetitionPenalty <= 0 ||
            options.repetitionContextSize < 0)) {
      throw SpeechFailure(
        code: 'invalid_provider_options',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        safeMessage: 'The MLX recognition parameters are invalid.',
      );
    }

    if (_activeTranscriptions >= maximumConcurrentTranscriptions) {
      throw SpeechFailure(
        code: 'mlx_recognition_busy',
        stage: 'preparation',
        providerId: mlxSpeechProviderId,
        retryable: true,
        safeMessage: 'The local MLX recognition queue is full.',
      );
    }
    _activeTranscriptions += 1;
    final operationCancellation = AudioCancellationController();
    final operationCompletion = Completer<void>();
    _recognitionCancellations.add(operationCancellation);
    _recognitionCompletions.add(operationCompletion);
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
      final captured = await _readSource(
        request.audio,
        cancellation: operationCancellation.token,
        maximumSampleCount: maximumInputSamples,
      );
      request.cancellation?.throwIfCancelled();
      if (captured.sampleCount == 0) {
        throw SpeechFailure(
          code: 'empty_audio',
          stage: 'capture',
          providerId: mlxSpeechProviderId,
          safeMessage: 'MLX recognition requires non-empty source audio.',
        );
      }
      request.onProgress?.call(0);
      final result = await worker.transcribe(
        MlxBatchWorkerRequest.owned(
          sampleChunks: captured.chunks,
          sampleRate: captured.format.sampleRate,
          channels: captured.format.channels,
          modelId: modelId,
          languageTag: request.options.languageTag,
          maxTokens: options?.maxTokens ?? 8192,
          temperature: options?.temperature ?? 0,
          topP: options?.topP ?? 0.95,
          topK: options?.topK ?? 0,
          repetitionPenalty: options?.repetitionPenalty ?? 1,
          repetitionContextSize: options?.repetitionContextSize ?? 32,
        ),
        cancellation: operationCancellation.token,
        onProgress: request.onProgress,
      );
      request.onProgress?.call(1);
      return BatchRecognitionResult(
        text: result.text,
        languageTag: result.languageTag,
        segments: result.segments.map(
          (segment) => BatchRecognitionSegment(
            text: segment.text,
            start: segment.start,
            end: segment.end,
          ),
        ),
      );
    } on AudioCancelledException {
      rethrow;
    } on SpeechFailure {
      rethrow;
    } on MlxWorkerException catch (error) {
      throw SpeechFailure(
        code: error.code == 'worker_queue_full'
            ? 'mlx_recognition_busy'
            : 'inference_failed',
        stage: 'recognition',
        providerId: mlxSpeechProviderId,
        retryable: error.code == 'worker_queue_full',
        safeMessage: error.code == 'worker_queue_full'
            ? 'The local MLX recognition queue is full.'
            : 'Local speech recognition failed.',
        safeCause: error.safeCause,
      );
    } catch (error) {
      throw SpeechFailure(
        code: 'inference_failed',
        stage: 'recognition',
        providerId: mlxSpeechProviderId,
        retryable: false,
        safeMessage: 'Local speech recognition failed.',
        safeCause: error.runtimeType.toString(),
      );
    } finally {
      _activeTranscriptions -= 1;
      _recognitionCancellations.remove(operationCancellation);
      _recognitionCompletions.remove(operationCompletion);
      if (!operationCompletion.isCompleted) {
        operationCompletion.complete();
      }
    }
  }

  @override
  AudioSource synthesize(SpeechSynthesisRequest request) {
    ensureOpen();
    final tts = _tts;
    if (tts == null) {
      throw SpeechFailure(
        code: 'mlx_tts_unavailable',
        stage: 'synthesis',
        providerId: mlxSpeechProviderId,
        safeMessage: 'This MLX provider has no synthesis worker.',
      );
    }
    return tts.synthesize(request);
  }

  @override
  Future<void> onClose() async {
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

    const closeCancellation = AudioCancellation(reason: 'provider_closed');
    for (final cancellation in List<AudioCancellationController>.of(
      _recognitionCancellations,
    )) {
      cancellation.cancel(closeCancellation);
    }
    await Future.wait<void>(<Future<void>>[
      capture(() async => _worker?.close()),
      capture(() async {
        await Future.wait<void>(<Future<void>>[
          for (final completion in List<Completer<void>>.of(
            _recognitionCompletions,
          ))
            completion.future,
        ]);
      }),
    ]);
    await Future.wait<void>(<Future<void>>[
      capture(() async => _tts?.closeSessions()),
      capture(() async => _ttsWorker?.close()),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError!,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}

final class _CapturedAudio {
  const _CapturedAudio(this.format, this.chunks);

  final AudioFormat format;
  final List<Float32List> chunks;

  int get sampleCount =>
      chunks.fold<int>(0, (total, chunk) => total + chunk.length);
}

Future<_CapturedAudio> _readSource(
  AudioSource source, {
  AudioCancellationToken? cancellation,
  required int maximumSampleCount,
}) async {
  final session = await source.prepare(cancellationToken: cancellation);
  final chunks = <Float32List>[];
  var sampleCount = 0;
  int? expectedSequence;
  int? expectedSampleOffset;
  int? firstSampleOffset;
  Duration? firstTimestamp;
  late final StreamSubscription<AudioFrame> subscription;
  final done = Completer<void>();

  subscription = session.frames.listen(
    (frame) {
      if (done.isCompleted) {
        return;
      }
      if (frame.format != session.format ||
          frame.sourceId != session.sourceId ||
          frame.trackId != session.trackId ||
          frame.clockId != session.clockId ||
          frame.discontinuity != null ||
          (expectedSequence != null && frame.sequence != expectedSequence) ||
          (expectedSampleOffset != null &&
              frame.sampleOffset != expectedSampleOffset) ||
          (firstSampleOffset != null &&
              frame.timestamp !=
                  firstTimestamp! +
                      session.format.durationForFrames(
                        frame.sampleOffset - firstSampleOffset!,
                      ))) {
        if (!done.isCompleted) {
          done.completeError(
            SpeechFailure(
              code: 'discontinuous_audio',
              stage: 'capture',
              providerId: mlxSpeechProviderId,
              safeMessage:
                  'Batch recognition requires continuous source audio.',
            ),
          );
        }
        return;
      }
      if (sampleCount > maximumSampleCount - frame.samples.length) {
        if (!done.isCompleted) {
          done.completeError(
            SpeechFailure(
              code: 'audio_too_large',
              stage: 'capture',
              providerId: mlxSpeechProviderId,
              safeMessage:
                  'The MLX recognition input exceeds the configured limit.',
            ),
          );
        }
        return;
      }
      firstSampleOffset ??= frame.sampleOffset;
      firstTimestamp ??= frame.timestamp;
      expectedSequence = frame.sequence + 1;
      expectedSampleOffset = frame.endSampleOffset;
      final copy = Float32List.fromList(frame.samples);
      chunks.add(copy);
      sampleCount += copy.length;
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!done.isCompleted) done.completeError(error, stackTrace);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  _CapturedAudio? captured;
  Object? failure;
  StackTrace? failureStackTrace;
  try {
    final sourceCompleted = Future.wait<void>(<Future<void>>[
      session.start(cancellationToken: cancellation),
      done.future,
    ]);
    if (cancellation == null) {
      await sourceCompleted;
    } else {
      await Future.any<void>(<Future<void>>[
        sourceCompleted,
        cancellation.whenCancelled.then((value) {
          throw AudioCancelledException(value);
        }),
      ]);
    }
    captured = _CapturedAudio(
      session.format,
      List<Float32List>.unmodifiable(chunks),
    );
  } catch (error, stackTrace) {
    failure = error;
    failureStackTrace = stackTrace;
    try {
      await session.abort();
    } catch (_) {
      // Preserve the source/cancellation failure.
    }
  }
  try {
    await subscription.cancel();
  } catch (error, stackTrace) {
    failure ??= error;
    failureStackTrace ??= stackTrace;
  }
  try {
    await session.close();
  } catch (error, stackTrace) {
    failure ??= error;
    failureStackTrace ??= stackTrace;
  }
  if (failure != null) {
    Error.throwWithStackTrace(failure, failureStackTrace ?? StackTrace.current);
  }
  return captured!;
}

String mlxVoiceDisplayName(String identifier) => identifier
    .split(RegExp('[-_]'))
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');
