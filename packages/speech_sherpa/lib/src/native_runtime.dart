// The long-lived worker-isolate transcriber, the empty-`modelType` auto-routing
// workaround, and the per-speaker embedding budget are derived from Control
// Center (https://github.com/SamuelAlev/control-center), MIT (c) 2026 Samuel
// Alev. See the NOTICE file at the root of this package.

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'failure.dart';
import 'options.dart';
import 'runtime.dart';

/// Initializes sherpa's native bindings for the calling isolate.
///
/// sherpa resolves its symbols into isolate-local statics, so every isolate
/// that touches the API must call this for itself. Skipping it in a worker
/// surfaces as `Please initialize sherpa-onnx first`, which reads like a
/// missing model rather than a missing binding.
void ensureSherpaBindings([String? libraryDirectory]) {
  sherpa.initBindings(libraryDirectory);
}

/// Production runtime backed by the `sherpa_onnx` plugin.
///
/// Recognition runs on a long-lived worker isolate: a decode is a synchronous
/// FFI call lasting hundreds of milliseconds to seconds, which would freeze the
/// UI and starve capture on the main isolate. Diarization uses a throwaway
/// isolate because it runs once per recording rather than per window.
final class SherpaNativeRuntime implements SherpaRuntime {
  /// Creates a runtime.
  ///
  /// [libraryDirectory] is forwarded to sherpa's binding loader for hosts that
  /// cannot resolve the native library by leaf name.
  SherpaNativeRuntime({this.libraryDirectory});

  /// Directory containing the sherpa native library, or null for the default.
  final String? libraryDirectory;

  final Set<_Closable> _drivers = <_Closable>{};
  Future<void>? _closeFuture;

  bool get _isClosed => _closeFuture != null;

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('sherpa-onnx runtime is closed.');
    }
  }

  void _register(_Closable driver) {
    _drivers.add(driver);
    driver.onClosed = () => _drivers.remove(driver);
  }

  @override
  Future<SherpaBatchAsrDriver> createBatchAsr(
    SherpaBatchAsrConfiguration configuration,
  ) async {
    _ensureOpen();
    final worker = await _AsrWorker.spawn(configuration, libraryDirectory);
    if (_isClosed) {
      await worker.close();
      throw StateError('sherpa-onnx runtime is closed.');
    }
    _register(worker);
    return worker;
  }

  @override
  Future<SherpaDiarizationDriver> createDiarizer(
    SherpaDiarizationConfiguration configuration,
  ) async {
    _ensureOpen();
    final driver = _NativeDiarizationDriver(configuration, libraryDirectory);
    _register(driver);
    return driver;
  }

  @override
  Future<SherpaVadDriver> createVad(
    SherpaVadConfiguration configuration,
  ) async {
    _ensureOpen();
    ensureSherpaBindings(libraryDirectory);
    final detector = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: configuration.modelPath,
          threshold: configuration.threshold,
          minSilenceDuration: configuration.minimumSilenceSeconds,
          minSpeechDuration: configuration.minimumSpeechSeconds,
          windowSize: configuration.windowSize,
          maxSpeechDuration: configuration.maximumSpeechSeconds,
        ),
        numThreads: configuration.numThreads,
        debug: false,
      ),
      bufferSizeInSeconds: configuration.bufferSizeSeconds,
    );
    final driver = _NativeVadDriver(detector, configuration.windowSize);
    _register(driver);
    return driver;
  }

  @override
  Future<void> close() => _closeFuture ??= _closeAll();

  Future<void> _closeAll() async {
    final drivers = List<_Closable>.of(_drivers);
    _drivers.clear();
    for (final driver in drivers) {
      driver.onClosed = null;
      await driver.close();
    }
  }
}

abstract class _Closable {
  void Function()? onClosed;

  Future<void> close();
}

/// Long-lived recognition worker.
final class _AsrWorker extends _Closable implements SherpaBatchAsrDriver {
  _AsrWorker._(this._commands, this._responses, this._isolate);

