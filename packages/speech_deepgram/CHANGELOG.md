# Changelog

## 0.1.2

- Widen `speech_core` to `^0.2.0`.
- Note: 0.1.1 was tagged but never reached pub.dev (the release preflight
  failed on the since-removed sibling-checkout overrides); its transport
  factory export ships here.

## 0.1.1

- Export `IoDeepgramTransportFactory` from the package barrel. It is the
  default transport factory of `DeepgramSpeechToTextProvider`, so callers that
  wrap, subclass around, or explicitly re-select it no longer need a `src/`
  import.

## 0.1.0

- Initial public release.
