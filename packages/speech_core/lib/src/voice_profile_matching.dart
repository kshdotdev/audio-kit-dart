// Ported from Control Center's
// `packages/cc_domain/lib/features/meetings/domain/services/
// voice_profile_matching.dart`, MIT (c) 2026 Samuel Alev
// (github.com/SamuelAlev/control-center). See the NOTICE file at the root of
// this package for the retained copyright notice.
//
// Changes from the original: the functions take [SpeakerEmbedding] instead of
// `List<double>`, so a cross-space comparison returns null rather than a
// plausible number; the thresholds are caller-supplied [VoiceMatchThresholds]
// instead of top-level constants baked into the algorithm; and the per-profile
// `Float32List.fromList` allocation is gone because the vector is stored once.

import 'dart:typed_data';

import 'embedding.dart';
import 'validation.dart';

/// A saved voiceprint: a display name plus the running centroid of every
/// embedding enrolled into it.
final class VoiceProfile {
  /// Creates a voice profile.
  VoiceProfile({
    required this.id,
    required this.displayName,
    required this.centroid,
    required this.sampleCount,
  }) {
    requireNonEmpty(id, 'id');
    requireNonEmpty(displayName, 'displayName');
    if (sampleCount < 0) {
      throw ArgumentError.value(
        sampleCount,
        'sampleCount',
        'Must not be negative.',
      );
    }
  }

  /// Stable profile ID.
  final String id;

  /// Human-readable name applied to a matched speaker.
  final String displayName;

  /// Running centroid of the enrolled embeddings, L2-normalized.
  final SpeakerEmbedding centroid;

  /// Number of embeddings blended into [centroid].
  ///
  /// Zero means nothing has been enrolled yet, so the next blend starts fresh.
  final int sampleCount;
}

/// A candidate match between a speaker embedding and a saved [VoiceProfile].
final class VoiceMatch {
  /// Creates a match.
  const VoiceMatch({required this.profile, required this.similarity});

  /// The matched profile.
  final VoiceProfile profile;

  /// Cosine similarity between the query and [VoiceProfile.centroid], -1 to 1.
  final double similarity;

  /// Whether this match is confident enough to apply its name without asking.
  bool isAutoApply(VoiceMatchThresholds thresholds) =>
      similarity >= thresholds.autoApply;
}

/// Cosine-similarity thresholds for voice-profile matching.
///
/// These are model-space parameters, not universal constants. A threshold tuned
/// against one embedding model says nothing about another, so there is no
/// default: callers pass the pair that was measured for the space their
/// embeddings come from, and [provenance] records how the numbers were
/// obtained.
final class VoiceMatchThresholds {
  /// Creates a threshold pair.
  ///
  /// [autoApply] must be at least [suggest]; both must lie in the cosine range
  /// -1 to 1.
  const VoiceMatchThresholds({
    required this.autoApply,
    required this.suggest,
    required this.provenance,
  }) : assert(autoApply >= suggest, 'autoApply must not be below suggest.'),
       assert(
         suggest >= -1 && autoApply <= 1,
         'Thresholds must lie in the cosine range -1 to 1.',
       ),
       assert(provenance.length > 0, 'provenance must not be empty.');

  /// Similarity at or above which a profile's name is applied automatically.
  final double autoApply;

  /// Similarity at or above which a profile is a plausible rename suggestion.
  final double suggest;

  /// How these numbers were obtained, for the paper trail a re-tune needs.
  final String provenance;

  /// Thresholds tuned against WeSpeaker en/voxceleb ResNet34-LM as used by
  /// Control Center, where auto-apply (0.70) is set stricter than the
  /// FastClustering boundary (0.50) that the suggest floor sits on.
  ///
  /// Auto-apply is deliberately the stricter of the two: a silent mislabel
  /// ("that wasn't me") is worse than leaving a speaker as "Person N".
  ///
  /// These numbers have no measured provenance in any other embedding space —
  /// notably not FluidAudio's 256-d VBx output. Using them there is a guess.
  /// Re-tuning is a caller obligation: run a same-speaker/different-speaker
  /// sweep on the target model's vectors and pass a new [VoiceMatchThresholds]
  /// with its own [provenance]. Nothing in this library will detect that the
  /// pair is wrong for the space it is applied to.
  static const VoiceMatchThresholds wespeakerVoxceleb = VoiceMatchThresholds(
    autoApply: 0.70,
    suggest: 0.50,
    provenance: 'Control Center, voice_profile_matching.dart:7-19',
  );

  @override
  String toString() =>
      'VoiceMatchThresholds(autoApply: $autoApply, suggest: $suggest, '
      'provenance: $provenance)';
}

