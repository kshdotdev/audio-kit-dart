# Changelog

## Unreleased

- Added `MlxSmartTurnScorer`, a `TurnCompletionScorer` over the pinned Smart
  Turn v3.2 classifier. It declares `SpeechCapability.turnCompletion` and runs
  inference in a long-lived worker isolate, so the model is loaded (and warmed)
  once and every window is scored off the calling isolate.
- Added the turn-completion worker seam: `MlxTurnWorker`,
  `MlxIsolateTurnWorker` (production), `SerializedMlxTurnWorker` (tests and
  embedding-specific workers), `MlxTurnWorkerRequest`, and
  `MlxTurnWorkerResult`.
- Added `MlxSmartTurnOptions` for turn-completion model routing.
- Export `MlxTtsCoordinator` from the package barrel. The synthesis
  coordinator owned by `MlxSpeechProvider` was previously unnameable without a
  `src/` import.

## 0.1.0

- Initial public release.
