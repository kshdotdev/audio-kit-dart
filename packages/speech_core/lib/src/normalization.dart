import 'provider.dart';
import 'transcript.dart';
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

/// Provider that can normalize a transcript without discarding its timings.
///
/// [InverseTextNormalizer.normalize] takes a string and returns a string, so a
/// caller holding a [SpeechTranscript] has to choose between written-form text
/// and word timings. That choice is a false one — it is the same utterance —
/// and it breaks every downstream consumer that needs both: sentence
/// segmentation, diarization alignment, seeking back into the audio.
///
/// A refinement of [InverseTextNormalizer] rather than a member on it, so
/// providers that only rewrite strings stay valid implementations and a caller
/// can test for the stronger contract with `is`.
abstract interface class TranscriptInverseTextNormalizer
    implements InverseTextNormalizer {
  /// Normalizes [transcript]'s text while keeping its word timings coherent.
  ///
  /// The contract is about the timeline, not the surface forms: the returned
  /// words stay inside the input's span, stay ordered, and are never
  /// re-timed by guesswork. Implementations that cannot map a rewritten span
  /// back onto words carry the original words through unchanged — a stale
  /// spoken-form word with a true timestamp is useful, an invented timestamp
  /// is not.
  ///
  /// Idempotent on already-normalized input, like [normalize].
  Future<SpeechTranscript> normalizeTranscript(
    SpeechTranscript transcript, {
    String? languageTag,
  });
}

/// Normalizes [transcript]'s text through [normalizer], carrying its words
/// across unchanged.
///
/// The baseline behavior of [TranscriptInverseTextNormalizer], available to
/// every provider that can only rewrite strings: text becomes written form,
/// [SpeechTranscript.words] keeps the timings the recognizer actually
/// produced, and the transcript is returned unchanged — the same instance —
/// when normalization is a no-op.
///
/// The limitation is worth stating plainly, because it is the reason the
/// interface exists as a seat a provider can implement better: word surfaces
/// are still spoken-form, so the concatenated words no longer reproduce
/// [SpeechTranscript.text]. Alignment survives; word-level text does not.
Future<SpeechTranscript> normalizeTranscriptPreservingWords(
  InverseTextNormalizer normalizer,
  SpeechTranscript transcript, {
  String? languageTag,
}) async {
  final normalized = await normalizer.normalize(
    transcript.text,
    languageTag: languageTag,
  );
  if (normalized == transcript.text) {
    return transcript;
  }
  return SpeechTranscript(
    text: normalized,
    words: transcript.words,
    languageTag: transcript.languageTag,
    confidence: transcript.confidence,
  );
}
