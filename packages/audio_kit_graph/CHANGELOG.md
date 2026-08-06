# Changelog

## Unreleased

- A failed upstream no longer costs lossless routes their accepted frames.
  `AudioRouter.drainThenAbort` delivers every frame a route already admitted
  to its sink and then aborts the route with the stable failure, so the sink
  keeps the audio while still learning the stream ended abnormally — `finish`
  stays reserved for genuine completion. `AudioHub` uses it for mid-capture
  source failures, and a source that throws during a graceful `stop()` now
  drains routes to a clean finish before the hub fails. The hub reports the
  `failed` state only after this teardown settles, so observers of the
  terminal state can trust the sinks. An explicit `abort()` still tears down
  immediately and discards queued frames.

## 0.1.0

- Initial public release.