  final SendPort _commands;
  final ReceivePort _responses;
  final Isolate _isolate;
  final Queue<Completer<SherpaDriverTranscript>> _pending =
      Queue<Completer<SherpaDriverTranscript>>();
  bool _closed = false;

  static Future<_AsrWorker> spawn(
    SherpaBatchAsrConfiguration configuration,
    String? libraryDirectory,
  ) async {
    final initPort = RawReceivePort();
    final connection = Completer<(ReceivePort, SendPort)>.sync();
    initPort.handler = (Object? message) {
      final responses = ReceivePort.fromRawReceivePort(initPort);
      if (message is _WorkerFailure) {
        connection.completeError(
          sherpaSpeechFailure(
            'sherpa_model_load_failed',
            'prepare',
            'The sherpa-onnx recognizer could not be loaded.',
            cause: message,
          ),
        );
        responses.close();
        return;
      }
      connection.complete((responses, message! as SendPort));
    };

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _asrWorkerEntryPoint,
        _AsrWorkerStart(
          replyTo: initPort.sendPort,
          configuration: configuration,
          libraryDirectory: libraryDirectory,
        ),
        debugName: 'speech_sherpa.asr',
      );
    } on Object {
      initPort.close();
      rethrow;
    }

    final (responses, commands) = await connection.future;
    final worker = _AsrWorker._(commands, responses, isolate);
    responses.listen(worker._handleResponse);
    return worker;
  }

  void _handleResponse(Object? message) {
    if (_pending.isEmpty) {
      return;
    }
    final completer = _pending.removeFirst();
    switch (message) {
      case _WorkerFailure():
        completer.completeError(
          sherpaSpeechFailure(
            'sherpa_decode_failed',
            'recognition',
            'sherpa-onnx failed to decode the supplied audio.',
            cause: message,
          ),
        );
      case final SherpaDriverTranscript transcript:
        completer.complete(transcript);
      default:
        completer.completeError(
          sherpaSpeechFailure(
            'sherpa_protocol_error',
            'recognition',
            'The sherpa-onnx worker returned an unexpected response.',
          ),
        );
    }
  }

  @override
  Future<SherpaDriverTranscript> transcribe(Float32List samples) {
    if (_closed) {
      throw StateError('The sherpa-onnx recognizer is closed.');
    }
    final completer = Completer<SherpaDriverTranscript>();
    _pending.add(completer);
    // TransferableTypedData moves the buffer without copying it.
    _commands.send(TransferableTypedData.fromList(<Float32List>[samples]));
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _commands.send(null);
    _responses.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(
        StateError('The sherpa-onnx recognizer was closed.'),
      );
    }
    onClosed?.call();
  }
}

final class _AsrWorkerStart {
  const _AsrWorkerStart({
    required this.replyTo,
    required this.configuration,
    required this.libraryDirectory,
  });

  final SendPort replyTo;
  final SherpaBatchAsrConfiguration configuration;
  final String? libraryDirectory;
}

final class _WorkerFailure {
  const _WorkerFailure(this.message);

  final String message;
}

void _asrWorkerEntryPoint(_AsrWorkerStart start) {
  final commands = ReceivePort();
  final sherpa.OfflineRecognizer recognizer;
  try {
    // Isolate-local statics: the worker must bind for itself.
    ensureSherpaBindings(start.libraryDirectory);
    recognizer = _createRecognizer(start.configuration);
  } catch (error) {
    start.replyTo.send(_WorkerFailure(error.toString()));
    commands.close();
    return;
  }

  start.replyTo.send(commands.sendPort);

  commands.listen((Object? message) {
    if (message == null) {
      recognizer.free();
      commands.close();
      return;
    }
    try {
      final samples = (message as TransferableTypedData)
          .materialize()
          .asFloat32List();
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        start.replyTo.send(
          SherpaDriverTranscript(
            text: result.text,
            languageCode: result.lang.isEmpty ? null : result.lang,
            tokens: result.tokens,
            timestamps: result.timestamps,
          ),
        );
      } finally {
        stream.free();
      }
    } catch (error) {
      start.replyTo.send(_WorkerFailure(error.toString()));
    }
  });
}

