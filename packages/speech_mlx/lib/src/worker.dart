import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:mlx_audio/mlx_audio.dart';

/// Domain-only request sent to a serialized MLX inference worker.
final class MlxBatchWorkerRequest {
  MlxBatchWorkerRequest({
    required Float32List samples,
    required this.sampleRate,
    required this.modelId,
    this.channels = 1,
    this.languageTag,
    this.maxTokens = 8192,
    this.temperature = 0,
    this.topP = 0.95,
    this.topK = 0,
    this.repetitionPenalty = 1,
    this.repetitionContextSize = 32,
  }) : _sampleChunks = <Float32List>[Float32List.fromList(samples)] {
    _validateBatchWorkerRequest(this);
  }

  /// Takes ownership of already independent source chunks.
  ///
  /// Callers must not mutate a list after passing it to this constructor.
  MlxBatchWorkerRequest.owned({
    required List<Float32List> sampleChunks,
    required this.sampleRate,
    required this.channels,
    required this.modelId,
    this.languageTag,
    this.maxTokens = 8192,
    this.temperature = 0,
    this.topP = 0.95,
    this.topK = 0,
    this.repetitionPenalty = 1,
    this.repetitionContextSize = 32,
  }) : _sampleChunks = List<Float32List>.unmodifiable(sampleChunks) {
    _validateBatchWorkerRequest(this);
  }

  final List<Float32List> _sampleChunks;

  /// Independent interleaved PCM chunks.
  List<Float32List> get sampleChunks => _sampleChunks;

