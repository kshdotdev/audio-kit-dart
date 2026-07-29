# Changelog

## Unreleased

- Add `AecDelayEstimator`: envelope cross-correlation delay estimation between a
  loopback reference and a microphone capture, with recency-weighted median
  smoothing and two lock tiers. Amplitude thresholds are float32-native; see
  `AecDelayEstimator.defaultMinNearStd`.
- Add `AecBlockAccumulator` plus `floatToPcm16`/`pcm16ToFloat` for chopping
  float32 captures into the exact 10 ms int16 blocks an echo canceller requires.
- Add `mixTracksToMono` and `peakBuckets` for offline mixdown and waveform
  rendering of completed recordings of differing lengths, which the streaming
  `AudioMixer` cannot express.
- Adapted from Control Center (MIT © 2026 Samuel Alev); see `NOTICE`.

## 0.1.0

- Initial public release.
