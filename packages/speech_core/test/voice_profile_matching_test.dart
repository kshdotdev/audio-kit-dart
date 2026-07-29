// Adapted from Control Center's
// test/features/meetings/voice_profile_matching_test.dart, MIT (c) 2026 Samuel
// Alev (github.com/SamuelAlev/control-center). See this package's NOTICE file.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

const VoiceMatchThresholds _thresholds = VoiceMatchThresholds.wespeakerVoxceleb;

SpeakerEmbedding _embedding(
  List<double> vector, {
  String providerId = 'fluidaudio',
  String modelId = 'vbx-diarization',
}) => SpeakerEmbedding(
  providerId: providerId,
  modelId: modelId,
  vector: Float32List.fromList(vector),
);

VoiceProfile _profile(
  String name,
  List<double> vector, {
  int count = 1,
  String providerId = 'fluidaudio',
  String modelId = 'vbx-diarization',
}) => VoiceProfile(
  id: 'vp_$name',
  displayName: name,
  centroid: _embedding(vector, providerId: providerId, modelId: modelId),
  sampleCount: count,
);

double _magnitude(SpeakerEmbedding embedding) {
  var sum = 0.0;
  for (final value in embedding.vector) {
    sum += value * value;
  }
  return math.sqrt(sum);
}