  /// Compatibility view that combines all chunks.
  ///
  /// Adapters should use [sampleChunks] so full-source copying stays off the UI
  /// isolate.
  Float32List get samples {
    final combined = Float32List(sampleCount);
    var offset = 0;
    for (final chunk in _sampleChunks) {
      combined.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return combined;
  }

  int get sampleCount =>
      _sampleChunks.fold<int>(0, (total, chunk) => total + chunk.length);

  final int sampleRate;
  final int channels;
  final String modelId;
  final String? languageTag;
  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;
  final double repetitionPenalty;
  final int repetitionContextSize;
}

/// One timed text segment returned across the worker boundary.
final class MlxBatchWorkerSegment {
  const MlxBatchWorkerSegment({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final Duration start;
  final Duration end;
}

/// Domain-only result returned by an MLX inference worker.
final class MlxBatchWorkerResult {
  MlxBatchWorkerResult({
    required this.text,
    required Iterable<MlxBatchWorkerSegment> segments,
    this.languageTag,
  }) : segments = List<MlxBatchWorkerSegment>.unmodifiable(segments);

  final String text;
  final List<MlxBatchWorkerSegment> segments;
  final String? languageTag;
}

/// Replaceable worker boundary used by [MlxSpeechProvider].
///
/// Implementations must serialize model access. A production implementation can
/// use an isolate; tests can inject a deterministic fake. Requests carry
/// source-native interleaved PCM. Production workers perform downmixing and
/// resampling next to the model rather than on Flutter's UI isolate.
abstract interface class MlxBatchWorker {
  /// Mono sample rate expected by the loaded model after worker preprocessing.
  int get inputSampleRate;

  Future<MlxBatchWorkerResult> transcribe(
    MlxBatchWorkerRequest request, {
    AudioCancellationToken? cancellation,
    void Function(double progress)? onProgress,
  });

  /// Releases the loaded model. Repeated calls must have no effect.
  Future<void> close();
}

/// A reusable serializer for injected inference functions.
///
/// This implementation does not itself move work off the calling isolate. It is
/// useful for tests and for wrapping an embedding-specific worker. Use
/// [MlxIsolateBatchWorker] for MLX inference from a UI process.
final class SerializedMlxBatchWorker implements MlxBatchWorker {
  SerializedMlxBatchWorker({
    required this.inputSampleRate,
    this.maximumQueuedRequests = 2,
    this.maximumQueuedPcmBytes = 268435456,
    this.closeTimeout = const Duration(seconds: 2),
    required FutureOr<MlxBatchWorkerResult> Function(
      MlxBatchWorkerRequest request,
      AudioCancellationToken? cancellation,
      void Function(double progress)? onProgress,
    )
    infer,
    FutureOr<void> Function()? dispose,
  }) : // Public callback labels intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _infer = infer,
       // ignore: prefer_initializing_formals
       _dispose = dispose {
    if (inputSampleRate <= 0) {
      throw ArgumentError.value(
        inputSampleRate,
        'inputSampleRate',
        'Must be positive.',
      );
    }
    _validateWorkerLimits(
      maximumQueuedRequests,
      maximumQueuedPcmBytes,
      closeTimeout,
    );
  }

  @override
  final int inputSampleRate;
  final int maximumQueuedRequests;
  final int maximumQueuedPcmBytes;
  final Duration closeTimeout;

  final FutureOr<MlxBatchWorkerResult> Function(
    MlxBatchWorkerRequest,
    AudioCancellationToken?,
    void Function(double)?,
  )
  _infer;
  final FutureOr<void> Function()? _dispose;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  final Set<Completer<MlxBatchWorkerResult>> _pendingResults =
      <Completer<MlxBatchWorkerResult>>{};
  AudioCancellationController? _activeCancellation;
  int _queuedRequests = 0;
  int _queuedPcmBytes = 0;

  @override
  Future<MlxBatchWorkerResult> transcribe(
    MlxBatchWorkerRequest request, {
    AudioCancellationToken? cancellation,
    void Function(double progress)? onProgress,
  }) {
    if (_closeFuture != null) {
      return Future<MlxBatchWorkerResult>.error(
        StateError('MLX worker is closed.'),
      );
    }
    final pcmBytes = request.sampleCount * Float32List.bytesPerElement;
    if (_queuedRequests >= maximumQueuedRequests ||
        pcmBytes > maximumQueuedPcmBytes - _queuedPcmBytes) {
      return Future<MlxBatchWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX worker admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxBatchWorkerResult>();
    final operationCancellation = AudioCancellationController();
    _pendingResults.add(result);
    _queuedRequests += 1;
    _queuedPcmBytes += pcmBytes;
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then(operationCancellation.cancel));
    }
    _tail = _tail.then((_) async {
      try {
        if (result.isCompleted || _closeFuture != null) {
          return;
        }
        cancellation?.throwIfCancelled();
        _activeCancellation = operationCancellation;
        final value = await _infer(
          request,
          operationCancellation.token,
          onProgress,
        );
        operationCancellation.token.throwIfCancelled();
        if (!result.isCompleted) {
          result.complete(value);
        }
      } catch (error, stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      } finally {
        if (_activeCancellation == operationCancellation) {
          _activeCancellation = null;
        }
        _pendingResults.remove(result);
        _queuedRequests -= 1;
        _queuedPcmBytes -= pcmBytes;
      }
    });
    return result.future;
  }

  @override
  Future<void> close() => _closeFuture ??= _closeAfterQueuedWork();

  Future<void> _closeAfterQueuedWork() async {
    const cancellation = AudioCancellation(reason: 'worker_closed');
    _activeCancellation?.cancel(cancellation);
    for (final result in List<Completer<MlxBatchWorkerResult>>.of(
      _pendingResults,
    )) {
      if (!result.isCompleted) {
        result.completeError(const AudioCancelledException(cancellation));
      }
    }
    try {
      await _tail.timeout(closeTimeout);
    } on TimeoutException {
      // Injected same-isolate work cannot be killed. Closing still completes
      // deterministically; production uses the killable isolate worker.
    }
    await _dispose?.call();
  }
}

/// Long-lived MLX STT worker isolate.
///
/// The model is loaded once in the worker and all requests are serialized.
/// Only float32 PCM, strings, numeric generation controls, progress, and typed
/// transcript data cross the isolate boundary. Cancellation terminates the
/// active isolate promptly; the next queued request transparently starts a new
/// long-lived worker.
final class MlxIsolateBatchWorker implements MlxBatchWorker {
  MlxIsolateBatchWorker({
    required this.modelPath,
    this.hfToken,
    this.inputSampleRate = 16000,
    this.maximumQueuedRequests = 2,
    this.maximumQueuedPcmBytes = 268435456,
  }) {
    if (inputSampleRate <= 0) {
      throw ArgumentError.value(
        inputSampleRate,
        'inputSampleRate',
        'Must be positive.',
      );
    }
    _validateWorkerLimits(
      maximumQueuedRequests,
      maximumQueuedPcmBytes,
      Duration.zero,
    );
  }

