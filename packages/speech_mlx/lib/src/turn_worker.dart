import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:mlx_audio/mlx_audio.dart';

import 'worker.dart' show MlxWorkerException;

/// Domain-only request sent to a serialized MLX turn-completion worker.
///
/// The window is mono by contract: `TurnCompletionRequest` rejects multi-channel
/// audio at construction, so a scorer never has to downmix. The sample rate is
/// carried rather than assumed — Smart Turn's own front-end resamples with the
/// same polyphase filter the rest of `mlx_audio` uses, which is better than
/// anything this boundary could do on the way past.
final class MlxTurnWorkerRequest {
  /// Copies [samples] so the caller may keep mutating its ring buffer.
  MlxTurnWorkerRequest({
    required Float32List samples,
    required this.sampleRate,
    required this.modelId,
    this.threshold,
  }) : samples = Float32List.fromList(samples) {
    _validateTurnWorkerRequest(this);
  }

  /// Takes ownership of [samples].
  ///
  /// Callers must not mutate the list after passing it to this constructor.
  MlxTurnWorkerRequest.owned({
    required this.samples,
    required this.sampleRate,
    required this.modelId,
    this.threshold,
  }) {
    _validateTurnWorkerRequest(this);
  }

  /// Mono PCM ending at the moment being judged.
  final Float32List samples;

  final int sampleRate;

  /// Stable model identifier the scorer routes on.
  final String modelId;

  /// Overrides the checkpoint's completion threshold for this request.
  final double? threshold;

  int get sampleCount => samples.length;
}

/// Domain-only verdict returned by an MLX turn-completion worker.
final class MlxTurnWorkerResult {
  MlxTurnWorkerResult({
    required this.probability,
    required this.isComplete,
    required this.threshold,
  }) {
    if (!probability.isFinite || probability < 0 || probability > 1) {
      throw ArgumentError.value(
        probability,
        'probability',
        'Must be between 0 and 1.',
      );
    }
    if (!threshold.isFinite || threshold < 0 || threshold > 1) {
      throw ArgumentError.value(
        threshold,
        'threshold',
        'Must be between 0 and 1.',
      );
    }
  }

  /// Probability that the speaker finished their turn.
  final double probability;

  /// Whether the model considers the turn complete (`probability > threshold`).
  final bool isComplete;

  /// The threshold that produced [isComplete].
  final double threshold;
}

/// Replaceable worker boundary used by `MlxSmartTurnScorer`.
///
/// Implementations must serialize model access. A production implementation
/// uses an isolate ([MlxIsolateTurnWorker]); tests can inject a deterministic
/// fake through [SerializedMlxTurnWorker].
abstract interface class MlxTurnWorker {
  /// Native mono sample rate of the loaded classifier.
  ///
  /// Requests at another rate are resampled next to the model, not here.
  int get inputSampleRate;

  /// Longest window the classifier reads. Longer requests keep their tail.
  Duration get maximumWindow;

  Future<MlxTurnWorkerResult> score(
    MlxTurnWorkerRequest request, {
    AudioCancellationToken? cancellation,
  });

  /// Releases the loaded model. Repeated calls must have no effect.
  Future<void> close();
}

/// A reusable serializer for an injected scoring function.
///
/// This implementation does not itself move work off the calling isolate. It is
/// useful for tests and for wrapping an embedding-specific worker. Use
/// [MlxIsolateTurnWorker] for MLX inference from a UI process.
final class SerializedMlxTurnWorker implements MlxTurnWorker {
  SerializedMlxTurnWorker({
    this.inputSampleRate = 16000,
    this.maximumWindow = const Duration(seconds: 8),
    this.maximumQueuedRequests = 4,
    this.closeTimeout = const Duration(seconds: 2),
    required FutureOr<MlxTurnWorkerResult> Function(
      MlxTurnWorkerRequest request,
      AudioCancellationToken? cancellation,
    )
    infer,
    FutureOr<void> Function()? dispose,
  }) : // Public callback labels intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _infer = infer,
       // ignore: prefer_initializing_formals
       _dispose = dispose {
    _validateTurnWorkerLimits(
      inputSampleRate: inputSampleRate,
      maximumWindow: maximumWindow,
      maximumQueuedRequests: maximumQueuedRequests,
      closeTimeout: closeTimeout,
    );
  }

  @override
  final int inputSampleRate;

  @override
  final Duration maximumWindow;

  final int maximumQueuedRequests;
  final Duration closeTimeout;

