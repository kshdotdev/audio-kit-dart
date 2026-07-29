# Changelog

## Unreleased

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

## 0.1.0

- Initial public release.
