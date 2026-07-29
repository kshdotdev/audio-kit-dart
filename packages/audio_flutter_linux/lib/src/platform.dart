import 'dart:async';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

import 'capture_session.dart';
import 'playback_session.dart';
import 'process_runner.dart';
import 'pulse_commands.dart';
import 'recording_sink.dart';

/// Registers the Linux implementation selected by audio_flutter's
/// `default_package` declaration.
abstract final class AudioFlutterLinux {
  static void registerWith() {
    AudioFlutterPlatform.instance = LinuxAudioFlutterPlatform();
  }
}

/// PulseAudio/PipeWire implementation of the federated platform contract.
///
/// Capture and playback both shell out to the standard command-line tools —
/// `parecord`/`pw-record` and `paplay`/`pw-play` — so the package carries no
/// native code and needs no plugin registrant beyond its Dart class.
///
/// ## Targeting
///
/// PulseAudio exposes one flat source namespace: hardware inputs
/// (`alsa_input.*`) and sink monitors (`alsa_output.*.monitor`) are both
/// sources addressable by name. [PlatformCaptureRequest.inputDeviceId]
/// therefore carries a PulseAudio **source name** for both capture kinds — a
/// hardware source for [PlatformCaptureKind.microphone], a `.monitor` source
/// for [PlatformCaptureKind.systemAudio]. Leaving it null selects the default
/// input for microphone capture, and the default sink's monitor for system
/// audio. No additional request field is needed, and none was added.
///
/// [PlatformCaptureRequest.processIds] has no Linux equivalent and is ignored;
/// [listAudioProcesses] returns an empty list for the same reason.
final class LinuxAudioFlutterPlatform extends AudioFlutterPlatform {
  LinuxAudioFlutterPlatform({
    LinuxProcessRunner? runner,
    LinuxRecordingSinkFactory? recordingSinkFactory,
    Duration? stallTimeout,
  }) : _runner = runner ?? const SystemLinuxProcessRunner(),
       _recordingSinkFactory = recordingSinkFactory ?? WavFileRecordingSink.new,
       _stallTimeout = stallTimeout ?? kLinuxCaptureStallTimeout;

  final LinuxProcessRunner _runner;
  final LinuxRecordingSinkFactory _recordingSinkFactory;
  final Duration _stallTimeout;

  final Map<int, LinuxCaptureSession> _captures = <int, LinuxCaptureSession>{};
  final Map<int, LinuxPlaybackSession> _playbacks =
      <int, LinuxPlaybackSession>{};

  int _nextSessionId = 1;

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    validateCaptureFormat(
      request.outputFormat,
      frameDuration: request.frameDuration,
    );

