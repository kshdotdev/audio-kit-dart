import 'provider.dart';
import 'validation.dart';

/// A single spoken-to-written replacement for a user-extensible ITN grammar.
final class InverseTextNormalizationRule {
  /// Creates a rule replacing [spoken] with [written].
  InverseTextNormalizationRule({required this.spoken, required this.written}) {
    requireNonEmpty(spoken, 'spoken');
  }

  /// Spoken form the provider should recognize, such as `ectos`.
  final String spoken;

  /// Written form to substitute. Empty removes the spoken form entirely.
  final String written;

  @override
  String toString() =>
      'InverseTextNormalizationRule(spoken: $spoken, written: $written)';
}

/// Provider capable of inverse text normalization.
///
/// ITN converts spoken-form recognition output to written form, which is the
/// difference between a transcript that reads `twenty five dollars` and one
/// that reads `$25`. Providers that declare
/// `SpeechCapability.inverseTextNormalization` implement this; every other
/// adapter simply does not, and composition degrades to the raw transcript
/// text rather than to a missing import.
abstract interface class InverseTextNormalizer implements SpeechProvider {
  /// Converts spoken-form [text] to written form.
  ///
  /// Idempotent on already-normalized input, so it is safe to apply to a
  /// transcript of unknown provenance. [languageTag] is a BCP-47 tag; when
  /// null the provider decides.
  Future<String> normalize(String text, {String? languageTag});

  /// Batch form, so providers may exploit sentence context.
  ///
  /// Returns one result per input, in order.
  Future<List<String>> normalizeSentences(
    Iterable<String> sentences, {
    String? languageTag,
  });
}

/// Provider whose ITN grammar accepts caller-supplied rules.
///
/// Optional even among providers that declare the capability: normalization
/// works without it, and a provider with a fixed grammar implements only
/// [InverseTextNormalizer].
abstract interface class CustomizableInverseTextNormalizer
    implements InverseTextNormalizer {
  /// Registers [rule] for subsequent [normalize] calls.
  Future<void> addRule(InverseTextNormalizationRule rule);
}
