# Changelog

## Unreleased

- Initial package: cross-platform batch speech-to-text, Silero voice-activity
  detection, pyannote + WeSpeaker diarization with provenance-tagged speaker
  embeddings, and an on-demand model registry, all over sherpa-onnx.
- Streaming speech-to-text over sherpa's `OnlineRecognizer`, emitting volatile
  `RecognitionPartial` hypotheses that are confirmed as `RecognitionFinal` when
  the endpointer closes a segment. Runs on its own long-lived worker isolate.
- Streaming Zipformer models in the catalog: `streamingZipformerEn` (English,
  296 MB, the streaming default) and `streamingZipformerEn20M` (English,
  122 MB, low-power). Recognition capability is now declared per model, so a
  batch model never advertises `streamingSpeechToText` and vice versa.
- `SherpaStreamingRecognitionOptions` exposes sherpa's three endpointing rules.
  They are silence timers over decoder state, not an end-of-utterance model.
- `transcribe` refuses audio shorter than
  `SpeechAudioGuards.minimumRecognitionDuration` with the typed
  `speech_audio_too_short` failure, the same guard every batch provider
  enforces. This replaces the empty-audio path that returned an empty
  transcript: "too short to try" and "the user said nothing" are different
  answers and only one of them is actionable.
