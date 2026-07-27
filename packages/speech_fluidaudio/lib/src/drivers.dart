import 'dart:typed_data';

import 'options.dart';

/// Native-runtime configuration for streaming recognition.
final class FluidStreamingAsrDriverConfiguration {
  FluidStreamingAsrDriverConfiguration({
    required this.model,
    required this.source,
    required this.vocabularyMinimumSimilarity,
    this.chunkSeconds,
    this.hypothesisChunkSeconds,
    this.leftContextSeconds,
    this.rightContextSeconds,
    this.minimumContextForConfirmation,
    this.confirmationThreshold,
    Iterable<FluidVocabularyEntry> vocabulary = const <FluidVocabularyEntry>[],
  }) : vocabulary = List<FluidVocabularyEntry>.unmodifiable(vocabulary);

  /// Parakeet generation.
  final FluidRecognitionModel model;

  /// Audio-origin tag.
  final FluidRecognitionSource source;

  /// Sliding-window chunk length.
  final double? chunkSeconds;

  /// Volatile hypothesis interval.
  final double? hypothesisChunkSeconds;

  /// Left context length.
  final double? leftContextSeconds;

  /// Right context length.
  final double? rightContextSeconds;

  /// Minimum confirmation context.
  final double? minimumContextForConfirmation;

  /// Confirmation threshold.
  final double? confirmationThreshold;

  /// Weighted CTC vocabulary.
  final List<FluidVocabularyEntry> vocabulary;

  /// Vocabulary similarity threshold.
  final double vocabularyMinimumSimilarity;
}

/// Provider-owned transcription timing with no Fluid SDK types.
final class FluidDriverTokenTiming {
  const FluidDriverTokenTiming({
    required this.text,
    required this.start,
    required this.end,
    required this.confidence,
  });

  /// Token surface text.
  final String text;

  /// Inclusive input offset.
  final Duration start;

  /// Exclusive input offset.
  final Duration end;

  /// Confidence estimate.
  final double confidence;
}

/// Provider-owned live transcription update.
final class FluidDriverTranscriptionUpdate {
  FluidDriverTranscriptionUpdate({
    required this.text,
    required this.promotesPreviousHypothesis,
    required this.confidence,
    Iterable<FluidDriverTokenTiming> timings = const <FluidDriverTokenTiming>[],
  }) : timings = List<FluidDriverTokenTiming>.unmodifiable(timings);

  /// New volatile hypothesis.
  final String text;

  /// Whether the preceding volatile hypothesis became committed.
  final bool promotesPreviousHypothesis;

  /// Confidence estimate.
  final double confidence;

  /// Optional token timings.
  final List<FluidDriverTokenTiming> timings;
}

/// Native driver used by one streaming ASR sink.
abstract interface class FluidStreamingAsrDriver {
  /// Native transcription updates.
  Stream<FluidDriverTranscriptionUpdate> get updates;

  /// Starts native recognition after event listeners are attached.
  Future<void> start();

  /// Feeds 16 kHz mono float32 PCM.
  Future<void> feed(Float32List samples);

  /// Flushes pending inference and returns the final volatile tail.
  Future<String> finish();

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Provider-owned result of one batch transcription.
final class FluidDriverBatchAsrResult {
  FluidDriverBatchAsrResult({
    required this.text,
    required this.confidence,
    required this.duration,
    Iterable<FluidDriverTokenTiming> timings = const <FluidDriverTokenTiming>[],
  }) : timings = List<FluidDriverTokenTiming>.unmodifiable(timings);

  /// Complete transcript.
  final String text;

  /// Overall confidence.
  final double confidence;

  /// Input duration reported by the model.
  final Duration duration;

  /// Optional token timings.
  final List<FluidDriverTokenTiming> timings;
}

/// Native driver used by one batch transcription operation.
abstract interface class FluidBatchAsrDriver {
  /// Transcribes 16 kHz mono float32 PCM.
  Future<FluidDriverBatchAsrResult> transcribe(
    Float32List samples, {
    String? language,
  });

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Provider-owned native VAD tick.
final class FluidDriverVadEvent {
  const FluidDriverVadEvent({
    required this.probability,
    this.sampleIndex,
    this.time,
  });

  /// Speech probability.
  final double probability;

  /// Sample offset reported by FluidAudio.
  final int? sampleIndex;

