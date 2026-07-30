# Changelog

## Unreleased

- Fail a synthesis that produced no audio at all with
  `fluid_tts_empty_synthesis` instead of finishing clean. Kokoro answers
  over-long input with an empty stream — no error, no frames — which a graph
  route reports as a completed playback that rendered nothing; the source now
  raises a typed `SpeechFailure` on its frame stream and fails its session
  status with the same code. Empty input text is unaffected: the provider still
  rejects it up front with `fluid_empty_text`.
- Implement `TranscriptInverseTextNormalizer`. `normalizeTranscript()` rewrites
  a `SpeechTranscript` to written form without forcing the caller to choose
  between written-form text and word timings, so sentence segmentation,
  diarization alignment, and seeking back into the audio all keep working after
  ITN. It prefers `FluidItn.normalizeResult` — the whole-transcript native call
  added in `fluidaudio_dart` 0.4.0 — and falls back to `speech_core`'s
  `normalizeTranscriptPreservingWords` on a runtime that can only rewrite
  strings. Blank text and a no-op rewrite return the same instance; a
  transcript's own `languageTag` is enough to trigger the English-only guard.
- Add `FluidTranscriptItnDriver` to the injectable runtime seam, a refinement of
  `FluidItnDriver` the provider tests for with `is`. It returns text alone: the
  timings go in so FluidAudio can rewrite spans in place, and the timed words
  the caller already holds come back untouched, which makes it structurally
  impossible for this path to hand back a guessed timestamp — or to lose the
  absent confidence and speaker label a driver timing cannot carry.

- Stop discarding speaker embeddings at the driver boundary. Batch diarization
  now carries `FluidDiarizationSegment.embedding` through to
  `SpeakerSegment.embedding`, tagged with the `fluidaudio` provider ID and the
  `vbx-diarization` model ID so the vectors can be compared against saved voice
  profiles without leaving their embedding space. The vectors are L2-normalized
  on the way out; an empty or non-finite vector is dropped rather than surfaced.
- Declare `SpeechCapability.speakerEmbedding` on the provider and on the
  `vbx-diarization` model.
- Implement `InverseTextNormalizer` and `CustomizableInverseTextNormalizer` over
  `FluidItn`, declared as `SpeechCapability.inverseTextNormalization` with a new
  `itn` model descriptor. Apps no longer need a direct `fluidaudio_dart`
  dependency to reach spoken-to-written conversion. The normalizer loads once,
  refuses non-English text, and fails with `fluid_itn_unavailable` when the
  native normalization library is missing rather than silently returning its
  input unchanged.
- Add `FluidItnDriver` and `FluidAudioRuntime.createItn` to the injectable
  runtime seam, and `fluidDiarizationModelId` alongside `fluidAudioProviderId`.
- Export the session, conversion, and synthesis-source types the provider
  already hands back: `FluidStreamingSpeechToTextSession`,
  `FluidVoiceActivityDetectionSession`, `FluidEndOfUtteranceSession`,
  `FluidManagedSession`, `FluidTtsAudioSource`, `FluidTtsAudioSourceSession`,
  `FluidCollectedAudio`, `FluidPcm16MonoConverter`, `collectFluidAudio`,
  `fluidAudioFailure`, `fluidLanguageCode`, and `fluidSpeechFailure`. They were
  reachable only through a `src/` import before.
- Stop discarding word timings on the batch path. `transcribe()` now reads
  `FluidAsrResult.tokenTimings` and fills `BatchRecognitionSegment.words`
  through the same mapper the streaming path uses, so the two paths cannot
  drift. The result stays one whole-audio segment — cutting it into sentences
  belongs to the batch pipeline, not to this adapter — but it is now a timed
  one.
- Refuse batch audio shorter than `SpeechAudioGuards.minimumRecognitionDuration`
  with the typed `speech_audio_too_short` failure, before any model is loaded.
  Parakeet needs a full second; below it the native result was noise or an
  empty string that read as silence.

## 0.1.0

- Initial public release.
