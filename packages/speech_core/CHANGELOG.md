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
- Add `BatchRecognitionSegment.words`, an optional `List<SpeechWord>` that
  defaults to empty and is copied on construction. Batch recognition could
  previously only return a block of untimed text, so nothing downstream could
  cut it into sentences, align it to a diarization span, or seek back into the
  audio — an asymmetry with the streaming path, which has always carried
  `SpeechTranscript.words`. Existing call sites are unaffected.
- Add `SpeechAudioGuards` with `minimumRecognitionDuration` (one second, the
  16,000 samples at 16 kHz that batch recognizers need) and the
  `speech_audio_too_short` failure code. Providers refuse shorter audio with a
  typed `SpeechFailure` instead of returning an empty transcript, which is
  indistinguishable from the user having said nothing.
- Add the turn-completion seam: `TurnCompletionScorer` with
  `scoreTurnCompletion(TurnCompletionRequest)`, plus `TurnCompletionScore`
  (`probability`, `isComplete`, optional `threshold`) and `TurnCompletionAudio`
  (16 kHz, an eight-second maximum window, a 0.5 default threshold compared
  strictly greater-than). The request carries a finite mono
  `BufferedAudioSource` — narrower than the `AudioSource` the other batch
  requests accept, because a scorer that cannot see the end of the window has
  nothing to score — plus an optional threshold override, cancellation, and
  provider options. This is what lets a turn detector reach a prosody model in
  an adapter package without the two packages depending on each other.
- Add `SpeechCapability.turnCompletion`, appended at the end of the enum.
  **Breaking for exhaustive switches**: code that switches over
  `SpeechCapability` without a default arm stops compiling until the new member
  is handled. Persist capability sets by `name`, never `index`.
- Add `TranscriptInverseTextNormalizer`, an optional refinement of
  `InverseTextNormalizer` adding `normalizeTranscript(SpeechTranscript)`, plus
  the `normalizeTranscriptPreservingWords` helper implementing the baseline
  behavior over any string normalizer. ITN and word timings could not coexist:
  normalizing a transcript meant reducing it to a string and throwing away the
  timings that sentence segmentation, diarization alignment, and seeking all
  depend on. Deliberately a sub-interface rather than a new member on
  `InverseTextNormalizer`, so existing implementers keep compiling and a
  provider that can only rewrite strings stays a valid one; callers test for
  the stronger contract with `is`.

## 0.1.0

- Initial public release.
