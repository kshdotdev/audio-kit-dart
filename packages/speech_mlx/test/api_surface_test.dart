import 'package:speech_mlx/speech_mlx.dart';
import 'package:test/test.dart';

/// Pins the public export surface of `package:speech_mlx`.
///
/// Every reference below resolves through the barrel alone, so narrowing or
/// dropping an export turns into a compile-time test failure instead of a
/// silent breaking change for downstream packages.
void main() {
  group('speech_mlx barrel', () {
    test('exports the provider entry points', () {
      expect(mlxSpeechProviderId, isNotEmpty);
      expect(<Type>[MlxSpeechProvider, MlxTtsCoordinator], isNotEmpty);
      expect(<Function>[mlxVoiceDisplayName], isNotEmpty);
    });

    test('exports the provider options', () {
      expect(<Type>[
        MlxRecognitionOptions,
        MlxSmartTurnOptions,
        MlxSynthesisOptions,
      ], isNotEmpty);
    });

    test('exports the turn-completion scorer and its worker seam', () {
      expect(mlxSmartTurnModelId, isNotEmpty);
      expect(<Type>[
        MlxIsolateTurnWorker,
        MlxSmartTurnScorer,
        MlxTurnWorker,
        MlxTurnWorkerRequest,
        MlxTurnWorkerResult,
        SerializedMlxTurnWorker,
      ], isNotEmpty);
    });

    test('exports the batch recognition worker seam', () {
      expect(<Type>[
        MlxBatchWorker,
        MlxBatchWorkerRequest,
        MlxBatchWorkerResult,
        MlxBatchWorkerSegment,
        MlxIsolateBatchWorker,
        MlxWorkerException,
        SerializedMlxBatchWorker,
      ], isNotEmpty);
    });

    test('exports the synthesis worker seam', () {
      expect(<Type>[
        MlxIsolateTtsWorker,
        MlxTtsWorker,
        MlxTtsWorkerChunk,
        MlxTtsWorkerRequest,
        MlxTtsWorkerResult,
        SerializedMlxTtsWorker,
      ], isNotEmpty);
    });
  });
}
