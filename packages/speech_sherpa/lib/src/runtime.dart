import 'dart:typed_data';

import 'models.dart';
import 'options.dart';

/// Native-runtime configuration for batch recognition.
final class SherpaBatchAsrConfiguration {
  /// Creates a batch recognizer configuration.
  const SherpaBatchAsrConfiguration({
    required this.paths,
    required this.numThreads,
    required this.decodingMethod,
    required this.provider,
    this.languageCode,
  });

  /// Resolved model files.
  final SherpaRecognitionModelPaths paths;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// sherpa decoding method.
  final String decodingMethod;

  /// ONNX Runtime execution provider.
  final String provider;

  /// Bare language subtag for Whisper, or null for auto-detection.
  final String? languageCode;
}

/// Native-runtime configuration for streaming recognition.
final class SherpaStreamingAsrConfiguration {
  /// Creates a streaming recognizer configuration.
  const SherpaStreamingAsrConfiguration({
    required this.paths,
    required this.numThreads,
    required this.decodingMethod,
    required this.provider,
    required this.enableEndpoint,
    required this.silenceBeforeSpeechSeconds,
    required this.silenceAfterSpeechSeconds,
    required this.maximumUtteranceSeconds,
  });

  /// Resolved streaming model files.
  final SherpaRecognitionModelPaths paths;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// sherpa decoding method.
  final String decodingMethod;

  /// ONNX Runtime execution provider.
  final String provider;

  /// Whether sherpa's rule-based endpointer segments the stream.
  final bool enableEndpoint;

  /// sherpa endpointing rule 1, in seconds.
  final double silenceBeforeSpeechSeconds;

  /// sherpa endpointing rule 2, in seconds.
  final double silenceAfterSpeechSeconds;

  /// sherpa endpointing rule 3, in seconds.
  final double maximumUtteranceSeconds;
}

/// Native-runtime configuration for diarization.
final class SherpaDiarizationConfiguration {
  /// Creates a diarizer configuration.
  const SherpaDiarizationConfiguration({
    required this.paths,
    required this.clusteringThreshold,
    required this.minimumDurationOn,
    required this.minimumDurationOff,
    required this.numThreads,
    required this.maximumEmbeddingSamples,
    this.exactSpeakerCount,
  });

  /// Resolved segmentation and embedding models.
  final SherpaDiarizationModelPaths paths;

  /// Cosine threshold used when the speaker count is inferred.
  final double clusteringThreshold;

  /// Shortest retained speech span, in seconds.
  final double minimumDurationOn;

  /// Shortest separating silence, in seconds.
  final double minimumDurationOff;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// Per-speaker audio budget for representative embeddings.
  final int maximumEmbeddingSamples;

  /// Exact speaker count, or null to infer it from the audio.
  final int? exactSpeakerCount;
}

/// Native-runtime configuration for voice-activity detection.
final class SherpaVadConfiguration {
  /// Creates a VAD configuration.
  const SherpaVadConfiguration({
    required this.modelPath,
    required this.threshold,
    required this.minimumSilenceSeconds,
    required this.minimumSpeechSeconds,
    required this.maximumSpeechSeconds,
    required this.windowSize,
    required this.numThreads,
    required this.bufferSizeSeconds,
  });

  /// Absolute Silero VAD model path.
  final String modelPath;

  /// Speech probability threshold.
  final double threshold;

  /// Silence required before speech ends, in seconds.
  final double minimumSilenceSeconds;

  /// Speech required before a start is reported, in seconds.
  final double minimumSpeechSeconds;

  /// Longest speech span before a forced cut, in seconds.
  final double maximumSpeechSeconds;

  /// Silero window size in samples.
  final int windowSize;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// Detector ring-buffer capacity, in seconds.
  final double bufferSizeSeconds;
}

/// Provider-owned recognition result with no sherpa types.
final class SherpaDriverTranscript {
  /// Creates a driver transcript.
  const SherpaDriverTranscript({
    required this.text,
    this.languageCode,
    this.tokens = const <String>[],
    this.timestamps = const <double>[],
  });

  /// Recognized text.
  final String text;

  /// Detected language subtag, when the model reports one.
  final String? languageCode;

  /// Token surface strings.
  final List<String> tokens;

  /// Token start offsets in seconds, parallel to [tokens].
  final List<double> timestamps;
}

/// The decoder state after one incremental streaming step.
final class SherpaDriverStreamingUpdate {
  /// Creates a streaming update.
  const SherpaDriverStreamingUpdate({
    required this.transcript,
    required this.isEndpoint,
  });

  /// An empty update, for a step that produced nothing.
  static const SherpaDriverStreamingUpdate empty = SherpaDriverStreamingUpdate(
    transcript: SherpaDriverTranscript(text: ''),
    isEndpoint: false,
  );

  /// Hypothesis for the segment currently being decoded.
  ///
  /// Replaceable until [isEndpoint] reports the segment closed: sherpa revises
  /// earlier words as later audio arrives.
  final SherpaDriverTranscript transcript;

  /// Whether sherpa's rule-based endpointer closed the segment on this step.
  ///
  /// A timer over decoder state, not a semantic end-of-utterance decision.
  final bool isEndpoint;
}

/// Provider-owned diarization span with its speaker vector.
final class SherpaDriverSpeakerSpan {
  /// Creates a diarization span.
  const SherpaDriverSpeakerSpan({
    required this.speaker,
    required this.startSeconds,
    required this.endSeconds,
    this.embedding,
  });

  /// Cluster index assigned by sherpa.
  final int speaker;

  /// Inclusive start offset in seconds.
  final double startSeconds;

