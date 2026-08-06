# Changelog

## Unreleased

- Add the `CaptureBackend` contract: normalized source discovery
  (`CaptureSourceDescriptor`, `CaptureSourceKind`,
  `CaptureSourceAvailability`), single-use probe grants
  (`CaptureProbeRequest`/`CaptureProbeResult`), and an explicit
  fallback-confirmation protocol
  (`CaptureFallbackProposal`/`CaptureFallbackConfirmation`) so a backend can
  propose a degraded source but never silently substitute one. No backend
  emits a proposal yet; the protocol ships dormant.
- Add capture manifests (`AudioCaptureSessionManifest`,
  `CapturedAudioTrackManifest`, `AudioCaptureSourceIdentity`,
  `AudioCaptureDegradationReason`): a durable, provider-neutral description of
  what a capture actually produced versus what the host requested.
  Experimental forward contract — nothing in this workspace consumes it yet.
- Add `MonotonicTrackTiming` and `MonotonicTrackTimingQuality`: maps one
  captured track onto a shared monotonic session timeline with integer sample
  arithmetic. Wall-clock timestamps are deliberately absent. Experimental
  forward contract — nothing in this workspace consumes it yet.
- Add `RealtimeAudioFeedSource`: a single-consumer source fed synchronously by
  a host capture graph, for compositions that must tap one native capture
  twice (durable track plus echo-canceller feed) without a hidden queue —
  `add` delivers synchronously or returns `false`, so realtime input cannot
  accumulate in memory.

## 0.1.0

- Initial public release.