sherpa.OfflineRecognizer _createRecognizer(
  SherpaBatchAsrConfiguration configuration,
) {
  final paths = configuration.paths;
  final model = switch (paths.model.kind) {
    SherpaRecognitionModelKind.transducer => sherpa.OfflineModelConfig(
      transducer: sherpa.OfflineTransducerModelConfig(
        encoder: paths.encoder,
        decoder: paths.decoder,
        joiner: paths.joiner!,
      ),
      tokens: paths.tokens,
      numThreads: configuration.numThreads,
      provider: configuration.provider,
      debug: false,
      // modelType stays empty on purpose. sherpa auto-routes NeMo-Parakeet
      // versus k2-Zipformer from the model metadata; hardcoding 'transducer'
      // makes every Parakeet model fail on a 'vocab_size' metadata lookup.
      modelType: '',
    ),
    SherpaRecognitionModelKind.whisper => sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: paths.encoder,
        decoder: paths.decoder,
        task: 'transcribe',
        // An empty language asks Whisper to detect it.
        language: configuration.languageCode ?? '',
      ),
      tokens: paths.tokens,
      numThreads: configuration.numThreads,
      provider: configuration.provider,
      debug: false,
      modelType: '',
    ),
  };

  return sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: model,
      decodingMethod: configuration.decodingMethod,
    ),
  );
}

final class _NativeDiarizationDriver extends _Closable
    implements SherpaDiarizationDriver {
  _NativeDiarizationDriver(this._configuration, this._libraryDirectory);

  final SherpaDiarizationConfiguration _configuration;
  final String? _libraryDirectory;
  bool _closed = false;

  @override
  Future<List<SherpaDriverSpeakerSpan>> diarize(Float32List samples) async {
    if (_closed) {
      throw StateError('The sherpa-onnx diarizer is closed.');
    }
    final configuration = _configuration;
    final libraryDirectory = _libraryDirectory;
    // Diarization runs once per recording, so a throwaway isolate is cheaper
    // than keeping several hundred megabytes of models resident.
    return Isolate.run<List<SherpaDriverSpeakerSpan>>(
      () => _diarizeSync(configuration, libraryDirectory, samples),
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    onClosed?.call();
  }
}

List<SherpaDriverSpeakerSpan> _diarizeSync(
  SherpaDiarizationConfiguration configuration,
  String? libraryDirectory,
  Float32List samples,
) {
  ensureSherpaBindings(libraryDirectory);
  final diarization = sherpa.OfflineSpeakerDiarization(
    sherpa.OfflineSpeakerDiarizationConfig(
      segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
        pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
          model: configuration.paths.segmentation,
        ),
        numThreads: configuration.numThreads,
        debug: false,
      ),
      embedding: sherpa.SpeakerEmbeddingExtractorConfig(
        model: configuration.paths.embedding,
        numThreads: configuration.numThreads,
        debug: false,
      ),
      clustering: sherpa.FastClusteringConfig(
        // -1 asks sherpa to infer the speaker count from the audio.
        numClusters: configuration.exactSpeakerCount ?? -1,
        threshold: configuration.clusteringThreshold,
      ),
      minDurationOn: configuration.minimumDurationOn,
      minDurationOff: configuration.minimumDurationOff,
    ),
  );

  try {
    final segments = diarization.process(samples: samples);
    if (segments.isEmpty) {
      return const <SherpaDriverSpeakerSpan>[];
    }
    final embeddings = _computeSpeakerEmbeddings(
      configuration: configuration,
      segments: segments,
      samples: samples,
    );
    return <SherpaDriverSpeakerSpan>[
      for (final segment in segments)
        SherpaDriverSpeakerSpan(
          speaker: segment.speaker,
          startSeconds: segment.start,
          endSeconds: segment.end,
          embedding: embeddings[segment.speaker],
        ),
    ];
  } finally {
    diarization.free();
  }
}

