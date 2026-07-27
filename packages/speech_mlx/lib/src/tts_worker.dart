import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:mlx_audio/mlx_audio.dart';

import 'worker.dart';

/// Provider-neutral request passed to an MLX text-to-speech worker.
final class MlxTtsWorkerRequest {
  const MlxTtsWorkerRequest({
    required this.text,
    required this.modelId,
    required this.voiceId,
    this.languageTag,
    this.temperature = 0.7,
    this.maxTokens,
    this.seed,
  });

  final String text;
  final String modelId;
  final String voiceId;
  final String? languageTag;
  final double temperature;
  final int? maxTokens;
  final int? seed;
}

/// One owned PCM chunk emitted by an MLX synthesis worker.
final class MlxTtsWorkerChunk {
  factory MlxTtsWorkerChunk({
    required Float32List samples,
    required int sampleRate,
    required int frameIndex,
    required int sampleOffset,
  }) => MlxTtsWorkerChunk.owned(
    samples: Float32List.fromList(samples),
    sampleRate: sampleRate,
    frameIndex: frameIndex,
    sampleOffset: sampleOffset,
  );

  /// Takes ownership of [samples].
  ///
  /// Callers must not mutate [samples] after construction.
  MlxTtsWorkerChunk.owned({
    required this.samples,
    required this.sampleRate,
    required this.frameIndex,
    required this.sampleOffset,
  }) {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'Must not be empty.');
    }
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be positive.');
    }
    if (frameIndex < 0) {
      throw ArgumentError.value(
        frameIndex,
        'frameIndex',
        'Must not be negative.',
      );
    }
    if (sampleOffset < 0) {
      throw ArgumentError.value(
        sampleOffset,
        'sampleOffset',
        'Must not be negative.',
      );
    }
  }

  final Float32List samples;
  final int sampleRate;
  final int frameIndex;
  final int sampleOffset;
}

/// Completion metadata returned without copying the complete waveform.
final class MlxTtsWorkerResult {
  const MlxTtsWorkerResult({
    required this.sampleRate,
    required this.sampleCount,
    required this.frameCount,
  });

  final int sampleRate;
  final int sampleCount;
  final int frameCount;
}

/// Serialized MLX synthesis boundary used by `MlxSpeechProvider`.
///
/// Implementations transfer only text, numeric controls, and owned PCM domain
/// data. They must invoke [onAudioChunk] while inference is still running and
/// stop delivering chunks as soon as [cancellation] is observed.
abstract interface class MlxTtsWorker {
  /// Fixed mono output sample rate advertised before synthesis starts.
  int get outputSampleRate;

  Future<MlxTtsWorkerResult> synthesize(
    MlxTtsWorkerRequest request, {
    required void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    AudioCancellationToken? cancellation,
  });

  /// Releases the loaded model. Repeated calls must have no effect.
  Future<void> close();
}

/// A reusable serializer for an injected TTS inference function.
///
/// This is useful for deterministic tests and embedding-specific workers. It
/// does not itself move inference off the caller isolate; use
/// [MlxIsolateTtsWorker] in a Flutter UI process.
final class SerializedMlxTtsWorker implements MlxTtsWorker {
  SerializedMlxTtsWorker({
    required this.outputSampleRate,
    this.maximumQueuedRequests = 2,
    this.maximumOutputSamples = 14400000,
    this.closeTimeout = const Duration(seconds: 2),
    required FutureOr<MlxTtsWorkerResult> Function(
      MlxTtsWorkerRequest request,
      AudioCancellationToken? cancellation,
      void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    )
    infer,
    FutureOr<void> Function()? dispose,
  }) : // Public callback labels intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _infer = infer,
       // ignore: prefer_initializing_formals
       _dispose = dispose {
    _validateTtsWorkerLimits(
      outputSampleRate: outputSampleRate,
      maximumQueuedRequests: maximumQueuedRequests,
      maximumOutputSamples: maximumOutputSamples,
      closeTimeout: closeTimeout,
    );
  }

  @override
  final int outputSampleRate;
  final int maximumQueuedRequests;
  final int maximumOutputSamples;
  final Duration closeTimeout;

  final FutureOr<MlxTtsWorkerResult> Function(
    MlxTtsWorkerRequest,
    AudioCancellationToken?,
    void Function(MlxTtsWorkerChunk),
  )
  _infer;
  final FutureOr<void> Function()? _dispose;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  final Set<Completer<MlxTtsWorkerResult>> _pendingResults =
      <Completer<MlxTtsWorkerResult>>{};
  AudioCancellationController? _activeCancellation;
  int _queuedRequests = 0;

