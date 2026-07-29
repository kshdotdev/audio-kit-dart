import 'dart:math' as math;
import 'dart:typed_data';

import 'validation.dart';

/// A speaker embedding together with the space it belongs to.
///
/// The triple ([providerId], [modelId], [dimension]) identifies that space, and
/// two embeddings are comparable only when all three agree. [providerId] and
/// [modelId] are not new vocabulary: they are the identifiers
/// `SpeechModelDescriptor` already carries — the provider ID and the embedding
/// model's own `id`.
///
/// Carrying the space on the vector is the point of the type. Two unrelated
/// models that happen to emit the same dimension would otherwise produce a
/// perfectly well-formed cosine score, clear an auto-apply threshold some
/// fraction of the time, and write the wrong human name onto a transcript. A
/// silent mislabel is worse than no label, so comparison is defined only inside
/// a space: see [speakerSimilarity] and [requireSpeakerSimilarity].
///
/// The corollary for stored profiles: changing the embedding model invalidates
/// every persisted centroid. This type makes that invalidation detectable
/// (stored space != current space) rather than silent.
///
/// [vector] is expected to be L2-normalized, which is what makes a stored
/// centroid a valid cosine reference. The contract is not enforced at
/// construction because cosine similarity is scale-invariant and providers
/// differ on whether they normalize; use [SpeakerEmbedding.normalized] when
/// handing over a raw vector.
final class SpeakerEmbedding {
  /// Creates an embedding over an already L2-normalized [vector].
  ///
  /// [vector] is copied, so later mutation of the caller's list cannot corrupt
  /// this value.
  SpeakerEmbedding({
    required this.providerId,
    required this.modelId,
    required Float32List vector,
  }) : dimension = vector.length,
       vector = Float32List.fromList(vector).asUnmodifiableView() {
    requireNonEmpty(providerId, 'providerId');
    requireNonEmpty(modelId, 'modelId');
    if (dimension == 0) {
      throw ArgumentError.value(vector, 'vector', 'Must not be empty.');
    }
    for (final value in this.vector) {
      if (!value.isFinite) {
        throw ArgumentError.value(vector, 'vector', 'Must be finite.');
      }
    }
  }

  /// Creates an embedding from a raw [vector], L2-normalizing it first.
  ///
  /// A zero vector is kept as-is: it has no direction to preserve.
  factory SpeakerEmbedding.normalized({
    required String providerId,
    required String modelId,
    required Float32List vector,
  }) => SpeakerEmbedding(
    providerId: providerId,
    modelId: modelId,
    vector: l2NormalizeVector(vector),
  );

  /// Provider that produced the vector, matching `SpeechModelDescriptor`.
  final String providerId;

  /// Embedding model that produced the vector, matching its descriptor `id`.
  final String modelId;

  /// Vector length, derived from [vector].
  final int dimension;

  /// L2-normalized vector. The returned view rejects mutation.
  final Float32List vector;

  /// Stable, persistable name for this embedding space.
  ///
  /// Storing it beside a centroid is what lets a later load detect that the
  /// embedding model changed.
  String get spaceId => '$providerId/$modelId/$dimension';

  /// Whether [other] was produced by the same provider, model, and dimension.
  bool sharesSpaceWith(SpeakerEmbedding other) =>
      providerId == other.providerId &&
      modelId == other.modelId &&
      dimension == other.dimension;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! SpeakerEmbedding || !sharesSpaceWith(other)) {
      return false;
    }
    for (var index = 0; index < dimension; index += 1) {
      if (vector[index] != other.vector[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(providerId, modelId, dimension, Object.hashAll(vector));

  @override
  String toString() => 'SpeakerEmbedding(space: $spaceId)';
}

/// Raised when two embeddings that do not share a space are compared through an
/// API where a cross-space comparison is a programming error.
final class SpeechEmbeddingSpaceMismatch implements Exception {
  /// Creates a mismatch between two embedding spaces.
  SpeechEmbeddingSpaceMismatch({required this.first, required this.second});

  /// Space of the left-hand embedding.
  final String first;

  /// Space of the right-hand embedding.
  final String second;

  @override
  String toString() =>
      'SpeechEmbeddingSpaceMismatch(first: $first, second: $second)';
}

/// Cosine similarity between [a] and [b] in the inclusive range -1 to 1, or
/// null when the two embeddings are not in the same space.
///
/// Never coerces, never truncates, never zero-pads. A cross-space comparison is
/// meaningless even when the dimensions coincide, so the answer is the absence
/// of a number rather than a plausible one. Returns 0 when either vector has
/// zero magnitude, which has no direction to compare.
double? speakerSimilarity(SpeakerEmbedding a, SpeakerEmbedding b) {
  if (!a.sharesSpaceWith(b)) {
    return null;
  }
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var index = 0; index < a.dimension; index += 1) {
    final left = a.vector[index];
    final right = b.vector[index];
    dot += left * right;
    normA += left * left;
    normB += right * right;
  }
  final denominator = math.sqrt(normA) * math.sqrt(normB);
  if (denominator == 0) {
    return 0;
  }
  return (dot / denominator).clamp(-1.0, 1.0).toDouble();
}

/// Cosine similarity between [a] and [b], throwing
/// [SpeechEmbeddingSpaceMismatch] instead of returning null.
///
/// For call sites where the two embeddings are known to come from one model and
/// a mismatch means the caller mixed up its own state.
double requireSpeakerSimilarity(SpeakerEmbedding a, SpeakerEmbedding b) {
  final similarity = speakerSimilarity(a, b);
  if (similarity == null) {
    throw SpeechEmbeddingSpaceMismatch(first: a.spaceId, second: b.spaceId);
  }
  return similarity;
}

/// L2-normalizes [vector] to unit length, returning a copy.
///
/// A zero vector is copied unchanged: it has no direction to preserve.
Float32List l2NormalizeVector(Float32List vector) {
  var sumOfSquares = 0.0;
  for (final value in vector) {
    sumOfSquares += value * value;
  }
  final norm = math.sqrt(sumOfSquares);
  if (norm == 0) {
    return Float32List.fromList(vector);
  }
  final normalized = Float32List(vector.length);
  for (var index = 0; index < vector.length; index += 1) {
    normalized[index] = vector[index] / norm;
  }
  return normalized;
}
