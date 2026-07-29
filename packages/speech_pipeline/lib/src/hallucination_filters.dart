// Derived from Control Center's `meeting_transcription_service.dart`
// (MIT © 2026 Samuel Alev): the three transcript hallucination filters, lifted
// as free functions. See NOTICE.

// Bracketed / parenthesised / musical markup models emit for non-speech.
final RegExp _nonSpeechMarkup = RegExp(r'\[[^\]]*\]|\([^)]*\)|\*[^*]*\*');
final RegExp _nonSpeechGlyphs = RegExp('[♪♫…]+');
final RegExp _wordCharacter = RegExp('[A-Za-z0-9]');

/// Whether [text] is a non-speech placeholder rather than real speech.
///
/// Recognizers render silent or noisy windows as tokens like `[BLANK_AUDIO]`,
/// `[ Silence ]`, `(buzzing)`, or `♪…♪`. Returns true when no word characters
/// remain once that markup is stripped. A window mixing a tag with real speech
/// (`[ Music ] okay so`) keeps its words and is not an artifact.
bool isNonSpeechArtifact(String text) {
  final stripped = text
      .replaceAll(_nonSpeechMarkup, ' ')
      .replaceAll(_nonSpeechGlyphs, ' ');
  return !_wordCharacter.hasMatch(stripped);
}

final RegExp _tokenSplit = RegExp('[^a-z0-9]+');

/// Whether [text] is a degenerate repetition hallucinated on low-energy or
/// echo-bleed audio — "agree agree agree agree", "the the the the the and".
///
/// Conservative by design: one distinct token must repeat at least four times,
/// or a token must occur at least five times *and* account for at least 70% of
/// the window. Short, varied windows (including genuine stutters) are kept.
bool isRepetitionHallucination(String text) {
  final tokens = text
      .toLowerCase()
      .split(_tokenSplit)
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.length < 4) {
    return false;
  }
  final counts = <String, int>{};
  var maxFrequency = 0;
  for (final token in tokens) {
    final count = (counts[token] ?? 0) + 1;
    counts[token] = count;
    if (count > maxFrequency) {
      maxFrequency = count;
    }
  }
  if (counts.length == 1) {
    return true; // One word repeated four or more times.
  }
  return maxFrequency >= 5 && maxFrequency / tokens.length >= 0.7;
}

// Canned phrases Whisper-family models hallucinate on silence, music, or the
// tail of a recording — an artifact of video-heavy training data. Matched
// against the whole normalized window only, so a real sentence that merely
// contains "thank you" is never dropped.
const Set<String> _boilerplateExact = <String>{
  'thank you for watching',
  'thanks for watching',
  'thank you for watching this video',
  'thank you so much for watching',
  'thank you very much for watching',
  'please subscribe',
  'please like and subscribe',
  'like and subscribe',
  'like comment and subscribe',
  'dont forget to subscribe',
  'see you in the next video',
  'see you next time',
  'subtitles by the amaraorg community',
  'transcription by castingwords',
};

// Credit / attribution lines ("Subtitles by …", "Transcription by …").
final RegExp _creditLine = RegExp(
  r'^(subtitle|subtitles|caption|captions|transcription|transcribed) '
  r'(by|by the) ',
);

// A lone URL or domain token with no spaces — "www.example.com".
final RegExp _urlOnly = RegExp(
  r'^(https?://|www\.)?\S+\.(com|org|net|io|tv|co)\S*$',
);

final RegExp _nonAlphanumeric = RegExp('[^a-z0-9 ]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Whether [text] is a canned hallucination rather than a real spoken line.
///
/// High precision: only whole-window matches against a curated phrase set,
/// attribution lines, or a bare URL are dropped — anything mixed with other
/// speech is kept. This complements [isNonSpeechArtifact] (markup) and
/// [isRepetitionHallucination] (degenerate loops), and matters more as
/// transducer models are added, which hallucinate different canned phrases.
bool isHallucinatedBoilerplate(String text) {
  final normalized = text
      .toLowerCase()
      .replaceAll(_nonAlphanumeric, ' ')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  if (normalized.isEmpty) {
    return false;
  }
  if (_boilerplateExact.contains(normalized)) {
    return true;
  }
  if (_creditLine.hasMatch(normalized)) {
    return true;
  }
  final raw = text.trim();
  return !raw.contains(' ') && _urlOnly.hasMatch(raw.toLowerCase());
}

/// Whether [text] should be discarded by any of the hallucination filters.
bool isHallucinatedTranscript(String text) =>
    isNonSpeechArtifact(text) ||
    isRepetitionHallucination(text) ||
    isHallucinatedBoilerplate(text);
