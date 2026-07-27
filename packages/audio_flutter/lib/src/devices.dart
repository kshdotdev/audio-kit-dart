import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// A physical microphone/input selectable by stable platform ID.
final class AudioInputDevice {
  const AudioInputDevice({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  /// Stable device ID accepted by `FlutterAudioCaptureConfig.inputDeviceId`.
  final String id;

  /// User-facing device name.
  final String label;

  /// Whether this is the platform's current default input.
  final bool isDefault;
}

/// Provider-neutral input-device discovery.
final class FlutterAudioDevices {
  FlutterAudioDevices({AudioFlutterPlatform? platform})
    : _platform = platform ?? AudioFlutterPlatform.instance;

  final AudioFlutterPlatform _platform;

  /// Lists physical input devices available to new capture sessions.
  Future<List<AudioInputDevice>> listInputs({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final List<PlatformAudioInputDevice> devices = await _platform
          .listAudioInputDevices();
      cancellationToken?.throwIfCancelled();
      return <AudioInputDevice>[
        for (final PlatformAudioInputDevice device in devices)
          AudioInputDevice(
            id: device.id,
            label: device.label,
            isDefault: device.isDefault,
          ),
      ];
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AudioFailure(
          code: 'platform_input_devices_failed',
          stage: AudioFailureStage.capture,
          message: 'Audio input devices could not be listed.',
          retryable: true,
          safeCause: error.runtimeType.toString(),
        ),
        stackTrace,
      );
    }
  }
}