void main() {
  group('VoiceMatchThresholds', () {
    test('wespeakerVoxceleb keeps the documented pair and provenance', () {
      expect(_thresholds.autoApply, 0.70);
      expect(_thresholds.suggest, 0.50);
      expect(_thresholds.provenance, contains('Control Center'));
    });
  });

  group('bestVoiceMatch', () {
    test('picks the highest-cosine profile', () {
      final match = bestVoiceMatch(
        _embedding(const <double>[1, 0, 0]),
        <VoiceProfile>[
          _profile('A', const <double>[1, 0, 0]),
          _profile('B', const <double>[0, 1, 0]),
        ],
        thresholds: _thresholds,
      );

      expect(match, isNotNull);
      expect(match!.profile.displayName, 'A');
      expect(match.similarity, closeTo(1, 1e-9));
    });

    test('returns null when nothing clears the suggest threshold', () {
      final match = bestVoiceMatch(
        _embedding(const <double>[0, 0, 1]),
        <VoiceProfile>[
          _profile('A', const <double>[1, 0, 0]),
          _profile('B', const <double>[0, 1, 0]),
        ],
        thresholds: _thresholds,
      );

      expect(match, isNull);
    });

    test('returns null when there are no profiles', () {
      expect(
        bestVoiceMatch(
          _embedding(const <double>[1, 0]),
          const <VoiceProfile>[],
          thresholds: _thresholds,
        ),
        isNull,
      );
    });

    test('skips profiles saved under a different embedding space', () {
      // An identical vector in a foreign space would score 1.0 on a bare
      // cosine and auto-apply the wrong name.
      final match = bestVoiceMatch(
        _embedding(const <double>[1, 0, 0]),
        <VoiceProfile>[
          _profile('Stale', const <double>[
            1,
            0,
            0,
          ], modelId: 'wespeaker-resnet34'),
        ],
        thresholds: _thresholds,
      );

      expect(match, isNull);
    });

    test('a caller-supplied threshold pair changes the outcome', () {
      final profiles = <VoiceProfile>[
        _profile('Mid', const <double>[0.6, 0.8]),
      ];
      const permissive = VoiceMatchThresholds(
        autoApply: 0.8,
        suggest: 0.4,
        provenance: 'test',
      );
      const strict = VoiceMatchThresholds(
        autoApply: 0.95,
        suggest: 0.9,
        provenance: 'test',
      );

      expect(
        bestVoiceMatch(
          _embedding(const <double>[1, 0]),
          profiles,
          thresholds: permissive,
        ),
        isNotNull,
      );
      expect(
        bestVoiceMatch(
          _embedding(const <double>[1, 0]),
          profiles,
          thresholds: strict,
        ),
        isNull,
      );
    });
  });

  group('VoiceMatch.isAutoApply', () {
    test('true at or above the auto-apply threshold, false below', () {
      final profile = _profile('A', const <double>[1, 0]);

      expect(
        VoiceMatch(
          profile: profile,
          similarity: _thresholds.autoApply,
        ).isAutoApply(_thresholds),
        isTrue,
      );
      expect(
        VoiceMatch(profile: profile, similarity: 0.85).isAutoApply(_thresholds),
        isTrue,
      );
      expect(
        VoiceMatch(
          profile: profile,
          similarity: _thresholds.autoApply - 0.01,
        ).isAutoApply(_thresholds),
        isFalse,
      );
      // A merely-plausible (suggest-range) match is not auto-applied.
      expect(
        VoiceMatch(
          profile: profile,
          similarity: _thresholds.suggest,
        ).isAutoApply(_thresholds),
        isFalse,
      );
    });
  });

  group('suggestedNames', () {
    test('returns plausible names ordered by similarity, capped', () {
      // cos([1,0], [1,0])=1.0, [0.6,0.8]=0.6 (both >= 0.5), [0,1]=0 (excluded).
      final names = suggestedNames(
        _embedding(const <double>[1, 0]),
        <VoiceProfile>[
          _profile('Mid', const <double>[0.6, 0.8]),
          _profile('Best', const <double>[1, 0]),
          _profile('None', const <double>[0, 1]),
        ],
        thresholds: _thresholds,
      );

      expect(names, <String>['Best', 'Mid']);
    });

    test('honors the max cap', () {
      final names = suggestedNames(
        _embedding(const <double>[1, 0]),
        <VoiceProfile>[
          _profile('Best', const <double>[1, 0]),
          _profile('Mid', const <double>[0.6, 0.8]),
        ],
        thresholds: _thresholds,
        max: 1,
      );

      expect(names, <String>['Best']);
    });

    test('de-duplicates by display name', () {
      final names = suggestedNames(
        _embedding(const <double>[1, 0]),
        <VoiceProfile>[
          _profile('Sam', const <double>[1, 0]),
          _profile('Sam', const <double>[0.6, 0.8]),
        ],
        thresholds: _thresholds,
      );

      expect(names, <String>['Sam']);
    });

    test('is empty when no profile is plausible or max is not positive', () {
      expect(
        suggestedNames(_embedding(const <double>[0, 1]), <VoiceProfile>[
          _profile('A', const <double>[1, 0]),
        ], thresholds: _thresholds),
        isEmpty,
      );
      expect(
        suggestedNames(
          _embedding(const <double>[1, 0]),
          <VoiceProfile>[
            _profile('A', const <double>[1, 0]),
          ],
          thresholds: _thresholds,
          max: 0,
        ),
        isEmpty,
      );
    });

    test('skips profiles from a foreign embedding space', () {
      expect(
        suggestedNames(_embedding(const <double>[1, 0]), <VoiceProfile>[
          _profile('Stale', const <double>[1, 0], providerId: 'sherpa'),
        ], thresholds: _thresholds),
        isEmpty,
      );
    });
  });

  group('blendCentroid', () {
    test('re-normalizes the weighted mean to unit length', () {
      final blended = blendCentroid(
        _profile('A', const <double>[1, 0]),
        _embedding(const <double>[0, 1]),
      );

      // mean = [0.5, 0.5] -> normalized = [0.7071, 0.7071]
      expect(blended, isNotNull);
      expect(blended!.vector[0], closeTo(math.sqrt1_2, 1e-6));
      expect(blended.vector[1], closeTo(math.sqrt1_2, 1e-6));
      expect(_magnitude(blended), closeTo(1, 1e-6));
    });

    test('weights the existing centroid by its sample count', () {
      // old has 3 samples -> the new sample moves it only a little.
      final blended = blendCentroid(
        _profile('A', const <double>[1, 0], count: 3),
        _embedding(const <double>[0, 1]),
      );

      expect(blended, isNotNull);
      expect(blended!.vector[0], greaterThan(blended.vector[1]));
    });

    test('keeps the sample space on the result', () {
      final blended = blendCentroid(
        _profile('A', const <double>[1, 0]),
        _embedding(const <double>[0, 1]),
      );

      expect(blended!.spaceId, 'fluidaudio/vbx-diarization/2');
    });

    test('starts fresh from the normalized sample at a zero sample count', () {
      final blended = blendCentroid(
        _profile('A', const <double>[1, 0], count: 0),
        _embedding(const <double>[3, 4]),
      );

      expect(blended, isNotNull);
      expect(blended!.vector[0], closeTo(0.6, 1e-6));
      expect(blended.vector[1], closeTo(0.8, 1e-6));
    });

    test('returns null on a space mismatch instead of a fresh start', () {
      // Control Center normalized the sample here. That silently discarded the
      // enrolled identity, and same dimension is not same space anyway.
      expect(
        blendCentroid(
          _profile('A', const <double>[1, 0]),
          _embedding(const <double>[1, 0], modelId: 'wespeaker'),
        ),
        isNull,
      );
      expect(
        blendCentroid(
          _profile('A', const <double>[1, 0]),
          _embedding(const <double>[3, 4, 0]),
        ),
        isNull,
      );
    });
  });

  group('unblendCentroid', () {
    test('backing a sample out pulls the centroid toward the kept sample', () {
      // Blend [1,0] and [0,1] (count 1->2): centroid = normalize([0.5,0.5]).
      final centroid = blendCentroid(
        _profile('A', const <double>[1, 0]),
        _embedding(const <double>[0, 1]),
      )!;
      // Remove the [0,1] sample -> the centroid leans back toward [1,0]. An
      // approximate inverse: each blend re-normalized, so it is not exact, but
      // it must move in the right direction and stay unit length.
      final back = unblendCentroid(
        VoiceProfile(
          id: 'vp_A',
          displayName: 'A',
          centroid: centroid,
          sampleCount: 2,
        ),
        _embedding(const <double>[0, 1]),
      );

      expect(back, isNotNull);
      expect(back!.vector[0], greaterThan(centroid.vector[0]));
      expect(back.vector[0], greaterThan(back.vector[1]));
      expect(_magnitude(back), closeTo(1, 1e-6));
    });

    test('returns null when removing the only sample (count <= 1)', () {
      expect(
        unblendCentroid(
          _profile('A', const <double>[1, 0]),
          _embedding(const <double>[1, 0]),
        ),
        isNull,
      );
      expect(
        unblendCentroid(
          _profile('A', const <double>[1, 0], count: 0),
          _embedding(const <double>[1, 0]),
        ),
        isNull,
      );
    });

    test(
      'returns null on a space mismatch (cannot un-blend a foreign vector)',
      () {
        expect(
          unblendCentroid(
            _profile('A', const <double>[1, 0], count: 3),
            _embedding(const <double>[1, 0, 0]),
          ),
          isNull,
        );
        expect(
          unblendCentroid(
            _profile('A', const <double>[1, 0], count: 3),
            _embedding(const <double>[1, 0], providerId: 'sherpa'),
          ),
          isNull,
        );
      },
    );

    test('result stays unit length for the remaining samples', () {
      // Three unit samples blended in, then back one out.
      var centroid = blendCentroid(
        _profile('A', const <double>[1, 0, 0]),
        _embedding(const <double>[0, 1, 0]),
      )!;
      centroid = blendCentroid(
        VoiceProfile(
          id: 'vp_A',
          displayName: 'A',
          centroid: centroid,
          sampleCount: 2,
        ),
        _embedding(const <double>[0, 0, 1]),
      )!;
      final back = unblendCentroid(
        VoiceProfile(
          id: 'vp_A',
          displayName: 'A',
          centroid: centroid,
          sampleCount: 3,
        ),
        _embedding(const <double>[0, 0, 1]),
      )!;

      expect(_magnitude(back), closeTo(1, 1e-6));
    });
  });

  group('VoiceProfile', () {
    test('rejects a blank ID or name and a negative sample count', () {
      expect(
        () => VoiceProfile(
          id: ' ',
          displayName: 'A',
          centroid: _embedding(const <double>[1, 0]),
          sampleCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => VoiceProfile(
          id: 'vp',
          displayName: '',
          centroid: _embedding(const <double>[1, 0]),
          sampleCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => VoiceProfile(
          id: 'vp',
          displayName: 'A',
          centroid: _embedding(const <double>[1, 0]),
          sampleCount: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