  final String modelPath;
  final String? hfToken;

  @override
  final int inputSampleRate;
  final int maximumQueuedRequests;
  final int maximumQueuedPcmBytes;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exits;
  StreamSubscription<Object?>? _responseSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Future<void>? _unexpectedExitCleanup;
  Completer<void>? _starting;
  Completer<MlxBatchWorkerResult>? _activeResult;
  void Function(double)? _activeProgress;
  double _activeProgressValue = 0;
  int _activeRequestId = 0;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  Completer<void>? _closingAcknowledgement;
  final Set<Completer<MlxBatchWorkerResult>> _pendingResults =
      <Completer<MlxBatchWorkerResult>>{};
  int _queuedRequests = 0;
  int _queuedPcmBytes = 0;

  @override
  Future<MlxBatchWorkerResult> transcribe(
    MlxBatchWorkerRequest request, {
    AudioCancellationToken? cancellation,
    void Function(double progress)? onProgress,
  }) {
    if (_closeFuture != null) {
      return Future<MlxBatchWorkerResult>.error(
        StateError('MLX isolate worker is closed.'),
      );
    }
    final pcmBytes = request.sampleCount * Float32List.bytesPerElement;
    if (_queuedRequests >= maximumQueuedRequests ||
        pcmBytes > maximumQueuedPcmBytes - _queuedPcmBytes) {
      return Future<MlxBatchWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX worker admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxBatchWorkerResult>();
    _pendingResults.add(result);
    _queuedRequests += 1;
    _queuedPcmBytes += pcmBytes;
    _tail = _tail.then((_) async {
      try {
        if (result.isCompleted || _closeFuture != null) {
          return;
        }
        cancellation?.throwIfCancelled();
        final value = await _perform(
          request,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        if (!result.isCompleted) {
          result.complete(value);
        }
      } catch (error, stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      } finally {
        _pendingResults.remove(result);
        _queuedRequests -= 1;
        _queuedPcmBytes -= pcmBytes;
      }
    });
    return result.future;
  }

  Future<MlxBatchWorkerResult> _perform(
    MlxBatchWorkerRequest request, {
    AudioCancellationToken? cancellation,
    void Function(double progress)? onProgress,
  }) async {
    if (request.sampleRate <= 0) {
      throw ArgumentError.value(
        request.sampleRate,
        'request.sampleRate',
        'Must be positive.',
      );
    }
    if (request.channels <= 0 || request.sampleCount % request.channels != 0) {
      throw ArgumentError.value(
        request.channels,
        'request.channels',
        'Must describe complete interleaved PCM frames.',
      );
    }
    await _ensureStarted();
    cancellation?.throwIfCancelled();

    final requestId = ++_activeRequestId;
    final result = Completer<MlxBatchWorkerResult>();
    _activeResult = result;
    _activeProgress = onProgress;
    _activeProgressValue = 0;

    var cancelled = false;
    unawaited(
      cancellation?.whenCancelled.then((value) async {
        if (_activeResult != result || result.isCompleted) return;
        cancelled = true;
        await _terminateActiveWorker();
        if (!result.isCompleted) {
          result.completeError(AudioCancelledException(value));
        }
      }),
    );

    final chunks = <Uint8List>[
      for (final chunk in request.sampleChunks)
        Uint8List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes),
    ];
    _commands!.send(<Object?>[
      'transcribe',
      requestId,
      TransferableTypedData.fromList(chunks),
      request.sampleCount,
      request.sampleRate,
      request.channels,
      request.modelId,
      request.languageTag,
      request.maxTokens,
      request.temperature,
      request.topP,
      request.topK,
      request.repetitionPenalty,
      request.repetitionContextSize,
    ]);

    try {
      return await result.future;
    } finally {
      if (!cancelled && _activeResult == result) {
        _activeResult = null;
        _activeProgress = null;
      }
    }
  }

  Future<void> _ensureStarted() async {
    final cleanup = _unexpectedExitCleanup;
    if (cleanup != null) {
      await cleanup;
      if (identical(_unexpectedExitCleanup, cleanup)) {
        _unexpectedExitCleanup = null;
      }
    }
    if (_commands != null) return;
    final existing = _starting;
    if (existing != null) return existing.future;

    final starting = Completer<void>();
    _starting = starting;
    final responses = ReceivePort();
    final exits = ReceivePort();
    _responses = responses;
    _exits = exits;
    _responseSubscription = responses.listen(_handleResponse);
    _exitSubscription = exits.listen((_) {
      final acknowledgement = _closingAcknowledgement;
      if (acknowledgement != null) {
        if (!acknowledgement.isCompleted) acknowledgement.complete();
        _commands = null;
        _isolate = null;
        return;
      }
      final starting = _starting;
      final active = _activeResult;
      _commands = null;
      _isolate = null;
      final cleanup = _clearPorts();
      _unexpectedExitCleanup = cleanup;
      unawaited(_finishUnexpectedExit(cleanup, starting, active));
    });
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _mlxBatchWorkerMain,
        <Object?>[responses.sendPort, modelPath, hfToken, inputSampleRate],
        onExit: exits.sendPort,
        debugName: 'mlx-batch-$modelPath',
      );
      if (_closeFuture != null) {
        _isolate?.kill(priority: Isolate.immediate);
        throw const AudioCancelledException(
          AudioCancellation(reason: 'worker_closed'),
        );
      }
      await starting.future;
    } catch (error, stackTrace) {
      if (!starting.isCompleted) {
        starting.completeError(error, stackTrace);
        try {
          await starting.future;
        } catch (_) {
          // The initiating caller rethrows the same startup failure below.
        }
      }
      await _clearPorts();
      rethrow;
    } finally {
      _starting = null;
    }
  }