/// The best profile match for [query] among [profiles] whose similarity is at
/// least [VoiceMatchThresholds.suggest], or null when nothing is plausible.
///
/// Profiles whose centroid is in a different embedding space than [query] are
/// skipped rather than compared, so a stale profile saved under a previous
/// model can never win.
VoiceMatch? bestVoiceMatch(
  SpeakerEmbedding query,
  List<VoiceProfile> profiles, {
  required VoiceMatchThresholds thresholds,
}) {
  if (profiles.isEmpty) {
    return null;
  }
  VoiceProfile? best;
  var bestSimilarity = thresholds.suggest;
  for (final profile in profiles) {
    final similarity = speakerSimilarity(query, profile.centroid);
    if (similarity != null && similarity >= bestSimilarity) {
      bestSimilarity = similarity;
      best = profile;
    }
  }
  return best == null
      ? null
      : VoiceMatch(profile: best, similarity: bestSimilarity);
}

/// Ordered candidate names to suggest for a still-unnamed speaker: every
/// profile whose similarity to [query] clears [VoiceMatchThresholds.suggest],
/// most-similar first, de-duplicated by display name and capped at [max].
///
/// Empty when nothing is plausible. Cross-space profiles are skipped.
List<String> suggestedNames(
  SpeakerEmbedding query,
  List<VoiceProfile> profiles, {
  required VoiceMatchThresholds thresholds,
  int max = 3,
}) {
  if (profiles.isEmpty || max <= 0) {
    return const <String>[];
  }
  final scored = <({String name, double similarity})>[];
  for (final profile in profiles) {
    final similarity = speakerSimilarity(query, profile.centroid);
    if (similarity != null && similarity >= thresholds.suggest) {
      scored.add((name: profile.displayName, similarity: similarity));
    }
  }
  scored.sort((a, b) => b.similarity.compareTo(a.similarity));
  final names = <String>[];
  for (final entry in scored) {
    if (!names.contains(entry.name)) {
      names.add(entry.name);
    }
    if (names.length >= max) {
      break;
    }
  }
  return names;
}

/// Blends [sample] into [profile]'s running centroid via a sample-count-
/// weighted mean, re-normalized to unit length so the result stays a valid
/// cosine reference:
/// `new = normalize((centroid * count + sample) / (count + 1))`.
///
/// Returns null when [sample] is not in the same space as the centroid. Control
/// Center fell back to a fresh start on a length mismatch; that is not safe
/// here, because a fresh start would silently discard an enrolled identity the
/// caller may still want, and same dimension is not same space. A null tells
/// the caller the profile and the sample do not belong together.
///
/// A profile with no samples yet ([VoiceProfile.sampleCount] of 0) blends to
/// the normalized [sample] — a genuine fresh start.
SpeakerEmbedding? blendCentroid(VoiceProfile profile, SpeakerEmbedding sample) {
  final centroid = profile.centroid;
  if (!centroid.sharesSpaceWith(sample)) {
    return null;
  }
  if (profile.sampleCount <= 0) {
    return SpeakerEmbedding.normalized(
      providerId: sample.providerId,
      modelId: sample.modelId,
      vector: sample.vector,
    );
  }
  final count = profile.sampleCount.toDouble();
  final blended = Float32List(centroid.dimension);
  for (var index = 0; index < blended.length; index += 1) {
    blended[index] =
        (centroid.vector[index] * count + sample.vector[index]) / (count + 1);
  }
  return SpeakerEmbedding.normalized(
    providerId: sample.providerId,
    modelId: sample.modelId,
    vector: blended,
  );
}

/// Backs [sample] out of [profile]'s running centroid, the inverse of
/// [blendCentroid]: `old = normalize((centroid * count - sample) / (count - 1))`
/// for the remaining `count - 1` samples. Used when a speaker is renamed away
/// from a profile their voiceprint was enrolled into, so the corrected name does
/// not leave a stale sample behind.
///
/// Returns null when nothing meaningful remains, which means *delete the
/// profile* rather than keep an empty husk — either [sample] was the profile's
/// only one ([VoiceProfile.sampleCount] of 1 or less), or it is not in the
/// centroid's space and the profile cannot be trusted to describe it.
///
/// Re-normalization is lossy, because each blend dropped the pre-normalization
/// magnitude, so this is an approximate inverse. For the common one-sample
/// profile it is exact: it deletes.
SpeakerEmbedding? unblendCentroid(
  VoiceProfile profile,
  SpeakerEmbedding sample,
) {
  final centroid = profile.centroid;
  if (profile.sampleCount <= 1 || !centroid.sharesSpaceWith(sample)) {
    return null;
  }
  final count = profile.sampleCount.toDouble();
  final remaining = Float32List(centroid.dimension);
  for (var index = 0; index < remaining.length; index += 1) {
    remaining[index] =
        (centroid.vector[index] * count - sample.vector[index]) / (count - 1);
  }
  return SpeakerEmbedding.normalized(
    providerId: centroid.providerId,
    modelId: centroid.modelId,
    vector: remaining,
  );
}