  /// Input offset reported by FluidAudio.
  final Duration? time;
}

/// Native driver used by one streaming VAD sink.
abstract interface class FluidVadDriver {
  /// Per-4096-sample inference ticks.
  Stream<FluidDriverVadEvent> get events;

  /// Feeds exactly 4096 samples of 16 kHz mono float32 PCM.
  Future<void> feed(Float32List samples);

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Provider-owned end-of-utterance update.
final class FluidDriverEndOfUtteranceUpdate {
  const FluidDriverEndOfUtteranceUpdate({
    required this.text,
    required this.isFinal,
  });

  /// Model transcript associated with the estimate.
  final String text;

  /// Whether FluidAudio committed an utterance boundary.
  final bool isFinal;
}

/// Native driver used by one end-of-utterance sink.
abstract interface class FluidEndOfUtteranceDriver {
  /// Partial and committed model updates.
  Stream<FluidDriverEndOfUtteranceUpdate> get updates;

  /// Feeds 16 kHz mono float32 PCM.
  Future<void> feed(Float32List samples);

  /// Flushes pending model state.
  Future<String> finish();

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Native diarization configuration.
final class FluidDiarizationDriverConfiguration {
  const FluidDiarizationDriverConfiguration({
    required this.clusteringThreshold,
    this.exactSpeakerCount,
    this.minimumSpeakers,
    this.maximumSpeakers,
  });

  /// Clustering threshold.
  final double clusteringThreshold;

  /// Exact speaker count.
  final int? exactSpeakerCount;

  /// Minimum number of speakers.
  final int? minimumSpeakers;

  /// Maximum number of speakers.
  final int? maximumSpeakers;
}

/// Provider-owned native diarization segment.
final class FluidDriverSpeakerSegment {
  const FluidDriverSpeakerSegment({
    required this.speakerId,
    required this.start,
    required this.end,
    this.confidence,
  });

  /// Stable label within this result.
  final String speakerId;

  /// Inclusive start offset.
  final Duration start;

  /// Exclusive end offset.
  final Duration end;

  /// Segment quality estimate.
  final double? confidence;
}

/// Native driver used by one batch diarization operation.
abstract interface class FluidDiarizationDriver {
  /// Diarizes 16 kHz mono float32 PCM.
  Future<List<FluidDriverSpeakerSegment>> diarize(Float32List samples);

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Native synthesis configuration.
final class FluidTtsDriverConfiguration {
  const FluidTtsDriverConfiguration({
    required this.engine,
    required this.temperature,
  });

  /// Fluid synthesis implementation.
  final FluidSynthesisEngine engine;

  /// PocketTTS sampling temperature.
  final double temperature;
}

/// Provider-owned incremental synthesis frame.
final class FluidDriverTtsChunk {
  const FluidDriverTtsChunk({required this.samples, required this.frameIndex});

  /// Owned 24 kHz mono float32 PCM.
  final Float32List samples;

  /// Native generation frame index.
  final int frameIndex;
}

/// Native driver used by one TTS source session.
abstract interface class FluidTtsDriver {
  /// Synthesizes incremental 24 kHz mono PCM.
  Stream<FluidDriverTtsChunk> synthesize({
    required String text,
    required String? voice,
    required double rate,
  });

  /// Immediately releases native resources. Must be idempotent.
  Future<void> close();
}

/// Injectable boundary between provider-neutral sessions and FluidAudio.
abstract interface class FluidAudioRuntime {
  /// Creates and loads a streaming recognizer.
  Future<FluidStreamingAsrDriver> createStreamingAsr(
    FluidStreamingAsrDriverConfiguration configuration,
  );

  /// Creates and loads a batch recognizer.
  Future<FluidBatchAsrDriver> createBatchAsr(FluidRecognitionModel model);

  /// Creates and loads a VAD stream.
  Future<FluidVadDriver> createVad({
    required double threshold,
    required Duration minimumSilence,
  });

  /// Creates and loads an end-of-utterance model.
  Future<FluidEndOfUtteranceDriver> createEndOfUtterance({
    required FluidEndOfUtteranceChunk chunk,
    required Duration debounce,
  });

  /// Creates and loads a batch diarizer.
  Future<FluidDiarizationDriver> createDiarizer(
    FluidDiarizationDriverConfiguration configuration,
  );

  /// Creates and loads a synthesis engine.
  Future<FluidTtsDriver> createTts(FluidTtsDriverConfiguration configuration);

  /// Closes every outstanding driver. Must be idempotent.
  Future<void> close();
}