  void _handleResponse(Object? raw) {
    if (raw is! List<Object?> || raw.isEmpty) return;
    switch (raw[0]) {
      case 'ready':
        _commands = raw[1]! as SendPort;
        final starting = _starting;
        if (starting != null && !starting.isCompleted) starting.complete();
      case 'progress':
        final id = raw[1]! as int;
        if (id != _activeRequestId) return;
        final stage = GenerationStage.values[raw[2]! as int];
        final completed = raw[3]! as int;
        final total = raw[4] as int?;
        final fraction = total == null || total == 0 ? null : completed / total;
        if (fraction != null) {
          final stageProgress = switch (stage) {
            GenerationStage.preparing => 0.0,
            GenerationStage.encoding => 0.1 + fraction * 0.2,
            GenerationStage.decoding => 0.3 + fraction * 0.69,
            GenerationStage.synthesizing => 0.3 + fraction * 0.69,
            GenerationStage.completed => 1.0,
          };
          _activeProgressValue = stageProgress > _activeProgressValue
              ? stageProgress.clamp(0, 1)
              : _activeProgressValue;
          try {
            _activeProgress?.call(_activeProgressValue);
          } catch (_) {
            // Progress observers are diagnostic and cannot corrupt inference.
          }
        }
      case 'result':
        final id = raw[1]! as int;
        final active = _activeResult;
        if (id != _activeRequestId || active == null || active.isCompleted) {
          return;
        }
        final segmentData = (raw[4]! as List<Object?>);
        active.complete(
          MlxBatchWorkerResult(
            text: raw[2]! as String,
            languageTag: raw[3] as String?,
            segments: segmentData.map((entry) {
              final values = entry! as List<Object?>;
              return MlxBatchWorkerSegment(
                text: values[0]! as String,
                start: Duration(microseconds: values[1]! as int),
                end: Duration(microseconds: values[2]! as int),
              );
            }),
          ),
        );
      case 'error':
        final id = raw[1]! as int;
        final active = _activeResult;
        if (id != _activeRequestId || active == null || active.isCompleted) {
          return;
        }
        active.completeError(
          MlxWorkerException(
            code: raw[2]! as String,
            safeCause: raw[3]! as String,
          ),
        );
      case 'closed':
        final acknowledgement = _closingAcknowledgement;
        if (acknowledgement != null && !acknowledgement.isCompleted) {
          acknowledgement.complete();
        }
    }
  }

