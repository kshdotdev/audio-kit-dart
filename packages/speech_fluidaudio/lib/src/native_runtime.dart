import 'dart:async';
import 'dart:typed_data';

import 'package:fluidaudio_dart/fluidaudio_dart.dart' as native;
import 'package:meta/meta.dart';

import 'drivers.dart';
import 'options.dart';

/// Production runtime backed by the `fluidaudio_dart` Flutter plugin.
///
/// SDK values are translated at this boundary and never enter `speech_core`.
///
/// [modelsRootPath] points FluidAudio's ASR/VAD/diarizer/EOU/CTC model
/// resolution at a host-managed directory
/// (`<modelsRootPath>/<repoFolderName>/<files>`); [ttsRootPath] does the same
/// for TTS assets. [offline] forbids network fetches, so a missing pinned
/// artifact fails loudly instead of being re-downloaded into the host's
/// directory — always pair it with a host-managed root. The configuration is
/// applied exactly once, before the first driver is created; the native side
/// rejects a root change after any model instance exists.
final class FluidNativeRuntime implements FluidAudioRuntime {
  /// Creates a runtime, optionally rooted at host-managed model directories.
  FluidNativeRuntime({
    this._modelsRootPath,
    this._ttsRootPath,
    this._offline = false,
    @visibleForTesting this._models,
  });

  final String? _modelsRootPath;
  final String? _ttsRootPath;
  final bool _offline;
  final native.FluidModels? _models;
  Future<void>? _configureFuture;
  final Set<_NativeDriver> _drivers = <_NativeDriver>{};
  Future<void>? _closeFuture;

  bool get _isClosed => _closeFuture != null;

  /// Applies the host-managed roots and offline mode now instead of lazily at
  /// the first driver, so a root conflict surfaces where the host can explain
  /// it. Idempotent; throws `FluidAudioException` with code `ModelRootsLocked`
  /// when a different root is already latched in this process.
  Future<void> ensureConfigured() => _ensureConfigured();

  Future<void> _ensureConfigured() {
    if (_modelsRootPath == null && _ttsRootPath == null && !_offline) {
      return Future<void>.value();
    }
    return _configureFuture ??= _configure();
  }

  Future<void> _configure() async {
    final models = _models ?? native.FluidModels();
    if (_modelsRootPath != null || _ttsRootPath != null) {
      try {
        await models.setModelRoots(
          native.FluidModelRoots(
            modelsRoot: _modelsRootPath,
            ttsRoot: _ttsRootPath,
          ),
        );
      } on native.FluidAudioException catch (error) {
        // The native roots are a process-wide latch: once any model instance
        // exists they refuse to change. A new runtime asking for the roots
        // that are already in effect is the normal recreate-after-dispose
        // path and must succeed; only a genuinely different root is an error.
        if (error.code != 'ModelRootsLocked') {
          rethrow;
        }
        final current = await models.modelRoots();
        final sameModels =
            _modelsRootPath == null ||
            _normalizePath(current.modelsRoot) == _normalizePath(_modelsRootPath);
        final sameTts =
            _ttsRootPath == null ||
            _normalizePath(current.ttsRoot) == _normalizePath(_ttsRootPath);
        if (!sameModels || !sameTts) {
          rethrow;
        }
      }
    }
    if (_offline) {
      await models.setOfflineMode(true);
    }
  }

