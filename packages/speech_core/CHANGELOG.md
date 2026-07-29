# Changelog

## Unreleased

- Add `SpeakerEmbedding`, a speaker vector carrying the `(providerId, modelId,
  dimension)` space that produced it, plus `speakerSimilarity` (null across
  spaces), `requireSpeakerSimilarity` (throws `SpeechEmbeddingSpaceMismatch`)
  and `l2NormalizeVector`. Comparing embeddings from two different models can no
  longer return a plausible number, which is what turns a silent mislabel into a
  detectable one.
- Add `SpeakerSegment.embedding`, an optional field. Providers that only forward
  speaker labels leave it null; existing call sites are unaffected.
- Add `SpeechCapability.speakerEmbedding` and
  `SpeechCapability.inverseTextNormalization`, appended at the end of the enum.
  Persist capability sets by `name`, never `index`.
- Add the `InverseTextNormalizer` and `CustomizableInverseTextNormalizer`
  provider contracts plus `InverseTextNormalizationRule`, so spoken-to-written
  conversion has a provider-neutral seat instead of being reached through a
  direct adapter import.
- Add voice-profile matching: `VoiceProfile`, `VoiceMatch`,
  `VoiceMatchThresholds`, `bestVoiceMatch`, `suggestedNames`, `blendCentroid`
  and `unblendCentroid`. Thresholds are a required parameter rather than library
  constants, because a pair tuned for one embedding model says nothing about
  another; `VoiceMatchThresholds.wespeakerVoxceleb` documents the provenance of
  the 0.70 / 0.50 pair and the obligation to re-tune. Adapted from Control
  Center under MIT; see `NOTICE`.

## 0.1.0

- Initial public release.
