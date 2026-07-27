import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unsupported implementation reports platform capabilities safely',
    () async {
      expect(
        await AudioFlutterPlatform.instance.isSystemAudioCaptureSupported(),
        isFalse,
      );
      expect(
        await AudioFlutterPlatform.instance.listAudioInputDevices(),
        isEmpty,
      );
      expect(await AudioFlutterPlatform.instance.listAudioProcesses(), isEmpty);
      expect(
        () => AudioFlutterPlatform.instance.prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.microphone,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          ),
        ),
        throwsUnsupportedError,
      );
    },
  );

  test('platform PCM format has value semantics', () {
    expect(
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );
  });
}