  final FutureOr<MlxTurnWorkerResult> Function(
    MlxTurnWorkerRequest,
    AudioCancellationToken?,
  )
  _infer;
  final FutureOr<void> Function()? _dispose;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  final Set<Completer<MlxTurnWorkerResult>> _pendingResults =
      <Completer<MlxTurnWorkerResult>>{};
  AudioCancellationController? _activeCancellation;
  int _queuedRequests = 0;

  @override
  Future<MlxTurnWorkerResult> score(
    MlxTurnWorkerRequest request, {
    AudioCancellationToken? cancellation,
  }) {
    if (_closeFuture != null) {
      return Future<MlxTurnWorkerResult>.error(
        StateError('MLX turn worker is closed.'),
      );
    }
    if (_queuedRequests >= maximumQueuedRequests) {
      return Future<MlxTurnWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX turn worker admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxTurnWorkerResult>();
    final operationCancellation = AudioCancellationController();
    _pendingResults.add(result);
    _queuedRequests += 1;
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
        final value = await _infer(request, operationCancellation.token);
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
    for (final result in List<Completer<MlxTurnWorkerResult>>.of(
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

/// Long-lived MLX turn-completion worker isolate.
///
/// The pinned Smart Turn checkpoint is loaded once in the worker — including
/// the MLX buffer-cache cap and the silence warmup `SmartTurn.load` performs —
/// and every request is serialized behind it. Only float32 PCM and numbers
/// cross the isolate boundary.
///
/// Unlike `MlxIsolateBatchWorker` there is no model path: `SmartTurn.load`
/// resolves a repo pinned by revision and per-file SHA-256, so the only knob is
/// [modelDirectory], which points at an already-materialized snapshot and skips
/// the hub entirely.
///
/// Cancellation terminates the active isolate promptly; the next queued request
/// transparently starts a new long-lived worker (and pays the model load
/// again).
final class MlxIsolateTurnWorker implements MlxTurnWorker {
  MlxIsolateTurnWorker({
    this.modelDirectory,
    this.hfToken,
    this.warmup = true,
    this.inputSampleRate = 16000,
    this.maximumWindow = const Duration(seconds: 8),
    this.maximumQueuedRequests = 4,
  }) {
    _validateTurnWorkerLimits(
      inputSampleRate: inputSampleRate,
      maximumWindow: maximumWindow,
      maximumQueuedRequests: maximumQueuedRequests,
      closeTimeout: Duration.zero,
    );
  }

  /// Local snapshot to load instead of resolving the pin from the hub.
  final String? modelDirectory;

  /// Bearer token for the pinned download; falls back to `HF_TOKEN`.
  final String? hfToken;

  /// Score 1 s of silence at load so the first real window skips Metal JIT.
  final bool warmup;

  @override
  final int inputSampleRate;

  @override
  final Duration maximumWindow;

  final int maximumQueuedRequests;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exits;
  StreamSubscription<Object?>? _responseSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Future<void>? _unexpectedExitCleanup;
  Completer<void>? _starting;
  Completer<MlxTurnWorkerResult>? _activeResult;
  int _activeRequestId = 0;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  Completer<void>? _closingAcknowledgement;
  final Set<Completer<MlxTurnWorkerResult>> _pendingResults =
      <Completer<MlxTurnWorkerResult>>{};
  int _queuedRequests = 0;

  @override
  Future<MlxTurnWorkerResult> score(
    MlxTurnWorkerRequest request, {
    AudioCancellationToken? cancellation,
  }) {
    if (_closeFuture != null) {
      return Future<MlxTurnWorkerResult>.error(
        StateError('MLX turn isolate worker is closed.'),
      );
    }
    if (_queuedRequests >= maximumQueuedRequests) {
      return Future<MlxTurnWorkerResult>.error(
        const MlxWorkerException(
          code: 'worker_queue_full',
          safeCause: 'Bounded MLX turn worker admission rejected the request.',
        ),
      );
    }
    final result = Completer<MlxTurnWorkerResult>();
    _pendingResults.add(result);
    _queuedRequests += 1;
    _tail = _tail.then((_) async {
      try {
        if (result.isCompleted || _closeFuture != null) {
          return;
        }
        cancellation?.throwIfCancelled();
        final value = await _perform(request, cancellation: cancellation);
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

  Future<MlxTurnWorkerResult> _perform(
    MlxTurnWorkerRequest request, {
    AudioCancellationToken? cancellation,
  }) async {
    await _ensureStarted();
    cancellation?.throwIfCancelled();

    final requestId = ++_activeRequestId;
    final result = Completer<MlxTurnWorkerResult>();
    _activeResult = result;

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

    final samples = request.samples;
    _commands!.send(<Object?>[
      'score',
      requestId,
      TransferableTypedData.fromList(<Uint8List>[
        Uint8List.view(
          samples.buffer,
          samples.offsetInBytes,
          samples.lengthInBytes,
        ),
      ]),
      samples.length,
      request.sampleRate,
      request.threshold,
    ]);

    try {
      return await result.future;
    } finally {
      if (!cancelled && _activeResult == result) {
        _activeResult = null;
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
        _mlxTurnWorkerMain,
        <Object?>[
          responses.sendPort,
          modelDirectory,
          hfToken,
          warmup,
          inputSampleRate,
          maximumWindow.inMilliseconds,
        ],
        onExit: exits.sendPort,
        debugName: 'mlx-turn-${modelDirectory ?? 'pinned'}',
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
      case 'result':
        final id = raw[1]! as int;
        final active = _activeResult;
        if (id != _activeRequestId || active == null || active.isCompleted) {
          return;
        }
        active.complete(
          MlxTurnWorkerResult(
            probability: raw[2]! as double,
            isComplete: raw[3]! as bool,
            threshold: raw[4]! as double,
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
    await _clearPorts();
  }

  Future<void> _finishUnexpectedExit(
    Future<void> cleanup,
    Completer<void>? startup,
    Completer<MlxTurnWorkerResult>? active,
  ) async {
    await cleanup;
    if (startup != null && !startup.isCompleted) {
      startup.completeError(
        StateError('MLX turn worker isolate exited during startup.'),
      );
    }
    if (active != null && !active.isCompleted) {
      active.completeError(
        StateError('MLX turn worker isolate exited during scoring.'),
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
    for (final result in List<Completer<MlxTurnWorkerResult>>.of(
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

Future<void> _mlxTurnWorkerMain(List<Object?> arguments) async {
  final responses = arguments[0]! as SendPort;
  final modelDirectory = arguments[1] as String?;
  final hfToken = arguments[2] as String?;
  final warmup = arguments[3]! as bool;
  final expectedSampleRate = arguments[4]! as int;
  final maximumWindowMs = arguments[5]! as int;
  final commands = ReceivePort();
  responses.send(<Object?>['ready', commands.sendPort]);

  SmartTurnModel? model;
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
    if (kind != 'score') {
      continue;
    }
    final requestId = raw[1]! as int;
    try {
      model ??= await SmartTurn.load(
        modelDirectory: modelDirectory == null
            ? null
            : Directory(modelDirectory),
        hfToken: hfToken,
        warmup: warmup,
      );
      if (model.sampleRate != expectedSampleRate) {
        throw StateError(
          'Loaded turn model expects ${model.sampleRate} Hz, configured worker '
          'expects $expectedSampleRate Hz.',
        );
      }
      if (model.maxAudioSeconds * 1000 != maximumWindowMs) {
        throw StateError(
          'Loaded turn model reads ${model.maxAudioSeconds} s windows, '
          'configured worker advertises ${maximumWindowMs / 1000} s.',
        );
      }
      final data = (raw[2]! as TransferableTypedData).materialize();
      final bytes = data.asUint8List();
      final sampleCount = raw[3]! as int;
      final samples = Float32List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        sampleCount,
      );
      final threshold = raw[5] as double?;
      final output = model.predictEndpoint(
        samples,
        sampleRate: raw[4]! as int,
        threshold: threshold,
      );
      responses.send(<Object?>[
        'result',
        requestId,
        output.probability,
        output.isComplete,
        threshold ?? model.threshold,
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

void _validateTurnWorkerRequest(MlxTurnWorkerRequest request) {
  if (request.samples.isEmpty) {
    throw ArgumentError.value(
      request.samples,
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
  if (request.modelId.trim().isEmpty) {
    throw ArgumentError.value(request.modelId, 'modelId', 'Must not be empty.');
  }
  final threshold = request.threshold;
  if (threshold != null &&
      (!threshold.isFinite || threshold < 0 || threshold > 1)) {
    throw ArgumentError.value(
      threshold,
      'threshold',
      'Must be between 0 and 1.',
    );
  }
}

void _validateTurnWorkerLimits({
  required int inputSampleRate,
  required Duration maximumWindow,
  required int maximumQueuedRequests,
  required Duration closeTimeout,
}) {
  if (inputSampleRate <= 0) {
    throw ArgumentError.value(
      inputSampleRate,
      'inputSampleRate',
      'Must be positive.',
    );
  }
  if (maximumWindow <= Duration.zero) {
    throw ArgumentError.value(
      maximumWindow,
      'maximumWindow',
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
  if (closeTimeout.isNegative) {
    throw ArgumentError.value(
      closeTimeout,
      'closeTimeout',
      'Must not be negative.',
    );
  }
}
