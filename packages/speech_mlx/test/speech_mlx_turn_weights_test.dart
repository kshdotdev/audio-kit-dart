/// Real-checkpoint check for the Smart Turn scorer's isolate path.
///
/// The default lane covers the scorer's behaviour through
/// `SerializedMlxTurnWorker`; this one proves the piece a fake cannot: that
/// `MlxIsolateTurnWorker` really loads the pinned checkpoint in a worker
/// isolate, keeps it resident across requests, and hands back probabilities the
/// adapter does not distort.
///
/// Numeric parity against the ectos Swift oracle and the fp32 ONNX reference
/// lives where the model does (`mlx_audio`, `test/smart_turn_parity_test.dart`).
///
/// **Opt-in twice over.** It carries the `weights` tag AND a runtime skip on
/// `SPEECH_MLX_WEIGHTS_TESTS`, because `flutter test` — which is what
/// `tool/verify.sh` and CI run — does not honour `dart_test.yaml`'s tag skips.
/// Without the guard this suite would download a 32 MB checkpoint and demand
/// the Apple-Silicon-only MLX native libraries on a Linux CI runner.
///
/// ```sh
/// dart run mlx:setup   # once, builds the native MLX libraries
/// SPEECH_MLX_WEIGHTS_TESTS=1 flutter test packages/speech_mlx/test/speech_mlx_turn_weights_test.dart
/// # or point at an existing snapshot instead of downloading the pin:
/// SMART_TURN_MODEL_DIR=~/…/smart-turn-v3 flutter test …
/// ```
@Tags(<String>['weights'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:speech_core/speech_core.dart';
import 'package:speech_mlx/speech_mlx.dart';
import 'package:test/test.dart';

/// The explicit opt-in: an env var, not a platform sniff, so a macOS developer
/// who has not run `dart run mlx:setup` is not ambushed by a native load
/// failure in an ordinary test run.
String? get _skipReason {
  final environment = Platform.environment;
  if (environment['SPEECH_MLX_WEIGHTS_TESTS'] == '1' ||
      environment['SMART_TURN_MODEL_DIR'] != null) {
    return null;
  }
  return 'needs the pinned Smart Turn checkpoint and the MLX native libraries; '
      'set SPEECH_MLX_WEIGHTS_TESTS=1 (or SMART_TURN_MODEL_DIR) to run';
}

void main() {
  group('MlxIsolateTurnWorker against the pinned checkpoint', () {
    late MlxSmartTurnScorer scorer;

    setUpAll(() {
      scorer = MlxSmartTurnScorer(
        worker: MlxIsolateTurnWorker(
          modelDirectory: Platform.environment['SMART_TURN_MODEL_DIR'],
        ),
      );
    });

    tearDownAll(() async {
      await scorer.close();
    });

    test(
      'scores digital silence as an incomplete turn',
      () async {
        final score = await scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(Float32List(8 * 16000)),
        );
        expect(score.probability, inInclusiveRange(0, 1));
        expect(score.threshold, 0.5);
        expect(score.probability, lessThan(0.5));
        expect(score.isComplete, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'keeps the model resident and deterministic across requests',
      () async {
        final window = Float32List(4 * 16000);
        for (var i = 0; i < window.length; i++) {
          window[i] = 0.1 * (i % 97 - 48) / 48;
        }
        final first = await scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(window),
        );
        final second = await scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(window),
        );
        expect(second.probability, first.probability);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'a threshold override flips only the verdict',
      () async {
        final silence = Float32List(16000);
        final base = await scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(silence),
        );
        final forced = await scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(silence, threshold: 0),
        );
        expect(forced.probability, base.probability);
        expect(base.isComplete, isFalse);
        expect(forced.isComplete, isTrue);
        expect(forced.threshold, 0);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }, skip: _skipReason);
}
