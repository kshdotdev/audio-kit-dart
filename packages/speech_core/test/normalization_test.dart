import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeTranscriptPreservingWords', () {
    test('rewrites the text and carries the timings across', () async {
      final normalizer = _FakeNormalizer();
      final transcript = _transcript();
      final normalized = await normalizeTranscriptPreservingWords(
        normalizer,
        transcript,
        languageTag: 'en-US',
      );

      expect(normalized.text, 'that is \$25');
      expect(normalizer.languageTags, <String?>['en-US']);
      expect(
        normalized.words.map((word) => word.text),
        orderedEquals(<String>['that', 'is', 'twenty', 'five', 'dollars']),
      );
      expect(normalized.words.first.range.start, Duration.zero);
      expect(
        normalized.words.last.range.end,
        transcript.words.last.range.end,
        reason: 'the span of the utterance is unchanged',
      );
      expect(normalized.languageTag, transcript.languageTag);
      expect(normalized.confidence, transcript.confidence);
    });

    test('returns the same transcript when normalization is a no-op', () async {
      final normalizer = _FakeNormalizer(identity: true);
      final transcript = _transcript();

      expect(
        await normalizeTranscriptPreservingWords(normalizer, transcript),
        same(transcript),
      );
    });

    test('is idempotent on already-normalized input', () async {
      final normalizer = _FakeNormalizer();
      final once = await normalizeTranscriptPreservingWords(
        normalizer,
        _transcript(),
      );
      final twice = await normalizeTranscriptPreservingWords(normalizer, once);

      expect(twice.text, once.text);
      expect(twice, same(once));
    });

    test('an empty word list stays empty', () async {
      final normalized = await normalizeTranscriptPreservingWords(
        _FakeNormalizer(),
        SpeechTranscript(text: 'that is twenty five dollars'),
      );

      expect(normalized.text, 'that is \$25');
      expect(normalized.words, isEmpty);
    });
  });

  group('TranscriptInverseTextNormalizer', () {
    test('refines the string normalizer rather than replacing it', () async {
      final normalizer = _FakeTranscriptNormalizer();

      expect(normalizer, isA<InverseTextNormalizer>());
      expect(await normalizer.normalize('twenty five dollars'), '\$25');
      final normalized = await normalizer.normalizeTranscript(_transcript());
      expect(normalized.text, 'that is \$25');
      expect(normalized.words, hasLength(5));
    });

    test('a string-only normalizer is still a valid provider', () {
      expect(_FakeNormalizer(), isA<InverseTextNormalizer>());
      expect(_FakeNormalizer(), isNot(isA<TranscriptInverseTextNormalizer>()));
    });
  });
}

SpeechTranscript _transcript() {
  const words = <String>['that', 'is', 'twenty', 'five', 'dollars'];
  return SpeechTranscript(
    text: 'that is twenty five dollars',
    words: <SpeechWord>[
      for (var index = 0; index < words.length; index += 1)
        SpeechWord(
          text: words[index],
          range: SpeechTimeRange(
            start: Duration(milliseconds: index * 300),
            end: Duration(milliseconds: (index * 300) + 250),
          ),
        ),
    ],
    languageTag: 'en-US',
    confidence: 0.9,
  );
}

/// Rewrites the one spoken-form span the tests care about.
base class _FakeNormalizer extends IdempotentSpeechProvider
    implements InverseTextNormalizer {
  _FakeNormalizer({this.identity = false});

  /// Whether normalization returns its input unchanged.
  final bool identity;

  final List<String?> languageTags = <String?>[];

  @override
  SpeechProviderDescriptor get descriptor => SpeechProviderDescriptor(
    id: 'fake',
    displayName: 'Fake',
    capabilities: const <SpeechCapability>{
      SpeechCapability.inverseTextNormalization,
    },
  );

  @override
  Future<String> normalize(String text, {String? languageTag}) async {
    languageTags.add(languageTag);
    if (identity) {
      return text;
    }
    return text.replaceAll('twenty five dollars', r'$25');
  }

  @override
  Future<List<String>> normalizeSentences(
    Iterable<String> sentences, {
    String? languageTag,
  }) async => <String>[
    for (final sentence in sentences)
      await normalize(sentence, languageTag: languageTag),
  ];

  @override
  Future<void> onClose() async {}
}

final class _FakeTranscriptNormalizer extends _FakeNormalizer
    implements TranscriptInverseTextNormalizer {
  @override
  Future<SpeechTranscript> normalizeTranscript(
    SpeechTranscript transcript, {
    String? languageTag,
  }) => normalizeTranscriptPreservingWords(
    this,
    transcript,
    languageTag: languageTag,
  );
}