  @override
  Future<MlxTtsWorkerResult> synthesize(
    MlxTtsWorkerRequest request, {
    required void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    AudioCancellationToken? cancellation,
  }) {
    if (_closeFuture != null) {
      return Future<MlxTtsWorkerResult>.error(
        StateError('MLX TTS worker is closed.'),
      );
    }
    if (_queuedRequests >= maximumQueuedRequests) {
      return Future<MlxTtsWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX TTS admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxTtsWorkerResult>();
    final operationCancellation = AudioCancellationController();
    _pendingResults.add(result);
    _queuedRequests += 1;
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((value) {
          operationCancellation.cancel(value);
          if (!result.isCompleted) {
            result.completeError(AudioCancelledException(value));
          }
        }),
      );
    }
    _tail = _tail.then((_) async {
      var emittedSamples = 0;
      try {
        if (result.isCompleted || _closeFuture != null) {
          return;
        }
        operationCancellation.token.throwIfCancelled();
        _activeCancellation = operationCancellation;
        final value = await _infer(request, operationCancellation.token, (
          chunk,
        ) {
          operationCancellation.token.throwIfCancelled();
          if (chunk.samples.length > maximumOutputSamples - emittedSamples) {
            throw const MlxWorkerException(
              code: 'synthesis_output_limit',
              safeCause: 'MLX TTS exceeded its bounded PCM output limit.',
            );
          }
          emittedSamples += chunk.samples.length;
          if (!result.isCompleted) {
            onAudioChunk(chunk);
          }
        });
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
      }
    });
    return result.future;
  }

  @override
  Future<void> close() => _closeFuture ??= _closeAfterQueuedWork();

  Future<void> _closeAfterQueuedWork() async {
    const cancellation = AudioCancellation(reason: 'worker_closed');
    _activeCancellation?.cancel(cancellation);
    for (final result in List<Completer<MlxTtsWorkerResult>>.of(
      _pendingResults,
    )) {
      if (!result.isCompleted) {
        result.completeError(const AudioCancelledException(cancellation));
      }
    }
    try {
      await _tail.timeout(closeTimeout);
    } on TimeoutException {
      // Injected same-isolate work cannot be killed. Production uses the
      // killable isolate worker.
    }
    await _dispose?.call();
  }
}

/// Long-lived, serialized MLX TTS worker isolate.
///
/// The model is loaded once. Incremental PCM chunks are transferred back while
/// `TtsModel.generate` is still running. Cancelling active synchronous MLX
/// inference terminates the isolate promptly; the next request starts a fresh
/// worker and reloads the model.
final class MlxIsolateTtsWorker implements MlxTtsWorker {
  MlxIsolateTtsWorker({
    required this.modelPath,
    this.hfToken,
    this.outputSampleRate = 24000,
    this.maximumQueuedRequests = 2,
    this.maximumOutputSamples = 14400000,
  }) {
    _validateTtsWorkerLimits(
      outputSampleRate: outputSampleRate,
      maximumQueuedRequests: maximumQueuedRequests,
      maximumOutputSamples: maximumOutputSamples,
      closeTimeout: Duration.zero,
    );
  }

  final String modelPath;
  final String? hfToken;

  @override
  final int outputSampleRate;
  final int maximumQueuedRequests;
  final int maximumOutputSamples;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exits;
  StreamSubscription<Object?>? _responseSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Future<void>? _unexpectedExitCleanup;
  Completer<void>? _starting;
  Completer<MlxTtsWorkerResult>? _activeResult;
  void Function(MlxTtsWorkerChunk)? _activeChunk;
  int _activeRequestId = 0;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  Completer<void>? _closingAcknowledgement;
  final Set<Completer<MlxTtsWorkerResult>> _pendingResults =
      <Completer<MlxTtsWorkerResult>>{};
  int _queuedRequests = 0;

