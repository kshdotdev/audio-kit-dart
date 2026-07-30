import 'package:speech_deepgram/speech_deepgram.dart';
import 'package:test/test.dart';

/// Pins the public export surface of `package:speech_deepgram`.
///
/// Every reference below resolves through the barrel alone, so narrowing or
/// dropping an export turns into a compile-time test failure instead of a
/// silent breaking change for downstream packages.
void main() {
  group('speech_deepgram barrel', () {
    test('exports the provider entry point', () {
      expect(<Type>[DeepgramSpeechToTextProvider], isNotEmpty);
    });

    test('exports the provider options', () {
      expect(<Type>[
        DeepgramDiarizationModel,
        DeepgramProviderConfig,
        DeepgramStreamingOptions,
      ], isNotEmpty);
    });

    test('exports the authorization seam', () {
      expect(<Type>[
        DeepgramAccessToken,
        DeepgramAuthorizationScheme,
        DeepgramTokenSource,
        StaticDeepgramTokenSource,
      ], isNotEmpty);
    });

    test('exports the transport seam', () {
      expect(<Type>[
        DeepgramStreamingTransport,
        DeepgramTransportClosed,
        DeepgramTransportError,
        DeepgramTransportEvent,
        DeepgramTransportFactory,
        DeepgramTransportRequest,
        DeepgramTransportText,
        IoDeepgramTransportFactory,
      ], isNotEmpty);
    });
  });
}