  static String? _normalizePath(String? path) {
    if (path == null) {
      return null;
    }
    var value = path;
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  @override
  Future<FluidBatchAsrDriver> createBatchAsr(
    FluidRecognitionModel model,
  ) async {
    _ensureOpen();
    await _ensureConfigured();
    final recognizer = await native.FluidAsr.load(version: _asrVersion(model));
    if (_isClosed) {
      await recognizer.dispose();
      throw StateError('FluidAudio runtime is closed.');
    }
    return _register<_NativeBatchAsrDriver>(_NativeBatchAsrDriver(recognizer));
  }

  @override
  Future<FluidDiarizationDriver> createDiarizer(
    FluidDiarizationDriverConfiguration configuration,
  ) async {
    _ensureOpen();
    await _ensureConfigured();
    final diarizer = await native.FluidDiarizer.create(
      clusteringThreshold: configuration.clusteringThreshold,
      numSpeakers: configuration.exactSpeakerCount,
      minSpeakers: configuration.minimumSpeakers,
      maxSpeakers: configuration.maximumSpeakers,
    );
    if (_isClosed) {
      await diarizer.dispose();
      throw StateError('FluidAudio runtime is closed.');
    }
    return _register<_NativeDiarizationDriver>(
      _NativeDiarizationDriver(diarizer),
    );
  }

  @override
  Future<FluidEndOfUtteranceDriver> createEndOfUtterance({
    required FluidEndOfUtteranceChunk chunk,
    required Duration debounce,
  }) async {
    _ensureOpen();
    await _ensureConfigured();
    final detector = await native.FluidEou.create(
      chunkSize: switch (chunk) {
        FluidEndOfUtteranceChunk.milliseconds160 => native.EouChunkSize.ms160,
        FluidEndOfUtteranceChunk.milliseconds320 => native.EouChunkSize.ms320,
        FluidEndOfUtteranceChunk.milliseconds1280 => native.EouChunkSize.ms1280,
      },
      eouDebounceMs: debounce.inMilliseconds,
    );
    if (_isClosed) {
      await detector.dispose();
      throw StateError('FluidAudio runtime is closed.');
    }
    return _register<_NativeEndOfUtteranceDriver>(
      _NativeEndOfUtteranceDriver(detector),
    );
  }

  @override
  Future<FluidStreamingAsrDriver> createStreamingAsr(
    FluidStreamingAsrDriverConfiguration configuration,
  ) async {
    _ensureOpen();
    await _ensureConfigured();
    native.FluidStreamingAsr? recognizer;
    native.FluidCtcVocabulary? vocabulary;
    try {
      recognizer = await native.FluidStreamingAsr.create(
        version: _asrVersion(configuration.model),
        config: native.FluidStreamingConfig(
          chunkSeconds: configuration.chunkSeconds,
          hypothesisChunkSeconds: configuration.hypothesisChunkSeconds,
          leftContextSeconds: configuration.leftContextSeconds,
          rightContextSeconds: configuration.rightContextSeconds,
          minContextForConfirmation:
              configuration.minimumContextForConfirmation,
          confirmationThreshold: configuration.confirmationThreshold,
        ),
      );
      if (configuration.vocabulary.isNotEmpty) {
        vocabulary = await native.FluidCtcVocabulary.load(
          terms: <native.FluidVocabularyTerm>[
            for (final term in configuration.vocabulary)
              native.FluidVocabularyTerm(
                term.text,
                weight: term.weight,
                aliases: term.aliases.isEmpty ? null : term.aliases,
              ),
          ],
          minSimilarity: configuration.vocabularyMinimumSimilarity,
        );
        await recognizer.configureVocabulary(vocabulary);
      }
      if (_isClosed) {
        await vocabulary?.dispose();
        await recognizer.dispose();
        throw StateError('FluidAudio runtime is closed.');
      }
      return _register<_NativeStreamingAsrDriver>(
        _NativeStreamingAsrDriver(recognizer, vocabulary, configuration.source),
      );
    } catch (_) {
      await vocabulary?.dispose();
      await recognizer?.dispose();
      rethrow;
    }
  }

  @override
  Future<FluidTtsDriver> createTts(
    FluidTtsDriverConfiguration configuration,
  ) async {
    _ensureOpen();
    await _ensureConfigured();
    final _NativeTtsDriver driver;
    switch (configuration.engine) {
      case FluidSynthesisEngine.pocket:
        final synthesizer = await native.FluidPocketTts.create();
        driver = _NativePocketTtsDriver(synthesizer, configuration.temperature);
      case FluidSynthesisEngine.kokoroEnglish:
      case FluidSynthesisEngine.kokoroMandarin:
      case FluidSynthesisEngine.kokoroJapanese:
        final synthesizer = await native.FluidKokoroTts.create(
          variant: switch (configuration.engine) {
            FluidSynthesisEngine.kokoroEnglish => native.KokoroVariant.english,
            FluidSynthesisEngine.kokoroMandarin =>
              native.KokoroVariant.mandarin,
            FluidSynthesisEngine.kokoroJapanese =>
              native.KokoroVariant.japanese,
            FluidSynthesisEngine.pocket => throw StateError(
              'PocketTTS does not have a Kokoro model variant.',
            ),
          },
        );
        driver = _NativeKokoroTtsDriver(synthesizer);
    }
    if (_isClosed) {
      await driver.close();
      throw StateError('FluidAudio runtime is closed.');
    }
    return _register<_NativeTtsDriver>(driver);
  }

  @override
  Future<FluidItnDriver> createItn() async {
    _ensureOpen();
    await _ensureConfigured();
    final normalizer = native.FluidItn();
    if (!await normalizer.isNativeAvailable()) {
      throw StateError(
        'The FluidAudio inverse text normalization library is unavailable.',
      );
    }
    if (_isClosed) {
      throw StateError('FluidAudio runtime is closed.');
    }
    return _register<_NativeItnDriver>(_NativeItnDriver(normalizer));
  }

  @override
  Future<FluidVadDriver> createVad({
    required double threshold,
    required Duration minimumSilence,
  }) async {
    _ensureOpen();
    await _ensureConfigured();
    native.FluidVad? detector;
    native.FluidVadStream? stream;
    try {
      detector = await native.FluidVad.create(threshold: threshold);
      stream = await detector.stream(
        minSilenceDuration:
            minimumSilence.inMicroseconds / Duration.microsecondsPerSecond,
      );
      if (_isClosed) {
        await stream.dispose();
        await detector.dispose();
        throw StateError('FluidAudio runtime is closed.');
      }
      return _register<_NativeVadDriver>(_NativeVadDriver(detector, stream));
    } catch (_) {
      await stream?.dispose();
      await detector?.dispose();
      rethrow;
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    final drivers = List<_NativeDriver>.of(_drivers);
    await Future.wait<void>(<Future<void>>[
      for (final driver in drivers) driver.close(),
    ]);
    _drivers.clear();
  }

  T _register<T extends _NativeDriver>(T driver) {
    driver.onClosed = () {
      _drivers.remove(driver);
    };
    _drivers.add(driver);
    return driver;
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('FluidAudio runtime is closed.');
    }
  }
}

native.AsrVersion _asrVersion(FluidRecognitionModel model) => switch (model) {
  FluidRecognitionModel.parakeetV2 => native.AsrVersion.v2,
  FluidRecognitionModel.parakeetV3 => native.AsrVersion.v3,
};

abstract base class _NativeDriver {
  Future<void>? _closeFuture;
  void Function()? onClosed;

  Future<void> close() => _closeFuture ??= _closeOnce();

  Future<void> _closeOnce() async {
    try {
      await closeNative();
    } finally {
      onClosed?.call();
    }
  }

  Future<void> closeNative();
}

final class _NativeStreamingAsrDriver extends _NativeDriver
    implements FluidStreamingAsrDriver {
  _NativeStreamingAsrDriver(this._recognizer, this._vocabulary, this._source);

  final native.FluidStreamingAsr _recognizer;
  final native.FluidCtcVocabulary? _vocabulary;
  final FluidRecognitionSource _source;

  @override
  Stream<FluidDriverTranscriptionUpdate> get updates => _recognizer.updates.map(
    (update) => FluidDriverTranscriptionUpdate(
      text: update.text,
      promotesPreviousHypothesis: update.isConfirmed,
      confidence: update.confidence,
      timings: <FluidDriverTokenTiming>[
        for (final timing
            in update.tokenTimings ?? const <native.FluidTokenTiming>[])
          FluidDriverTokenTiming(
            text: timing.token,
            start: timing.start,
            end: timing.end,
            confidence: timing.confidence,
          ),
      ],
    ),
  );

  @override
  Future<void> feed(Float32List samples) => _recognizer.feed(samples);

  @override
  Future<String> finish() => _recognizer.finish();

  @override
  Future<void> start() => _recognizer.start(
    source: switch (_source) {
      FluidRecognitionSource.microphone => native.FluidAudioSource.microphone,
      FluidRecognitionSource.systemAudio => native.FluidAudioSource.system,
    },
  );

  @override
  Future<void> closeNative() async {
    try {
      await _recognizer.dispose();
    } finally {
      await _vocabulary?.dispose();
    }
  }
}

final class _NativeBatchAsrDriver extends _NativeDriver
    implements FluidBatchAsrDriver {
  _NativeBatchAsrDriver(this._recognizer);

  final native.FluidAsr _recognizer;

  @override
  Future<FluidDriverBatchAsrResult> transcribe(
    Float32List samples, {
    String? language,
  }) async {
    final result = await _recognizer.transcribe(samples, language: language);
    return FluidDriverBatchAsrResult(
      text: result.text,
      confidence: result.confidence,
      duration: result.duration,
      timings: <FluidDriverTokenTiming>[
        for (final timing
            in result.tokenTimings ?? const <native.FluidTokenTiming>[])
          FluidDriverTokenTiming(
            text: timing.token,
            start: timing.start,
            end: timing.end,
            confidence: timing.confidence,
          ),
      ],
    );
  }

  @override
  Future<void> closeNative() => _recognizer.dispose();
}

final class _NativeVadDriver extends _NativeDriver implements FluidVadDriver {
  _NativeVadDriver(this._detector, this._stream);

