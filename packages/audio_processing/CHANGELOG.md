# Changelog

## 0.2.0

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
- Add `AudioRing`: a fixed-capacity float32 ring addressed by a monotonic
  absolute write index, so a position reported by a VAD — counted from the
  start of the stream — indexes the audio directly no matter how often the
  buffer has wrapped. Ranges older than the capacity are clipped rather than
  wrapped, because returning samples from the wrong moment is indistinguishable
  from success. Defaults to 160,000 samples, ten seconds at 16 kHz.
- Add `AdaptiveGain` and `AdaptiveGainProcessor`: slow automatic gain control
  that amplifies quiet capture toward a 0.3 target peak (30x ceiling, 0.995
  per-chunk running-peak decay, 1.05 deadband) and never attenuates. Speech
  models trained on normalized audio collapse on the 0.05-peak recordings real
  microphones produce; the slow decay is what keeps the noise floor from being
  pumped up between utterances. The processor keeps one running peak per stream
  and drops it on a discontinuity.
- Add segmented WAV recording: `SegmentedWavRecorder` rotates bounded WAV
  segments while durably mirroring a JSON sidecar
  (`SegmentedWavRecordingManifest`) with pause/resume/source-change markers,
  bounded queue policies (`wait`, `dropNewest`, `failRecorder`), and a stable
  failed state on segment IO errors. Storage is injected through the new
  `SegmentedWavStorage`/`SegmentedWavStorageFile` ports;
  `LocalSegmentedWavStorage` is the `dart:io` adapter.
- Add crash recovery for segmented recordings: `recoverSegmentedWavRecording`
  repairs every segment named by the durable sidecar after an interrupted
  process, and `repairWavStorageFile` repairs one canonical WAV held in any
  `SegmentedWavStorageFile`. `repairWavFileHeader` covers the path-based
  `dart:io` case.
- Add `WavFileAudioSource`: an `AudioSource` over a canonical WAV file for
  offline pipelines.
- Keep the portable/`dart:io` barrel split intact for the new APIs:
  `audio_processing.dart` exports only portable code (recorder, manifest,
  storage ports, storage-based recovery), while `audio_processing_io.dart`
  adds `LocalSegmentedWavStorage`, `WavFileAudioSource`, `WavFileAudioSink`,
  and `repairWavFileHeader`. `SegmentedWavRecorder.create` and
  `recoverSegmentedWavRecording` take required storage instead of a
  `directoryPath` convenience, so portable code never constructs `dart:io`
  storage implicitly.

## 0.1.0

- Initial public release.
