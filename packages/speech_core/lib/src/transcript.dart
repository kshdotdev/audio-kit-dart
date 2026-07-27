/// Time range within an audio session.
final class SpeechTimeRange {
  SpeechTimeRange({required this.start, required this.end}) {
    if (start.isNegative || end < start) {
      throw ArgumentError('Speech time range must satisfy 0 <= start <= end.');
    }
  }

  /// Inclusive start offset.
  final Duration start;

  /// Exclusive end offset.
  final Duration end;

  /// Range length.
  Duration get duration => end - start;
}

/// A timed recognized word.
final class SpeechWord {
  SpeechWord({
    required this.text,
    required this.range,
    this.confidence,
    this.speakerId,
  }) {
    _validateConfidence(confidence);
  }

  /// Recognized surface text.
  final String text;

  /// Position in the input audio.
  final SpeechTimeRange range;

  /// Confidence in the inclusive range 0–1.
  final double? confidence;

  /// Provider-neutral speaker label, when diarization is available.
  final String? speakerId;
}

/// Provider-neutral transcript hypothesis.
final class SpeechTranscript {
  SpeechTranscript({
    required this.text,
    Iterable<SpeechWord> words = const <SpeechWord>[],
    this.languageTag,
    this.confidence,
  }) : words = List<SpeechWord>.unmodifiable(words) {
    _validateConfidence(confidence);
  }

  /// Complete text represented by this hypothesis.
  final String text;

  /// Timed word details when supplied by the provider.
  final List<SpeechWord> words;

  /// Detected or requested BCP-47 language tag.
  final String? languageTag;

  /// Confidence in the inclusive range 0–1.
  final double? confidence;
}

/// A diarized speaker segment.
final class SpeakerSegment {
  SpeakerSegment({
    required this.speakerId,
    required this.range,
    this.confidence,
  }) {
    if (speakerId.trim().isEmpty) {
      throw ArgumentError.value(speakerId, 'speakerId', 'Must not be empty.');
    }
    _validateConfidence(confidence);
  }

  /// Stable label within one session, not a real-world identity.
  final String speakerId;

  /// Time occupied by the speaker.
  final SpeechTimeRange range;

  /// Confidence in the inclusive range 0–1.
  final double? confidence;
}

void _validateConfidence(double? confidence) {
  if (confidence != null &&
      (!confidence.isFinite || confidence < 0 || confidence > 1)) {
    throw ArgumentError.value(
      confidence,
      'confidence',
      'Must be between 0 and 1.',
    );
  }
}