  /// Exclusive end offset in seconds.
  final double endSeconds;

  /// Representative vector for [speaker], when the extractor produced one.
  ///
  /// Every span of one cluster carries the same vector: the embedding
  /// identifies the speaker, not the span.
  final Float32List? embedding;
}

/// Provider-owned speech span emitted by the VAD driver.
final class SherpaDriverSpeechSpan {
  /// Creates a VAD speech span.
  const SherpaDriverSpeechSpan({
    required this.startSample,
    required this.sampleCount,
  });

  /// Start offset in samples from the beginning of the session.
  final int startSample;

  /// Length of the detected span in samples.
  final int sampleCount;
}

/// A loaded batch recognizer.
abstract interface class SherpaBatchAsrDriver {
  /// Decodes complete 16 kHz mono audio.
  Future<SherpaDriverTranscript> transcribe(Float32List samples);

  /// Releases the recognizer and its worker.
  Future<void> close();
}

/// A live streaming recognizer holding one open decode stream.
///
/// Unlike [SherpaBatchAsrDriver], every call mutates state that the next call
/// depends on, so calls must not overlap: the session serializes them.
abstract interface class SherpaStreamingAsrDriver {
  /// Feeds 16 kHz mono samples and decodes every step they made ready.
  Future<SherpaDriverStreamingUpdate> accept(Float32List samples);

  /// Discards the decoded segment, keeping the recognizer and its features.
  ///
  /// Called after a confirmed segment so the next hypothesis starts empty.
  Future<void> reset();

  /// Marks input finished, drains the decoder, and returns the last
  /// hypothesis.
  Future<SherpaDriverStreamingUpdate> finish();

  /// Releases the recognizer, its stream, and its worker.
  Future<void> close();
}

/// A loaded diarizer.
abstract interface class SherpaDiarizationDriver {
  /// Clusters speakers over complete 16 kHz mono audio.
  Future<List<SherpaDriverSpeakerSpan>> diarize(Float32List samples);

  /// Releases the diarizer.
  Future<void> close();
}

/// A live voice-activity detector.
abstract interface class SherpaVadDriver {
  /// Feeds 16 kHz mono samples and returns any completed speech spans.
  Future<List<SherpaDriverSpeechSpan>> accept(Float32List samples);

  /// Flushes buffered audio and returns any remaining spans.
  Future<List<SherpaDriverSpeechSpan>> flush();

  /// Releases the detector.
  Future<void> close();
}

/// The seam between this adapter and the sherpa-onnx native library.
///
/// Production uses `SherpaNativeRuntime`; tests inject a fake so provider
/// behavior is exercised without ONNX Runtime, model files, or isolates.
abstract interface class SherpaRuntime {
  /// Loads a recognizer described by [configuration].
  Future<SherpaBatchAsrDriver> createBatchAsr(
    SherpaBatchAsrConfiguration configuration,
  );

  /// Loads a streaming recognizer described by [configuration].
  Future<SherpaStreamingAsrDriver> createStreamingAsr(
    SherpaStreamingAsrConfiguration configuration,
  );

  /// Loads a diarizer described by [configuration].
  Future<SherpaDiarizationDriver> createDiarizer(
    SherpaDiarizationConfiguration configuration,
  );

  /// Loads a voice-activity detector described by [configuration].
  Future<SherpaVadDriver> createVad(SherpaVadConfiguration configuration);

  /// Releases every driver this runtime created.
  Future<void> close();
}

/// Converts option objects into driver configurations.
SherpaBatchAsrConfiguration buildBatchAsrConfiguration({
  required SherpaRecognitionModelPaths paths,
  required SherpaRecognitionOptions options,
  String? languageCode,
}) => SherpaBatchAsrConfiguration(
  paths: paths,
  numThreads: options.numThreads,
  decodingMethod: options.decodingMethod,
  provider: options.provider,
  languageCode: paths.model.kind == SherpaRecognitionModelKind.whisper
      ? languageCode
      : null,
);

/// Converts streaming options into a driver configuration.
SherpaStreamingAsrConfiguration buildStreamingAsrConfiguration({
  required SherpaRecognitionModelPaths paths,
  required SherpaStreamingRecognitionOptions options,
}) => SherpaStreamingAsrConfiguration(
  paths: paths,
  numThreads: options.numThreads,
  decodingMethod: options.decodingMethod,
  provider: options.provider,
  enableEndpoint: options.enableEndpoint,
  silenceBeforeSpeechSeconds: _seconds(options.silenceBeforeSpeech),
  silenceAfterSpeechSeconds: _seconds(options.silenceAfterSpeech),
  maximumUtteranceSeconds: _seconds(options.maximumUtterance),
);

double _seconds(Duration value) =>
    value.inMicroseconds / Duration.microsecondsPerSecond;

/// Converts diarization options into a driver configuration.
SherpaDiarizationConfiguration buildDiarizationConfiguration({
  required SherpaDiarizationModelPaths paths,
  required SherpaDiarizationOptions options,
  int? exactSpeakerCount,
}) => SherpaDiarizationConfiguration(
  paths: paths,
  clusteringThreshold: options.clusteringThreshold,
  minimumDurationOn:
      options.minimumDurationOn.inMicroseconds / Duration.microsecondsPerSecond,
  minimumDurationOff:
      options.minimumDurationOff.inMicroseconds /
      Duration.microsecondsPerSecond,
  numThreads: options.numThreads,
  maximumEmbeddingSamples:
      (options.maximumEmbeddingAudio.inMicroseconds * 16000) ~/
      Duration.microsecondsPerSecond,
  exactSpeakerCount: exactSpeakerCount,
);
