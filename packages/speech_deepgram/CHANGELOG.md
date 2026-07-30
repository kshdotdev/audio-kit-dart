# Changelog

## 0.1.1

- Export `IoDeepgramTransportFactory` from the package barrel. It is the
  default transport factory of `DeepgramSpeechToTextProvider`, so callers that
  wrap, subclass around, or explicitly re-select it no longer need a `src/`
  import.

## 0.1.0

- Initial public release.