  final native.FluidVad _detector;
  final native.FluidVadStream _stream;

  @override
  Stream<FluidDriverVadEvent> get events => _stream.events.map(
    (event) => FluidDriverVadEvent(
      probability: event.probability,
      sampleIndex: event.sampleIndex,
      time: event.time,
    ),
  );

  @override
  Future<void> feed(Float32List samples) => _stream.feed(samples);

  @override
  Future<void> closeNative() async {
    try {
      await _stream.dispose();
    } finally {
      await _detector.dispose();
    }
  }
}

final class _NativeEndOfUtteranceDriver extends _NativeDriver
    implements FluidEndOfUtteranceDriver {
  _NativeEndOfUtteranceDriver(this._detector);

  final native.FluidEou _detector;

  @override
  Stream<FluidDriverEndOfUtteranceUpdate> get updates =>
      StreamGroup.merge(<Stream<FluidDriverEndOfUtteranceUpdate>>[
        _detector.partials.map(
          (text) => FluidDriverEndOfUtteranceUpdate(text: text, isFinal: false),
        ),
        _detector.utterances.map(
          (text) => FluidDriverEndOfUtteranceUpdate(text: text, isFinal: true),
        ),
      ]);

  @override
  Future<void> feed(Float32List samples) => _detector.feed(samples);

  @override
  Future<String> finish() => _detector.finish();

  @override
  Future<void> closeNative() => _detector.dispose();
}

final class _NativeDiarizationDriver extends _NativeDriver
    implements FluidDiarizationDriver {
  _NativeDiarizationDriver(this._diarizer);

  final native.FluidDiarizer _diarizer;

  @override
  Future<List<FluidDriverSpeakerSegment>> diarize(Float32List samples) async {
    final result = await _diarizer.diarize(samples);
    return <FluidDriverSpeakerSegment>[
      for (final segment in result.segments)
        FluidDriverSpeakerSegment(
          speakerId: segment.speakerId,
          start: segment.start,
          end: segment.end,
          confidence: segment.qualityScore,
          embedding: segment.embedding,
        ),
    ];
  }

  @override
  Future<void> closeNative() => _diarizer.dispose();
}

final class _NativeItnDriver extends _NativeDriver
    implements FluidTranscriptItnDriver {
  _NativeItnDriver(this._normalizer);

  final native.FluidItn _normalizer;

  @override
  Future<String> normalizeSentence(String text) =>
      _normalizer.normalizeSentence(text);

  @override
  Future<String> normalizeTranscript({
    required String text,
    required List<FluidDriverTokenTiming> timings,
  }) async {
    // `FluidAsrResult` is the shape FluidAudio's ITN host accepts for a whole
    // transcription, but only the text and the token timings take part in
    // normalization: the confidence, the durations and the token IDs are
    // echoed back unread. Neutral values go over the wire rather than invented
    // ones, and the caller keeps the real confidence on the Dart side.
    final normalized = await _normalizer.normalizeResult(
      native.FluidAsrResult(
        text: text,
        confidence: 0,
        duration: Duration.zero,
        processingTime: Duration.zero,
        tokenTimings: <native.FluidTokenTiming>[
          for (final timing in timings)
            native.FluidTokenTiming(
              token: timing.text,
              tokenId: 0,
              start: timing.start,
              end: timing.end,
              confidence: timing.confidence,
            ),
        ],
      ),
    );
    return normalized.text;
  }

  @override
  Future<void> addRule({required String spoken, required String written}) =>
      _normalizer.addRule(spoken: spoken, written: written);

  /// `FluidItn` holds no disposable native handle, so releasing it is a no-op.
  @override
  Future<void> closeNative() async {}
}

abstract base class _NativeTtsDriver extends _NativeDriver
    implements FluidTtsDriver {}

final class _NativePocketTtsDriver extends _NativeTtsDriver {
  _NativePocketTtsDriver(this._synthesizer, this._temperature);