  Future<void> _terminateActiveWorker() async {
    _isolate?.kill(priority: Isolate.immediate);
    _commands = null;
    _isolate = null;
    _activeResult = null;
    _activeProgress = null;
    _activeProgressValue = 0;
    await _clearPorts();
  }

  Future<void> _finishUnexpectedExit(
    Future<void> cleanup,
    Completer<void>? starting,
    Completer<MlxBatchWorkerResult>? active,
  ) async {
    await cleanup;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(
        StateError('MLX worker isolate exited during startup.'),
      );
    }
    if (active != null && !active.isCompleted) {
      active.completeError(
        StateError('MLX worker isolate exited during inference.'),
      );
    }
  }

  Future<void> _clearPorts() async {
    await _responseSubscription?.cancel();
    await _exitSubscription?.cancel();
    _responseSubscription = null;
    _exitSubscription = null;
    _responses?.close();
    _exits?.close();
    _responses = null;
    _exits = null;
  }

  @override
  Future<void> close() => _closeFuture ??= _closeImmediately();

  Future<void> _closeImmediately() async {
    const cancellation = AudioCancellation(reason: 'worker_closed');
    final hadPendingWork = _pendingResults.isNotEmpty;
    for (final result in List<Completer<MlxBatchWorkerResult>>.of(
      _pendingResults,
    )) {
      if (!result.isCompleted) {
        result.completeError(const AudioCancelledException(cancellation));
      }
    }
    final active = _activeResult;
    if (active != null && !active.isCompleted) {
      active.completeError(const AudioCancelledException(cancellation));
    }
    if (hadPendingWork) {
      await _terminateActiveWorker();
    } else {
      await _closeIdleWorker();
    }
    await _tail;
    await _clearPorts();
    _commands = null;
    _isolate = null;
  }

  Future<void> _closeIdleWorker() async {
    final isolate = _isolate;
    if (isolate == null || _commands == null) {
      return;
    }
    final acknowledgement = Completer<void>();
    _closingAcknowledgement = acknowledgement;
    _commands!.send(const <Object?>['close']);
    try {
      await acknowledgement.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
    } finally {
      _closingAcknowledgement = null;
    }
  }
}

/// Safe cross-isolate MLX worker error.
final class MlxWorkerException implements Exception {
  const MlxWorkerException({required this.code, required this.safeCause});

  final String code;
  final String safeCause;

  @override
  String toString() => 'MlxWorkerException(code: $code, cause: $safeCause)';
}

Future<void> _mlxBatchWorkerMain(List<Object?> arguments) async {
  final responses = arguments[0]! as SendPort;
  final modelPath = arguments[1]! as String;
  final hfToken = arguments[2] as String?;
  final expectedSampleRate = arguments[3]! as int;
  final commands = ReceivePort();
  responses.send(<Object?>['ready', commands.sendPort]);

  SttModel? model;
  await for (final raw in commands) {
    if (raw is! List<Object?> || raw.isEmpty) continue;
    final kind = raw[0];
    if (kind == 'close') {
      model?.close();
      responses.send(const <Object?>['closed']);
      commands.close();
      break;
    }
    if (kind != 'transcribe') continue;
    final requestId = raw[1]! as int;
    try {
      model ??= await STT.loadModel(modelPath, hfToken: hfToken);
      if (model.sampleRate != expectedSampleRate) {
        throw StateError(
          'Loaded model expects ${model.sampleRate} Hz, configured worker '
          'expects $expectedSampleRate Hz.',
        );
      }
      final data = (raw[2]! as TransferableTypedData).materialize();
      final byteView = data.asUint8List();
      final sampleCount = raw[3]! as int;
      final interleaved = Float32List.fromList(
        Float32List.view(byteView.buffer, byteView.offsetInBytes, sampleCount),
      );
      final samples = _preprocessPcm(
        interleaved,
        channels: raw[5]! as int,
        inputSampleRate: raw[4]! as int,
        outputSampleRate: expectedSampleRate,
      );
      final params = SttGenerateParameters(
        maxTokens: raw[8]! as int,
        temperature: raw[9]! as double,
        topP: raw[10]! as double,
        topK: raw[11]! as int,
        language: raw[7] as String?,
        repetitionPenalty: raw[12]! as double,
        repetitionContextSize: raw[13]! as int,
      );
      final output = model.generate(
        samples,
        params: params,
        onProgress: (progress) {
          responses.send(<Object?>[
            'progress',
            requestId,
            progress.stage.index,
            progress.completed,
            progress.total,
          ]);
        },
      );
      responses.send(<Object?>[
        'result',
        requestId,
        output.text,
        output.language,
        <Object?>[
          for (final segment
              in output.segments ?? const <TranscriptionSegment>[])
            <Object?>[
              segment.text,
              (segment.start * Duration.microsecondsPerSecond).round(),
              (segment.end * Duration.microsecondsPerSecond).round(),
            ],
        ],
      ]);
    } catch (error) {
      responses.send(<Object?>[
        'error',
        requestId,
        'inference_failed',
        error.runtimeType.toString(),
      ]);
    }
  }
}