/// Computes one representative vector per speaker cluster.
///
/// Each speaker contributes at most
/// [SherpaDiarizationConfiguration.maximumEmbeddingSamples] of their own audio:
/// an hour of speech does not produce a better centroid than thirty seconds.
Map<int, Float32List> _computeSpeakerEmbeddings({
  required SherpaDiarizationConfiguration configuration,
  required List<sherpa.OfflineSpeakerDiarizationSegment> segments,
  required Float32List samples,
}) {
  final extractor = sherpa.SpeakerEmbeddingExtractor(
    config: sherpa.SpeakerEmbeddingExtractorConfig(
      model: configuration.paths.embedding,
      numThreads: configuration.numThreads,
      debug: false,
    ),
  );
  try {
    final grouped = <int, List<sherpa.OfflineSpeakerDiarizationSegment>>{};
    for (final segment in segments) {
      grouped.putIfAbsent(segment.speaker, () => []).add(segment);
    }

    final result = <int, Float32List>{};
    for (final entry in grouped.entries) {
      final collected = <double>[];
      for (final segment in entry.value) {
        if (collected.length >= configuration.maximumEmbeddingSamples) {
          break;
        }
        final start = (segment.start * 16000).round().clamp(0, samples.length);
        final end = (segment.end * 16000).round().clamp(0, samples.length);
        if (end <= start) {
          continue;
        }
        final remaining =
            configuration.maximumEmbeddingSamples - collected.length;
        final take = (end - start) < remaining ? (end - start) : remaining;
        collected.addAll(samples.sublist(start, start + take));
      }
      if (collected.isEmpty) {
        continue;
      }
      final stream = extractor.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.fromList(collected),
          sampleRate: 16000,
        );
        stream.inputFinished();
        if (!extractor.isReady(stream)) {
          continue;
        }
        final embedding = extractor.compute(stream);
        if (embedding.isNotEmpty) {
          result[entry.key] = embedding;
        }
      } finally {
        stream.free();
      }
    }
    return result;
  } finally {
    extractor.free();
  }
}

final class _NativeVadDriver extends _Closable implements SherpaVadDriver {
  _NativeVadDriver(this._detector, this._windowSize);

  final sherpa.VoiceActivityDetector _detector;
  final int _windowSize;
  final List<double> _carry = <double>[];
  bool _closed = false;

  @override
  Future<List<SherpaDriverSpeechSpan>> accept(Float32List samples) async {
    if (_closed) {
      throw StateError('The sherpa-onnx detector is closed.');
    }
    // Silero consumes exact windows; the remainder waits for the next frame.
    _carry.addAll(samples);
    final usable = _carry.length - (_carry.length % _windowSize);
    if (usable > 0) {
      final window = Float32List.fromList(_carry.sublist(0, usable));
      _carry.removeRange(0, usable);
      _detector.acceptWaveform(window);
    }
    return _drain();
  }

  @override
  Future<List<SherpaDriverSpeechSpan>> flush() async {
    if (_closed) {
      return const <SherpaDriverSpeechSpan>[];
    }
    if (_carry.isNotEmpty) {
      final padded = Float32List(_windowSize);
      padded.setRange(0, _carry.length, _carry);
      _detector.acceptWaveform(padded);
      _carry.clear();
    }
    _detector.flush();
    return _drain();
  }

  List<SherpaDriverSpeechSpan> _drain() {
    final spans = <SherpaDriverSpeechSpan>[];
    while (!_detector.isEmpty()) {
      final segment = _detector.front();
      spans.add(
        SherpaDriverSpeechSpan(
          startSample: segment.start,
          sampleCount: segment.samples.length,
        ),
      );
      _detector.pop();
    }
    return spans;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _detector.free();
    onClosed?.call();
  }
}
