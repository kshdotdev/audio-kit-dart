import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

// Cases ported from Control Center's transcription-service tests
// (MIT © 2026 Samuel Alev). See NOTICE.

void main() {
  group('isNonSpeechArtifact', () {
    test('drops bracketed, parenthesised, and musical markup', () {
      expect(isNonSpeechArtifact('[BLANK_AUDIO]'), isTrue);
      expect(isNonSpeechArtifact('[ Silence ]'), isTrue);
      expect(isNonSpeechArtifact('(buzzing)'), isTrue);
      expect(isNonSpeechArtifact('♪♪♪'), isTrue);
      expect(isNonSpeechArtifact('...'), isTrue);
      expect(isNonSpeechArtifact('*coughs*'), isTrue);
    });

    test('keeps a window that mixes markup with real speech', () {
      expect(isNonSpeechArtifact('[ Music ] okay so'), isFalse);
      expect(isNonSpeechArtifact('(laughs) that works'), isFalse);
    });

    test('keeps ordinary speech', () {
      expect(isNonSpeechArtifact('ship it on Friday'), isFalse);
    });
  });

  group('isRepetitionHallucination', () {
    test('drops one token repeated four or more times', () {
      expect(isRepetitionHallucination('agree agree agree agree'), isTrue);
      expect(isRepetitionHallucination('Take Take Take Take Take'), isTrue);
    });

    test('drops a dominant token that carries most of the window', () {
      expect(isRepetitionHallucination('the the the the the and'), isTrue);
    });

    test('keeps short or varied windows including genuine stutters', () {
      expect(isRepetitionHallucination('is is'), isFalse);
      expect(isRepetitionHallucination('I I think so'), isFalse);
      expect(
        isRepetitionHallucination('we should ship the release today'),
        isFalse,
      );
    });

    test('keeps a window under four tokens', () {
      expect(isRepetitionHallucination('no no no'), isFalse);
    });
  });

  group('isHallucinatedBoilerplate', () {
    test('drops curated whole-window phrases', () {
      expect(isHallucinatedBoilerplate('Thanks for watching!'), isTrue);
      expect(isHallucinatedBoilerplate('Please subscribe'), isTrue);
      expect(isHallucinatedBoilerplate('See you next time.'), isTrue);
      expect(
        isHallucinatedBoilerplate('Subtitles by the Amara.org community'),
        isTrue,
      );
    });

    test('drops attribution lines and bare URLs', () {
      expect(isHallucinatedBoilerplate('Transcription by SomeVendor'), isTrue);
      expect(isHallucinatedBoilerplate('www.example.com'), isTrue);
    });

    test('keeps real speech that merely contains a boilerplate phrase', () {
      expect(
        isHallucinatedBoilerplate('thanks for watching the deploy with me'),
        isFalse,
      );
      expect(isHallucinatedBoilerplate('thank you'), isFalse);
      expect(
        isHallucinatedBoilerplate('the docs are at www.example.com now'),
        isFalse,
      );
    });

    test('keeps an empty window for the artifact filter to handle', () {
      expect(isHallucinatedBoilerplate(''), isFalse);
    });
  });

  group('isHallucinatedTranscript', () {
    test('is the union of the three filters', () {
      expect(isHallucinatedTranscript('[BLANK_AUDIO]'), isTrue);
      expect(isHallucinatedTranscript('yeah yeah yeah yeah'), isTrue);
      expect(isHallucinatedTranscript('Please subscribe'), isTrue);
      expect(isHallucinatedTranscript('let us cut the release'), isFalse);
    });
  });
}
