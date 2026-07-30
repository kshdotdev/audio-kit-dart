/// Windows implementation of the audio_flutter platform contract, built on
/// WASAPI shared-mode loopback and capture clients.
library;

export 'src/channel.dart'
    show
        kWindowsCaptureStallTimeout,
        kWindowsEventChannel,
        kWindowsMethodChannel;
export 'src/codec.dart' show decodeFloat32Le, encodeFloat32Le;
export 'src/platform.dart'
    show AudioFlutterWindows, WindowsAudioFlutterPlatform;
