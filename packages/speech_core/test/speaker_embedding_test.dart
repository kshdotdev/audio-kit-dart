import 'dart:typed_data';

import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

SpeakerEmbedding _embedding(
  List<double> vector, {
  String providerId = 'fluidaudio',
  String modelId = 'vbx-diarization',
}) => SpeakerEmbedding(
  providerId: providerId,
  modelId: modelId,
  vector: Float32List.fromList(vector),
);

void main() {
  group('SpeakerEmbedding', () {
    test('derives its dimension and space from the vector and IDs', () {
      final embedding = _embedding(const <double>[1, 0, 0]);

      expect(embedding.dimension, 3);
      expect(embedding.spaceId, 'fluidaudio/vbx-diarization/3');
    });

    test('rejects an empty vector, blank IDs, and non-finite values', () {
      expect(() => _embedding(const <double>[]), throwsArgumentError);
      expect(
        () => _embedding(const <double>[1], providerId: ' '),
        throwsA(isArgumentError),
      );
      expect(
        () => _embedding(const <double>[1], modelId: ''),
        throwsArgumentError,
      );
      expect(
        () => _embedding(const <double>[1, double.nan]),
        throwsArgumentError,
      );
      expect(
        () => _embedding(const <double>[1, double.infinity]),
        throwsArgumentError,
      );
    });

    test('copies the vector and rejects mutation of the stored view', () {
      final source = Float32List.fromList(const <double>[1, 0]);
      final embedding = SpeakerEmbedding(
        providerId: 'p',
        modelId: 'm',
        vector: source,
      );

      source[0] = 99;

      expect(embedding.vector[0], 1);
      expect(() => embedding.vector[0] = 5, throwsUnsupportedError);
    });

    test('is equal only within a space and by value', () {
      final a = _embedding(const <double>[1, 0]);

      expect(a, _embedding(const <double>[1, 0]));
      expect(a.hashCode, _embedding(const <double>[1, 0]).hashCode);
      expect(a, isNot(_embedding(const <double>[0, 1])));
      expect(a, isNot(_embedding(const <double>[1, 0], providerId: 'sherpa')));
      expect(a, isNot(_embedding(const <double>[1, 0], modelId: 'wespeaker')));
      expect(a, isNot(_embedding(const <double>[1, 0, 0])));
    });

    test('sharesSpaceWith requires provider, model, and dimension', () {
      final a = _embedding(const <double>[1, 0]);

      expect(a.sharesSpaceWith(_embedding(const <double>[0, 1])), isTrue);
      expect(
        a.sharesSpaceWith(_embedding(const <double>[1, 0], modelId: 'other')),
        isFalse,
      );
      expect(a.sharesSpaceWith(_embedding(const <double>[1, 0, 0])), isFalse);
    });

    test('normalized scales to unit length and keeps a zero vector', () {
      final unit = SpeakerEmbedding.normalized(
        providerId: 'p',
        modelId: 'm',
        vector: Float32List.fromList(const <double>[3, 4, 0]),
      );

      expect(unit.vector[0], closeTo(0.6, 1e-6));
      expect(unit.vector[1], closeTo(0.8, 1e-6));
      expect(unit.vector[2], closeTo(0, 1e-6));

      final zero = SpeakerEmbedding.normalized(
        providerId: 'p',
        modelId: 'm',
        vector: Float32List.fromList(const <double>[0, 0]),
      );

      expect(zero.vector, everyElement(0));
    });
  });

  group('speakerSimilarity', () {
    test('scores parallel, orthogonal, and opposed vectors', () {
      expect(
        speakerSimilarity(
          _embedding(const <double>[1, 0]),
          _embedding(const <double>[1, 0]),
        ),
        closeTo(1, 1e-9),
      );
      expect(
        speakerSimilarity(
          _embedding(const <double>[1, 0]),
          _embedding(const <double>[0, 1]),
        ),
        closeTo(0, 1e-9),
      );
      expect(
        speakerSimilarity(
          _embedding(const <double>[1, 0]),
          _embedding(const <double>[-1, 0]),
        ),
        closeTo(-1, 1e-9),
      );
    });

    test('is scale-invariant and stays inside the cosine range', () {
      final similarity = speakerSimilarity(
        _embedding(const <double>[3, 0]),
        _embedding(const <double>[0.5, 0]),
      );

      expect(similarity, isNotNull);
      expect(similarity, closeTo(1, 1e-9));
      expect(similarity, lessThanOrEqualTo(1));
    });

    test('returns 0 when either vector has no direction', () {
      expect(
        speakerSimilarity(
          _embedding(const <double>[0, 0]),
          _embedding(const <double>[1, 0]),
        ),
        0,
      );
    });

    test('returns null across providers, models, and dimensions', () {
      final query = _embedding(const <double>[1, 0]);

      expect(
        speakerSimilarity(
          query,
          _embedding(const <double>[1, 0], providerId: 'sherpa'),
        ),
        isNull,
      );
      expect(
        speakerSimilarity(
          query,
          _embedding(const <double>[1, 0], modelId: 'wespeaker'),
        ),
        isNull,
      );
      expect(
        speakerSimilarity(query, _embedding(const <double>[1, 0, 0])),
        isNull,
      );
    });

    test('same dimension in a different space is still not comparable', () {
      // The whole point of the type: identical dimensions would otherwise
      // produce a well-formed score that clears an auto-apply threshold.
      final fluid = _embedding(const <double>[1, 0, 0]);
      final wespeaker = _embedding(
        const <double>[1, 0, 0],
        providerId: 'sherpa',
        modelId: 'wespeaker-resnet34',
      );

      expect(fluid.dimension, wespeaker.dimension);
      expect(speakerSimilarity(fluid, wespeaker), isNull);
    });
  });

  group('requireSpeakerSimilarity', () {
    test('returns the score inside a space', () {
      expect(
        requireSpeakerSimilarity(
          _embedding(const <double>[1, 0]),
          _embedding(const <double>[1, 0]),
        ),
        closeTo(1, 1e-9),
      );
    });

    test('throws with both space IDs across spaces', () {
      expect(
        () => requireSpeakerSimilarity(
          _embedding(const <double>[1, 0]),
          _embedding(const <double>[1, 0], modelId: 'wespeaker'),
        ),
        throwsA(
          isA<SpeechEmbeddingSpaceMismatch>()
              .having((e) => e.first, 'first', 'fluidaudio/vbx-diarization/2')
              .having((e) => e.second, 'second', 'fluidaudio/wespeaker/2'),
        ),
      );
    });
  });

  group('SpeakerSegment.embedding', () {
    test('is null by default and carried when supplied', () {
      final range = SpeechTimeRange(
        start: Duration.zero,
        end: const Duration(seconds: 1),
      );

      expect(SpeakerSegment(speakerId: 'S1', range: range).embedding, isNull);
      expect(
        SpeakerSegment(
          speakerId: 'S1',
          range: range,
          embedding: _embedding(const <double>[1, 0]),
        ).embedding,
        isNotNull,
      );
    });
  });

  test('SpeechCapability appends the new members without renumbering', () {
    // Persisted capability sets serialize by name, but an accidental reorder
    // would still silently rewrite anything that stored an index.
    expect(SpeechCapability.values.map((value) => value.name), <String>[
      'streamingSpeechToText',
      'batchSpeechToText',
      'textToSpeech',
      'voiceActivityDetection',
      'endOfUtterance',
      'diarization',
      'speakerEmbedding',
      'inverseTextNormalization',
    ]);
  });
}
