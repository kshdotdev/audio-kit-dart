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
/// Pulse-compatible servers also expose active render streams as sink inputs.
/// When `parecord` is installed, each stream carrying a local process ID is an
/// addressable application source through `--monitor-stream`. A process request
/// must select one of those exact sources; it is never widened to a monitor.
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

    final int? monitorStreamIndex = parsePulseMonitorStreamTarget(
      request.inputDeviceId,
    );
    if (request.processIds.isNotEmpty) {
      await _validateProcessCapture(request, monitorStreamIndex);
    } else if (monitorStreamIndex != null) {
      throw UnsupportedError(
        'InvalidProcessCapture: an application stream requires its exact '
        'process ID; re-enumerate capture sources before starting',
      );
    }
    final String? target = await _resolveCaptureTarget(request);
    if (request.kind == PlatformCaptureKind.systemAudio &&
        request.processIds.isEmpty &&
        (target == null || !target.endsWith('.monitor'))) {
      throw UnsupportedError(
        'SystemAudioSourceUnavailable: system audio requires an explicit '
        'sound-server monitor source; capture will not fall back to the '
        'default microphone',
      );
    }
    final int sessionId = _nextSessionId++;
    final LinuxCaptureSession session = LinuxCaptureSession(
      sessionId: sessionId,
      request: request,
      target: target,
      monitorStreamIndex: monitorStreamIndex,
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
  Future<void> startCapture(int sessionId) async {
    final LinuxCaptureSession session = _capture(sessionId);
    if (session.monitorStreamIndex != null) {
      // Sink-inputs are transient. Validate again at the actual allocation
      // boundary so a disappeared stream cannot turn into another source.
      await _validateProcessCapture(
        session.request,
        session.monitorStreamIndex,
      );
    }
    await session.start();
  }

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

  /// True when a capture tool, `pactl`, and a monitor source are available.
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
    if (!await _runner.exists(LinuxAudioTools.pactl)) {
      return false;
    }
    return (await _listSources()).any((PulseSource source) => source.isMonitor);
  }

  /// Linux has no system-audio permission gate: monitor sources are readable
  /// by any client of the running sound server. This reports whether the
  /// mechanism exists, never a user grant.
  @override
  Future<bool> requestSystemAudioCapturePermission() =>
      isSystemAudioCaptureSupported();

  @override
  Future<PlatformCaptureBackendInfo> captureBackendInfo() async {
    final bool hasRecorder = await _hasCaptureTool();
    final bool hasPactl = await _runner.exists(LinuxAudioTools.pactl);
    final List<PulseSource> monitors = hasPactl
        ? (await _listSources())
              .where((PulseSource source) => source.isMonitor)
              .toList(growable: false)
        : const <PulseSource>[];
    final bool hasPulseRecorder = await _runner.exists(
      LinuxAudioTools.parecord,
    );
    final List<PulseSinkInput> applicationStreams = hasPactl && hasPulseRecorder
        ? await _listSinkInputs()
        : const <PulseSinkInput>[];
    final bool hasApplications = applicationStreams.any(
      (PulseSinkInput stream) => stream.processId != null,
    );
    final bool hasBrowsers = applicationStreams.any(
      (PulseSinkInput stream) => stream.processId != null && stream.isBrowser,
    );
    final Set<PlatformCaptureSourceKind> sourceKinds =
        <PlatformCaptureSourceKind>{
          if (hasRecorder) PlatformCaptureSourceKind.microphone,
          if (hasApplications) PlatformCaptureSourceKind.application,
          if (hasBrowsers) PlatformCaptureSourceKind.browser,
          if (hasRecorder)
            for (final PulseSource monitor in monitors)
              monitor.isPipeWire
                  ? PlatformCaptureSourceKind.pipeWireMonitor
                  : PlatformCaptureSourceKind.pulseMonitor,
        };
    return PlatformCaptureBackendInfo(
      backendId: 'audio_flutter.linux.sound-server',
      displayName: 'Linux PulseAudio/PipeWire capture',
      platform: 'linux',
      sourceKinds: sourceKinds,
      capabilities: <PlatformCaptureCapability>{
        if (hasRecorder && monitors.isNotEmpty)
          PlatformCaptureCapability.systemMix,
        if (hasApplications) ...<PlatformCaptureCapability>{
          PlatformCaptureCapability.processFiltering,
          PlatformCaptureCapability.applicationFiltering,
        },
      },
    );
  }

  @override
  Future<List<PlatformCaptureSourceInfo>> listCaptureSources() async {
    final bool hasRecorder = await _hasCaptureTool();
    final bool hasPactl = await _runner.exists(LinuxAudioTools.pactl);
    final bool hasPulseRecorder = await _runner.exists(
      LinuxAudioTools.parecord,
    );
    final List<PulseSource> sources = hasPactl
        ? await _listSources()
        : const <PulseSource>[];
    final List<PulseSource> inputs = sources
        .where((PulseSource source) => !source.isMonitor)
        .toList(growable: false);
    final List<PulseSource> monitors = sources
        .where((PulseSource source) => source.isMonitor)
        .toList(growable: false);
    final String? defaultSource = hasPactl ? await _defaultSourceName() : null;
    final String? defaultMonitor = hasPactl
        ? await _defaultMonitorName()
        : null;
    final List<PulseSinkInput> applicationStreams = hasPactl && hasPulseRecorder
        ? (await _listSinkInputs())
              .where((PulseSinkInput stream) => stream.processId != null)
              .toList(growable: false)
        : const <PulseSinkInput>[];
    final String unavailableCode = !hasRecorder
        ? 'linux_capture_tool_unavailable'
        : !hasPactl
        ? 'linux_pactl_unavailable'
        : 'linux_monitor_unavailable';
    final String unavailableReason = !hasRecorder
        ? 'Neither parecord nor pw-record is available on PATH.'
        : !hasPactl
        ? 'pactl is required to discover sound-server monitor sources.'
        : 'The sound server exposes no monitor source.';

    return <PlatformCaptureSourceInfo>[
      if (inputs.isEmpty)
        PlatformCaptureSourceInfo(
          sourceId: hasRecorder
              ? 'linux.microphone.default'
              : 'linux.microphone.unavailable',
          kind: PlatformCaptureSourceKind.microphone,
          displayName: 'Default microphone',
          availability: hasRecorder
              ? PlatformCaptureSourceAvailability.available
              : PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.microphone,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          isDefault: true,
          maximumSampleRate: kLinuxMaximumSampleRate,
          maximumChannelCount: kLinuxMaximumChannelCount,
          availabilityCode: hasRecorder
              ? null
              : 'linux_capture_tool_unavailable',
          availabilityReason: hasRecorder
              ? null
              : 'Neither parecord nor pw-record is available on PATH.',
        )
      else
        for (final PulseSource input in inputs)
          PlatformCaptureSourceInfo(
            sourceId: 'linux.microphone.${Uri.encodeComponent(input.name)}',
            kind: PlatformCaptureSourceKind.microphone,
            displayName: input.description,
            availability: hasRecorder
                ? PlatformCaptureSourceAvailability.available
                : PlatformCaptureSourceAvailability.unavailable,
            captureKind: PlatformCaptureKind.microphone,
            timingQuality: PlatformCaptureTimingQuality.synthesized,
            maximumSampleRate: kLinuxMaximumSampleRate,
            maximumChannelCount: kLinuxMaximumChannelCount,
            isDefault: input.name == defaultSource,
            nativeSourceId: input.name,
            inputDeviceId: input.name,
            availabilityCode: hasRecorder
                ? null
                : 'linux_capture_tool_unavailable',
            availabilityReason: hasRecorder
                ? null
                : 'Neither parecord nor pw-record is available on PATH.',
          ),
      if (hasRecorder && hasPactl && monitors.isNotEmpty)
        for (final PulseSource monitor in monitors)
          PlatformCaptureSourceInfo(
            sourceId:
                'linux.${monitor.isPipeWire ? 'pipewire' : 'pulse'}.monitor.'
                '${Uri.encodeComponent(monitor.name)}',
            kind: monitor.isPipeWire
                ? PlatformCaptureSourceKind.pipeWireMonitor
                : PlatformCaptureSourceKind.pulseMonitor,
            displayName: monitor.description,
            availability: PlatformCaptureSourceAvailability.available,
            captureKind: PlatformCaptureKind.systemAudio,
            timingQuality: PlatformCaptureTimingQuality.synthesized,
            capabilities: const <PlatformCaptureCapability>{
              PlatformCaptureCapability.systemMix,
            },
            maximumSampleRate: kLinuxMaximumSampleRate,
            maximumChannelCount: kLinuxMaximumChannelCount,
            isDefault: monitor.name == defaultMonitor,
            nativeSourceId: monitor.name,
            inputDeviceId: monitor.name,
          )
      else ...<PlatformCaptureSourceInfo>[
        PlatformCaptureSourceInfo(
          sourceId: 'linux.pulse.monitor.unavailable',
          kind: PlatformCaptureSourceKind.pulseMonitor,
          displayName: 'PulseAudio monitor',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          capabilities: const <PlatformCaptureCapability>{
            PlatformCaptureCapability.systemMix,
          },
          availabilityCode: unavailableCode,
          availabilityReason: unavailableReason,
        ),
        PlatformCaptureSourceInfo(
          sourceId: 'linux.pipewire.monitor.unavailable',
          kind: PlatformCaptureSourceKind.pipeWireMonitor,
          displayName: 'PipeWire monitor',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          capabilities: const <PlatformCaptureCapability>{
            PlatformCaptureCapability.systemMix,
          },
          availabilityCode: unavailableCode,
          availabilityReason: unavailableReason,
        ),
      ],
      for (final PulseSinkInput stream in applicationStreams)
        PlatformCaptureSourceInfo(
          sourceId:
              'linux.${stream.isBrowser ? 'browser' : 'application'}.'
              '${stream.index}',
          kind: stream.isBrowser
              ? PlatformCaptureSourceKind.browser
              : PlatformCaptureSourceKind.application,
          displayName: stream.displayName,
          availability: PlatformCaptureSourceAvailability.available,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          capabilities: const <PlatformCaptureCapability>{
            PlatformCaptureCapability.processFiltering,
            PlatformCaptureCapability.applicationFiltering,
          },
          maximumSampleRate: kLinuxMaximumSampleRate,
          maximumChannelCount: kLinuxMaximumChannelCount,
          processIds: <int>[stream.processId!],
          nativeSourceId: '${stream.index}',
          applicationId: stream.applicationId,
          inputDeviceId: pulseMonitorStreamTarget(stream.index),
        ),
      if (!applicationStreams.any((PulseSinkInput stream) => !stream.isBrowser))
        PlatformCaptureSourceInfo(
          sourceId: 'linux.application.unavailable',
          kind: PlatformCaptureSourceKind.application,
          displayName: 'Application audio',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          availabilityCode: _applicationUnavailableCode(
            hasPactl: hasPactl,
            hasPulseRecorder: hasPulseRecorder,
          ),
          availabilityReason: _applicationUnavailableReason(
            hasPactl: hasPactl,
            hasPulseRecorder: hasPulseRecorder,
          ),
        ),
      if (!applicationStreams.any((PulseSinkInput stream) => stream.isBrowser))
        PlatformCaptureSourceInfo(
          sourceId: 'linux.browser.unavailable',
          kind: PlatformCaptureSourceKind.browser,
          displayName: 'Browser audio',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.synthesized,
          availabilityCode: _applicationUnavailableCode(
            hasPactl: hasPactl,
            hasPulseRecorder: hasPulseRecorder,
          ),
          availabilityReason: hasPactl && hasPulseRecorder
              ? 'No active browser render stream exposes a local process ID.'
              : _applicationUnavailableReason(
                  hasPactl: hasPactl,
                  hasPulseRecorder: hasPulseRecorder,
                ),
        ),
    ];
  }

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
  /// Not part of the platform contract: this is the Linux answer to "what can
  /// system-mix capture target"; addressable application streams are exposed
  /// separately by [listCaptureSources].
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

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async {
    if (!await _runner.exists(LinuxAudioTools.pactl)) {
      return const <PlatformAudioProcess>[];
    }
    final Map<int, PlatformAudioProcess> processes =
        <int, PlatformAudioProcess>{};
    for (final PulseSinkInput stream in await _listSinkInputs()) {
      final int? processId = stream.processId;
      if (processId == null) {
        continue;
      }
      final PlatformAudioProcess? existing = processes[processId];
      processes[processId] = PlatformAudioProcess(
        processId: processId,
        bundleId: stream.applicationId,
        isProducingAudio:
            (existing?.isProducingAudio ?? false) || !stream.corked,
      );
    }
    final List<PlatformAudioProcess> result = processes.values.toList()
      ..sort(
        (PlatformAudioProcess left, PlatformAudioProcess right) =>
            left.processId.compareTo(right.processId),
      );
    return result;
  }

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
      return parsePulseMonitorStreamTarget(requested) == null
          ? requested
          : null;
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

  Future<List<PulseSinkInput>> _listSinkInputs() async {
    final String output = await _pactl(<String>[
      '--format=json',
      'list',
      'sink-inputs',
    ]);
    return parseSinkInputsJson(output);
  }

  Future<void> _validateProcessCapture(
    PlatformCaptureRequest request,
    int? monitorStreamIndex,
  ) async {
    if (request.kind != PlatformCaptureKind.systemAudio ||
        monitorStreamIndex == null) {
      throw UnsupportedError(
        'UnsupportedProcessCapture: select an addressable application source; '
        'a process ID is never widened to a monitor mix',
      );
    }
    if (!await _runner.exists(LinuxAudioTools.parecord)) {
      throw UnsupportedError(
        'UnsupportedProcessCapture: parecord with --monitor-stream is required '
        'for isolated application capture',
      );
    }
    final PulseSinkInput? stream = (await _listSinkInputs())
        .where(
          (PulseSinkInput candidate) => candidate.index == monitorStreamIndex,
        )
        .firstOrNull;
    if (stream == null || stream.processId == null) {
      throw StateError(
        'ProcessCaptureSourceExpired: the selected render stream is no longer '
        'addressable; re-enumerate sources',
      );
    }
    if (request.processIds.length != 1 ||
        request.processIds.single != stream.processId) {
      throw UnsupportedError(
        'UnsupportedProcessSet: this sound-server source represents exactly '
        'process ${stream.processId}; select separate addressable streams for '
        'additional processes',
      );
    }
  }

  Future<bool> _hasCaptureTool() async =>
      await _runner.exists(LinuxAudioTools.parecord) ||
      await _runner.exists(LinuxAudioTools.pwRecord);

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

String _applicationUnavailableCode({
  required bool hasPactl,
  required bool hasPulseRecorder,
}) => !hasPactl
    ? 'linux_pactl_unavailable'
    : !hasPulseRecorder
    ? 'linux_parecord_monitor_stream_unavailable'
    : 'linux_addressable_stream_unavailable';

String _applicationUnavailableReason({
  required bool hasPactl,
  required bool hasPulseRecorder,
}) => !hasPactl
    ? 'pactl is required to discover addressable application render streams.'
    : !hasPulseRecorder
    ? 'parecord is required because pw-record cannot select a Pulse sink input.'
    : 'No active application render stream exposes a local process ID.';