    final String? target = await _resolveCaptureTarget(request);
    final int sessionId = _nextSessionId++;
    final LinuxCaptureSession session = LinuxCaptureSession(
      sessionId: sessionId,
      request: request,
      target: target,
      runner: _runner,
      recordingSinkFactory: _recordingSinkFactory,
      stallTimeout: _stallTimeout,
    );
    _captures[sessionId] = session;
    session.emitPrepared();
    return session.info;
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) =>
      _captures[sessionId]?.events ??
      const Stream<PlatformAudioSessionEvent>.empty();

  @override
  Future<void> startCapture(int sessionId) => _capture(sessionId).start();

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) => _capture(sessionId).read(maxFrames: maxFrames, timeout: timeout);

  @override
  Future<void> stopCapture(int sessionId) => _capture(sessionId).stop();

  @override
  Future<void> abortCapture(int sessionId) => _capture(sessionId).abort();

  @override
  Future<void> disposeCapture(int sessionId) async {
    final LinuxCaptureSession? session = _captures.remove(sessionId);
    await session?.dispose();
  }

  /// True when a capture tool and `pactl` are both installed.
  ///
  /// Monitor capture needs `pactl` to resolve the default sink, so a host with
  /// `parecord` but no `pactl` cannot reliably target system audio.
  @override
  Future<bool> isSystemAudioCaptureSupported() async {
    final bool hasRecorder =
        await _runner.exists(LinuxAudioTools.parecord) ||
        await _runner.exists(LinuxAudioTools.pwRecord);
    if (!hasRecorder) {
      return false;
    }
    return _runner.exists(LinuxAudioTools.pactl);
  }

  /// Linux has no system-audio permission gate: monitor sources are readable
  /// by any client of the running sound server. This reports whether the
  /// mechanism exists, never a user grant.
  @override
  Future<bool> requestSystemAudioCapturePermission() =>
      isSystemAudioCaptureSupported();

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async {
    final List<PulseSource> sources = await _listSources();
    final String? defaultSource = await _defaultSourceName();
    return sources
        .where((PulseSource source) => !source.isMonitor)
        .map(
          (PulseSource source) => PlatformAudioInputDevice(
            id: source.name,
            label: source.description,
            isDefault: source.name == defaultSource,
          ),
        )
        .toList(growable: false);
  }

  /// Monitor sources available for system-audio capture, in the same shape as
  /// [listAudioInputDevices] so callers can offer them for selection.
  ///
  /// Not part of the platform contract: Linux has no per-process capture, so
  /// this is the Linux answer to "what can system capture target".
  Future<List<PlatformAudioInputDevice>> listSystemAudioSources() async {
    final List<PulseSource> sources = await _listSources();
    final String? defaultMonitor = await _defaultMonitorName();
    return sources
        .where((PulseSource source) => source.isMonitor)
        .map(
          (PulseSource source) => PlatformAudioInputDevice(
            id: source.name,
            label: source.description,
            isDefault: source.name == defaultMonitor,
          ),
        )
        .toList(growable: false);
  }

  /// Always empty: PulseAudio monitors mix a sink, so there is no per-process
  /// tap equivalent to the Core Audio process list.
  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async =>
      const <PlatformAudioProcess>[];

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async {
    validatePlaybackFormat(request.inputFormat);
    final int sessionId = _nextSessionId++;
    final LinuxPlaybackSession session = LinuxPlaybackSession(
      sessionId: sessionId,
      request: request,
      runner: _runner,
    );
    _playbacks[sessionId] = session;
    session.emitPrepared();
    return session.info;
  }

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) =>
      _playbacks[sessionId]?.events ??
      const Stream<PlatformAudioSessionEvent>.empty();

  @override
  Future<void> startPlayback(int sessionId) => _playback(sessionId).start();

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) => _playback(sessionId).write(frames);

  @override
  Future<void> finishPlayback(int sessionId) => _playback(sessionId).finish();

  @override
  Future<void> abortPlayback(int sessionId) => _playback(sessionId).abort();

  @override
  Future<void> disposePlayback(int sessionId) async {
    final LinuxPlaybackSession? session = _playbacks.remove(sessionId);
    await session?.dispose();
  }

  Future<String?> _resolveCaptureTarget(PlatformCaptureRequest request) async {
    final String? requested = request.inputDeviceId;
    if (requested != null && requested.isNotEmpty) {
      return requested;
    }
    return switch (request.kind) {
      // Null lets parecord/pw-record pick the server default input.
      PlatformCaptureKind.microphone => null,
      PlatformCaptureKind.systemAudio => _defaultMonitorName(),
    };
  }

  Future<List<PulseSource>> _listSources() async {
    final String output = await _pactl(<String>['list', 'sources', 'short']);
    return parseSourcesShort(output);
  }

  Future<String?> _defaultMonitorName() async {
    final String output = await _pactl(<String>['get-default-sink']);
    return defaultSinkMonitor(output);
  }

  Future<String?> _defaultSourceName() async {
    final String output = await _pactl(<String>['get-default-source']);
    final String trimmed = output.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Runs `pactl`, treating any failure as "no information available" so
  /// enumeration degrades instead of throwing on a host without PulseAudio.
  Future<String> _pactl(List<String> arguments) async {
    try {
      final LinuxProcessResult result = await _runner.run(
        LinuxAudioTools.pactl,
        arguments,
      );
      return result.exitCode == 0 ? result.stdout : '';
    } on Object {
      return '';
    }
  }

  LinuxCaptureSession _capture(int sessionId) {
    final LinuxCaptureSession? session = _captures[sessionId];
    if (session == null) {
      throw StateError('SessionNotFound: no capture session $sessionId');
    }
    return session;
  }

  LinuxPlaybackSession _playback(int sessionId) {
    final LinuxPlaybackSession? session = _playbacks[sessionId];
    if (session == null) {
      throw StateError('SessionNotFound: no playback session $sessionId');
    }
    return session;
  }
}