  final native.FluidPocketTts _synthesizer;
  final double _temperature;

  @override
  Stream<FluidDriverTtsChunk> synthesize({
    required String text,
    required String? voice,
    required double rate,
  }) => _synthesizer
      .synthesizeStreaming(text, voice: voice, temperature: _temperature)
      .map(
        (chunk) => FluidDriverTtsChunk(
          samples: Float32List.fromList(chunk.samples),
          frameIndex: chunk.frameIndex,
        ),
      );

  @override
  Future<void> closeNative() => _synthesizer.dispose();
}

final class _NativeKokoroTtsDriver extends _NativeTtsDriver {
  _NativeKokoroTtsDriver(this._synthesizer);

  final native.FluidKokoroTts _synthesizer;

  @override
  Stream<FluidDriverTtsChunk> synthesize({
    required String text,
    required String? voice,
    required double rate,
  }) async* {
    final result = await _synthesizer.synthesizeDetailed(
      text,
      voice: voice,
      speed: rate,
    );
    yield FluidDriverTtsChunk(
      samples: Float32List.fromList(result.samples),
      frameIndex: 0,
    );
  }

  @override
  Future<void> closeNative() => _synthesizer.dispose();
}

/// Minimal stream merge that avoids coupling the adapter to an Rx package.
final class StreamGroup<T> {
  StreamGroup._();

  static Stream<T> merge<T>(Iterable<Stream<T>> streams) {
    late StreamController<T> controller;
    final subscriptions = <StreamSubscription<T>>[];
    var remaining = 0;

    controller = StreamController<T>.broadcast(
      onListen: () {
        final values = streams.toList(growable: false);
        remaining = values.length;
        if (remaining == 0) {
          unawaited(controller.close());
          return;
        }
        for (final stream in values) {
          subscriptions.add(
            stream.listen(
              controller.add,
              onError: controller.addError,
              onDone: () {
                remaining -= 1;
                if (remaining == 0) {
                  unawaited(controller.close());
                }
              },
            ),
          );
        }
      },
      onCancel: () async {
        await Future.wait<void>(<Future<void>>[
          for (final subscription in subscriptions) subscription.cancel(),
        ]);
      },
    );
    return controller.stream;
  }
}
