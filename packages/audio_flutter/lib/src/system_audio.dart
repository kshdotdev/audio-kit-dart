import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// A process visible to the platform audio server.
final class AudioCaptureProcess {
  const AudioCaptureProcess({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  final int processId;
  final String bundleId;
  final bool isProducingAudio;
}

/// Platform capability and permission helpers for system-audio capture.
final class FlutterSystemAudio {
  FlutterSystemAudio({AudioFlutterPlatform? platform})
    : _platform = platform ?? AudioFlutterPlatform.instance;

  final AudioFlutterPlatform _platform;

  Future<bool> get isSupported async {
    try {
      return await _platform.isSystemAudioCaptureSupported();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_system_audio_capability_failed',
          message: 'System-audio support could not be determined.',
        ),
        stackTrace,
      );
    }
  }

  Future<bool> requestPermission({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final bool granted = await _platform
          .requestSystemAudioCapturePermission();
      cancellationToken?.throwIfCancelled();
      return granted;
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_system_audio_permission_failed',
          message: 'System-audio permission could not be requested.',
        ),
        stackTrace,
      );
    }
  }

  /// Destroys private capture devices this plugin leaked in an earlier run,
  /// returning how many were reclaimed.
  ///
  /// Call it once at app start, before the first capture. A process killed
  /// mid-capture (crash, `kill -9`, a debugger stop) cannot unwind the private
  /// aggregate device its system tap runs on, and those devices accumulate in
  /// the audio server across runs. Only devices this plugin created are
  /// touched, and never one a live session still owns, so the call is safe at
  /// any time — but running it while other captures are active in this process
  /// is pointless, since their devices are exactly the ones it skips.
  ///
  /// Returns 0 on platforms with no such devices to reclaim.
  Future<int> cleanupOrphanedCaptureDevices({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final int destroyed = await _platform.cleanupOrphanedCaptureDevices();
      cancellationToken?.throwIfCancelled();
      return destroyed;
    } on AudioCancelledException {
      rethrow;
    } on UnimplementedError {
      // Platforms endorsed before this API existed leak nothing to reclaim.
      return 0;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_capture_device_cleanup_failed',
          message: 'Orphaned capture devices could not be reclaimed.',
        ),
        stackTrace,
      );
    }
  }

  Future<List<AudioCaptureProcess>> listProcesses({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final List<PlatformAudioProcess> processes = await _platform
          .listAudioProcesses();
      cancellationToken?.throwIfCancelled();
      return <AudioCaptureProcess>[
        for (final PlatformAudioProcess process in processes)
          AudioCaptureProcess(
            processId: process.processId,
            bundleId: process.bundleId,
            isProducingAudio: process.isProducingAudio,
          ),
      ];
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_audio_processes_failed',
          message: 'Audio-producing processes could not be listed.',
        ),
        stackTrace,
      );
    }
  }
}

AudioFailure _systemAudioFailure(
  Object error, {
  required String code,
  required String message,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.capture,
        message: message,
        retryable: true,
        safeCause: error.runtimeType.toString(),
      );
