import 'package:test/test.dart';
import 'package:voice_core/voice_core.dart';

void main() {
  group('IncrementalSentenceSegmenter', () {
    test('segments punctuation across arbitrary chunks', () {
      final segmenter = IncrementalSentenceSegmenter();

      expect(segmenter.add('Hello wor'), isEmpty);
      expect(segmenter.add('ld. How are'), ['Hello world.']);
      expect(segmenter.add(' you? Fine!'), ['How are you?', 'Fine!']);
      expect(segmenter.flush(), isEmpty);
    });

    test('preserves abbreviations and decimal numbers', () {
      final segmenter = IncrementalSentenceSegmenter();

      expect(segmenter.add('Dr. Smith measured 3.14 meters. Next.'), [
        'Dr. Smith measured 3.14 meters.',
        'Next.',
      ]);
    });

    test('includes closing quotes in sentence', () {
      final segmenter = IncrementalSentenceSegmenter();

      expect(segmenter.add('She said "go now." Then'), ['She said "go now."']);
      expect(segmenter.flush(), ['Then']);
    });

    test('forces a word-boundary split for unpunctuated text', () {
      final segmenter = IncrementalSentenceSegmenter(maximumCharacters: 20);

      expect(segmenter.add('one two three four five six'), [
        'one two three four',
      ]);
      expect(segmenter.flush(), ['five six']);
    });

    test('reset discards pending text', () {
      final segmenter = IncrementalSentenceSegmenter();
      expect(segmenter.add('discard me'), isEmpty);

      segmenter.reset();

      expect(segmenter.pending, isEmpty);
      expect(segmenter.flush(), isEmpty);
    });
  });
}
