/// Linux implementation of the audio_flutter platform contract, built on the
/// PulseAudio/PipeWire command-line tools.
library;

export 'src/capture_session.dart' show kLinuxCaptureStallTimeout;
export 'src/frame_ring.dart' show FrameRing, FrameRingAdmission;
export 'src/pcm.dart' show decodeS16le, encodeS16le;
export 'src/platform.dart' show AudioFlutterLinux, LinuxAudioFlutterPlatform;
export 'src/process_runner.dart'
    show
        LinuxProcessHandle,
        LinuxProcessResult,
        LinuxProcessRunner,
        SystemLinuxProcessRunner;
export 'src/pulse_commands.dart'
    show
        LinuxAudioFormatException,
        LinuxAudioTools,
        PulseSource,
        captureCommands,
        defaultSinkMonitor,
        parseSourcesShort,
        playbackCommands,
        sampleFramesPerFrame,
        samplesPerFrame,
        validateCaptureFormat,
        validatePlaybackFormat;
export 'src/recording_sink.dart'
    show LinuxRecordingSink, LinuxRecordingSinkFactory, WavFileRecordingSink;