  @override
  Future<MlxTtsWorkerResult> synthesize(
    MlxTtsWorkerRequest request, {
    required void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    AudioCancellationToken? cancellation,
  }) {
    if (_closeFuture != null) {
      return Future<MlxTtsWorkerResult>.error(
        StateError('MLX TTS isolate worker is closed.'),
      );
    }
    if (_queuedRequests >= maximumQueuedRequests) {
      return Future<MlxTtsWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX TTS admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxTtsWorkerResult>();
    _pendingResults.add(result);
    _queuedRequests += 1;
    _tail = _tail.then((_) async {
      try {
        if (result.isCompleted || _closeFuture != null) {
          return;
        }
        cancellation?.throwIfCancelled();
        final value = await _perform(
          request,
          onAudioChunk: onAudioChunk,
          cancellation: cancellation,
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
      }
    });
    return result.future;
  }

  Future<MlxTtsWorkerResult> _perform(
    MlxTtsWorkerRequest request, {
    required void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    AudioCancellationToken? cancellation,
  }) async {
    await _ensureStarted();
    cancellation?.throwIfCancelled();

    final requestId = ++_activeRequestId;
    final result = Completer<MlxTtsWorkerResult>();
    _activeResult = result;
    _activeChunk = onAudioChunk;

    var cancelled = false;
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((value) async {
          if (_activeResult != result || result.isCompleted) {
            return;
          }
          cancelled = true;
          await _terminateActiveWorker();
          if (!result.isCompleted) {
            result.completeError(AudioCancelledException(value));
          }
        }),
      );
    }

    _commands!.send(<Object?>[
      'synthesize',
      requestId,
      request.text,
      request.modelId,
      request.voiceId,
      request.languageTag,
      request.temperature,
      request.maxTokens,
      request.seed,
    ]);

    try {
      return await result.future;
    } finally {
      if (!cancelled && _activeResult == result) {
        _activeResult = null;
        _activeChunk = null;
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
    if (_commands != null) {
      return;
    }
    final existing = _starting;
    if (existing != null) {
      return existing.future;
    }

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
        if (!acknowledgement.isCompleted) {
          acknowledgement.complete();
        }
        _commands = null;
        _isolate = null;
        return;
      }
      final startup = _starting;
      final active = _activeResult;
      _commands = null;
      _isolate = null;
      final cleanup = _clearPorts();
      _unexpectedExitCleanup = cleanup;
      unawaited(_finishUnexpectedExit(cleanup, startup, active));
    });
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _mlxTtsWorkerMain,
        <Object?>[
          responses.sendPort,
          modelPath,
          hfToken,
          outputSampleRate,
          maximumOutputSamples,
        ],
        onExit: exits.sendPort,
        debugName: 'mlx-tts-$modelPath',
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
    if (raw is! List<Object?> || raw.isEmpty) {
      return;
    }
    switch (raw[0]) {
      case 'ready':
        _commands = raw[1]! as SendPort;
        final starting = _starting;
        if (starting != null && !starting.isCompleted) {
          starting.complete();
        }
      case 'chunk':
        final id = raw[1]! as int;
        final active = _activeResult;
        if (id != _activeRequestId || active == null || active.isCompleted) {
          return;
        }
        try {
          final data = (raw[2]! as TransferableTypedData).materialize();
          final bytes = data.asUint8List();
          final sampleCount = raw[3]! as int;
          final samples = Float32List.view(
            bytes.buffer,
            bytes.offsetInBytes,
            sampleCount,
          );
          _activeChunk?.call(
            MlxTtsWorkerChunk.owned(
              samples: samples,
              sampleRate: raw[4]! as int,
              frameIndex: raw[5]! as int,
              sampleOffset: raw[6]! as int,
            ),
          );
        } catch (error, stackTrace) {
          unawaited(_terminateAfterChunkFailure(active, error, stackTrace));
        }
      case 'result':
        final id = raw[1]! as int;
        final active = _activeResult;
        if (id != _activeRequestId || active == null || active.isCompleted) {
          return;
        }
        active.complete(
          MlxTtsWorkerResult(
            sampleRate: raw[2]! as int,
            sampleCount: raw[3]! as int,
            frameCount: raw[4]! as int,
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
    _activeChunk = null;
    await _clearPorts();
  }

  Future<void> _terminateAfterChunkFailure(
    Completer<MlxTtsWorkerResult> active,
    Object error,
    StackTrace stackTrace,
  ) async {
    await _terminateActiveWorker();
    if (!active.isCompleted) {
      active.completeError(error, stackTrace);
    }
  }

  Future<void> _finishUnexpectedExit(
    Future<void> cleanup,
    Completer<void>? startup,
    Completer<MlxTtsWorkerResult>? active,
  ) async {
    await cleanup;
    if (startup != null && !startup.isCompleted) {
      startup.completeError(
        StateError('MLX TTS worker isolate exited during startup.'),
      );
    }
    if (active != null && !active.isCompleted) {
      active.completeError(
        StateError('MLX TTS worker isolate exited during synthesis.'),
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
    for (final result in List<Completer<MlxTtsWorkerResult>>.of(
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

Future<void> _mlxTtsWorkerMain(List<Object?> arguments) async {
  final responses = arguments[0]! as SendPort;
  final modelPath = arguments[1]! as String;
  final hfToken = arguments[2] as String?;
  final expectedSampleRate = arguments[3]! as int;
  final maximumOutputSamples = arguments[4]! as int;
  final commands = ReceivePort();
  responses.send(<Object?>['ready', commands.sendPort]);

  TtsModel? model;
  await for (final raw in commands) {
    if (raw is! List<Object?> || raw.isEmpty) {
      continue;
    }
    final kind = raw[0];
    if (kind == 'close') {
      model?.close();
      responses.send(const <Object?>['closed']);
      commands.close();
      break;
    }
    if (kind != 'synthesize') {
      continue;
    }
    final requestId = raw[1]! as int;
    try {
      model ??= await TTS.loadModel(modelPath, hfToken: hfToken);
      if (model.sampleRate != expectedSampleRate) {
        throw StateError(
          'Loaded model produces ${model.sampleRate} Hz, configured worker '
          'advertises $expectedSampleRate Hz.',
        );
      }
      var expectedFrameIndex = 0;
      var expectedSampleOffset = 0;
      final output = model.generate(
        raw[2]! as String,
        voice: raw[4]! as String,
        params: TtsGenerateParameters(
          temperature: raw[6]! as double,
          maxTokens: raw[7] as int?,
          seed: raw[8] as int?,
        ),
        onAudioChunk: (chunk) {
          if (chunk.sampleRate != expectedSampleRate ||
              chunk.frameIndex != expectedFrameIndex ||
              chunk.sampleOffset != expectedSampleOffset ||
              chunk.samples.isEmpty) {
            throw StateError('MLX TTS emitted an invalid PCM chunk timeline.');
          }
          if (chunk.samples.length >
              maximumOutputSamples - expectedSampleOffset) {
            throw const _MlxTtsOutputLimitException();
          }
          final bytes = Uint8List.view(
            chunk.samples.buffer,
            chunk.samples.offsetInBytes,
            chunk.samples.lengthInBytes,
          );
          responses.send(<Object?>[
            'chunk',
            requestId,
            TransferableTypedData.fromList(<Uint8List>[bytes]),
            chunk.samples.length,
            chunk.sampleRate,
            chunk.frameIndex,
            chunk.sampleOffset,
          ]);
          expectedFrameIndex += 1;
          expectedSampleOffset += chunk.samples.length;
        },
      );
      if (output.sampleRate != expectedSampleRate ||
          output.samples.length != expectedSampleOffset) {
        throw StateError('MLX TTS output does not match its streamed PCM.');
      }
      responses.send(<Object?>[
        'result',
        requestId,
        output.sampleRate,
        output.samples.length,
        output.frameCount,
      ]);
    } catch (error) {
      responses.send(<Object?>[
        'error',
        requestId,
        error is GenerationCancelledException
            ? 'synthesis_cancelled'
            : error is _MlxTtsOutputLimitException
            ? 'synthesis_output_limit'
            : 'synthesis_failed',
        error.runtimeType.toString(),
      ]);
    }
  }
}

final class _MlxTtsOutputLimitException implements Exception {
  const _MlxTtsOutputLimitException();
}

void _validateTtsWorkerLimits({
  required int outputSampleRate,
  required int maximumQueuedRequests,
  required int maximumOutputSamples,
  required Duration closeTimeout,
}) {
  if (outputSampleRate <= 0) {
    throw ArgumentError.value(
      outputSampleRate,
      'outputSampleRate',
      'Must be positive.',
    );
  }
  if (maximumQueuedRequests <= 0) {
    throw ArgumentError.value(
      maximumQueuedRequests,
      'maximumQueuedRequests',
      'Must be positive.',
    );
  }
  if (maximumOutputSamples <= 0) {
    throw ArgumentError.value(
      maximumOutputSamples,
      'maximumOutputSamples',
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
