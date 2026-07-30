import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'descriptors.dart';
import 'provider.dart';
import 'requests.dart';
import 'validation.dart';

/// Window policy shared by the turn-completion model family.
///
/// These are not tunables: they describe the audio the classifiers were
/// trained on. A window at another rate, or with the wrong end anchored, is
/// scored as confidently as a correct one — the number comes back either way —
/// so the policy is stated once here rather than re-derived per adapter.
abstract final class TurnCompletionAudio {
  /// Sample rate every turn-completion model in this family expects.
  static const int sampleRate = 16000;

  /// Longest window a classifier sees.
  ///
  /// Providers crop the *tail* of a longer window and left-pad a shorter one,
  /// because the decision is about how the audio ended, not how it began.
  static const Duration maximumWindow = Duration(seconds: 8);

  /// Probability above which a window is treated as a completed turn when the
  /// provider has no opinion of its own.
  ///
  /// The comparison is strict: `probability > threshold` completes the turn.
  static const double defaultThreshold = 0.5;
}

/// A finite window of speech to be scored for turn completion.
///
/// The audio is a [BufferedAudioSource] rather than the [AudioSource] the other
/// batch requests accept, and the narrowing is deliberate: a scorer must hold
/// the entire window before it can produce a single number, so an open-ended
/// live source would simply never return. Buffered audio also states that the
/// caller — typically a ring buffer sitting behind a VAD — already owns the
/// samples, which is exactly the shape a turn detector has at a pause.
final class TurnCompletionRequest {
  /// Creates a request over a finite mono window.
  TurnCompletionRequest({
    required this.audio,
    this.threshold,
    this.cancellation,
    this.providerOptions,
  }) {
    if (audio.format.channels != 1) {
      throw ArgumentError.value(
        audio.format.channels,
        'audio',
        'Turn completion scores a mono window; downmix before scoring.',
      );
    }
    final threshold = this.threshold;
    if (threshold != null) {
      requireProbability(threshold, 'threshold');
    }
  }

  /// Creates a request over raw mono samples, copying [samples].
  ///
  /// The convenience form for a caller holding a plain window — a ring buffer
  /// slice — that would otherwise have to invent source identifiers to wrap it.
  factory TurnCompletionRequest.fromSamples(
    Float32List samples, {
    int sampleRate = TurnCompletionAudio.sampleRate,
    String sourceId = 'turn-completion',
    String trackId = 'audio',
    double? threshold,
    AudioCancellationToken? cancellation,
    SpeechProviderOptions? providerOptions,
  }) => TurnCompletionRequest(
    audio: BufferedAudioSource(
      format: AudioFormat(sampleRate: sampleRate, channels: 1),
      samples: samples,
      sourceId: sourceId,
      trackId: trackId,
    ),
    threshold: threshold,
    cancellation: cancellation,
    providerOptions: providerOptions,
  );

  /// Finite mono window ending at the moment being judged.
  ///
  /// Trailing silence belongs in the window: it is evidence, and cropping it
  /// out lowers the score of an utterance that has plainly finished.
  final BufferedAudioSource audio;

  /// Overrides the provider's completion threshold for this request.
  ///
  /// Null keeps the provider default, which is what the model shipped with;
  /// see [TurnCompletionAudio.defaultThreshold].
  final double? threshold;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;

  /// Length of [audio].
  Duration get windowDuration =>
      audio.format.durationForFrames(audio.samples.length);
}

/// A turn-completion verdict for one window.
final class TurnCompletionScore {
  /// Creates a score.
  TurnCompletionScore({
    required this.probability,
    required this.isComplete,
    this.threshold,
  }) {
    requireProbability(probability, 'probability');
    final threshold = this.threshold;
    if (threshold != null) {
      requireProbability(threshold, 'threshold');
    }
  }

  /// Creates a score by applying [threshold] to [probability].
  ///
  /// The comparison is strictly greater-than, matching the reference
  /// implementation; a probability exactly on the threshold leaves the turn
  /// open.
  factory TurnCompletionScore.fromThreshold({
    required double probability,
    required double threshold,
  }) => TurnCompletionScore(
    probability: probability,
    isComplete: probability > threshold,
    threshold: threshold,
  );

  /// Probability that the speaker finished their turn, in the range 0–1.
  ///
  /// Kept alongside [isComplete] because a detector needs the number, not only
  /// the verdict: it is what a diagnostic tap logs and what a caller compares
  /// against a stricter local threshold.
  final double probability;

  /// Whether the provider considers the turn complete.
  final bool isComplete;

  /// Threshold that produced [isComplete], when the provider discloses it.
  ///
  /// Null for providers whose decision boundary is not a single number.
  final double? threshold;

  @override
  String toString() =>
      'TurnCompletionScore(probability: $probability, '
      'isComplete: $isComplete, threshold: $threshold)';
}

/// Provider that judges whether a window of speech ended a conversational turn.
///
/// Silence alone is a poor turn boundary: people pause mid-sentence, and a
/// timeout long enough to avoid interrupting them is long enough to feel
/// broken. A turn-completion model reads the prosody of the trailing audio and
/// answers the question silence cannot.
///
/// This is a seam, not a pipeline. It exists so a detector — which owns the
/// VAD, the ring buffer, and the turn bookkeeping — can reach a model living
/// in a provider package without the two packages depending on each other.
/// Providers declare [SpeechCapability.turnCompletion].
abstract interface class TurnCompletionScorer implements SpeechProvider {
  /// Scores one finite window.
  ///
  /// Implementations resample to [TurnCompletionAudio.sampleRate] when needed
  /// and crop or pad to [TurnCompletionAudio.maximumWindow]. Failures are
  /// reported as `SpeechFailure`; a scorer never returns a made-up probability
  /// to keep a caller running, because an invented 0.5 is indistinguishable
  /// from a genuinely uncertain model.
  Future<TurnCompletionScore> scoreTurnCompletion(
    TurnCompletionRequest request,
  );
}