Float32List _preprocessPcm(
  Float32List interleaved, {
  required int channels,
  required int inputSampleRate,
  required int outputSampleRate,
}) {
  if (channels <= 0 || interleaved.length % channels != 0) {
    throw ArgumentError('Input PCM does not match its channel count.');
  }
  if (inputSampleRate <= 0 || outputSampleRate <= 0) {
    throw ArgumentError('PCM sample rates must be positive.');
  }
  final frameCount = interleaved.length ~/ channels;
  final mono = Float32List(frameCount);
  if (channels == 1) {
    mono.setAll(0, interleaved);
  } else {
    for (var frame = 0; frame < frameCount; frame++) {
      var sum = 0.0;
      final base = frame * channels;
      for (var channel = 0; channel < channels; channel++) {
        sum += interleaved[base + channel];
      }
      mono[frame] = sum / channels;
    }
  }
  if (mono.isEmpty || inputSampleRate == outputSampleRate) {
    return mono;
  }
  final outputLength = (mono.length * outputSampleRate / inputSampleRate)
      .round();
  final output = Float32List(outputLength);
  final ratio = inputSampleRate / outputSampleRate;
  for (var index = 0; index < outputLength; index++) {
    final position = index * ratio;
    final left = position.floor().clamp(0, mono.length - 1);
    final right = (left + 1).clamp(0, mono.length - 1);
    final fraction = position - left;
    output[index] = mono[left] + (mono[right] - mono[left]) * fraction;
  }
  return output;
}

void _validateWorkerLimits(
  int maximumQueuedRequests,
  int maximumQueuedPcmBytes,
  Duration closeTimeout,
) {
  if (maximumQueuedRequests <= 0) {
    throw ArgumentError.value(
      maximumQueuedRequests,
      'maximumQueuedRequests',
      'Must be positive.',
    );
  }
  if (maximumQueuedPcmBytes <= 0) {
    throw ArgumentError.value(
      maximumQueuedPcmBytes,
      'maximumQueuedPcmBytes',
      'Must be positive.',
    );
  }
  if (closeTimeout.isNegative) {
    throw ArgumentError.value(
      closeTimeout,
      'closeTimeout',
      'Must not be negative.',
    );
  }
}

void _validateBatchWorkerRequest(MlxBatchWorkerRequest request) {
  if (request.sampleChunks.isEmpty ||
      request.sampleChunks.any((chunk) => chunk.isEmpty)) {
    throw ArgumentError.value(
      request.sampleChunks,
      'samples',
      'Must contain non-empty PCM.',
    );
  }
  if (request.sampleRate <= 0) {
    throw ArgumentError.value(
      request.sampleRate,
      'sampleRate',
      'Must be positive.',
    );
  }
  if (request.channels <= 0 || request.sampleCount % request.channels != 0) {
    throw ArgumentError.value(
      request.channels,
      'channels',
      'Must describe complete interleaved PCM frames.',
    );
  }
  if (request.modelId.trim().isEmpty) {
    throw ArgumentError.value(request.modelId, 'modelId', 'Must not be empty.');
  }
}
