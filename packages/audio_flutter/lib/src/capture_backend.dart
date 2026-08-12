import 'dart:convert';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart'
    as federated;

import 'capture.dart';
import 'process_selector.dart';
import 'system_audio.dart';

/// Normalized [CaptureBackend] implemented by the active federated plugin.
///
/// Construct it with [create] so the synchronous core descriptor is populated
/// from capability-checked platform facts. Probes are single-use grants: a
/// start must present the exact request/source pair that was probed and the
/// source is revalidated immediately before native allocation.
final class FlutterCaptureBackend implements CaptureBackend {
  FlutterCaptureBackend._({
    required this._platform,
    required this.descriptor,
    required this._probeLifetime,
  }) {
    _probeClock.start();
  }

  /// Opens the normalized adapter for [platform], or the registered platform.
  ///
  /// Ready probes remain valid for [probeLifetime] and are always consumed by
  /// their first start attempt, successful or not.
  static Future<FlutterCaptureBackend> create({
    federated.AudioFlutterPlatform? platform,
    AudioCancellationToken? cancellationToken,
    Duration probeLifetime = const Duration(minutes: 5),
  }) async {
    if (probeLifetime <= Duration.zero) {
      throw ArgumentError.value(
        probeLifetime,
        'probeLifetime',
        'Must be positive.',
      );
    }
    cancellationToken?.throwIfCancelled();
    final federated.AudioFlutterPlatform resolved =
        platform ?? federated.AudioFlutterPlatform.instance;
    final federated.PlatformCaptureBackendInfo info;
    try {
      info = await resolved.captureBackendInfo();
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _captureBackendFailure(
          error,
          code: 'platform_capture_backend_probe_failed',
          message: 'The platform capture backend could not be identified.',
        ),
        stackTrace,
      );
    }
    cancellationToken?.throwIfCancelled();
    return FlutterCaptureBackend._(
      platform: resolved,
      probeLifetime: probeLifetime,
      descriptor: CaptureBackendDescriptor(
        backendId: info.backendId,
        displayName: info.displayName,
        platform: info.platform,
        sourceKinds: info.sourceKinds.map(_captureSourceKind).toSet(),
        capabilities: info.capabilities.map(_captureCapability).toSet(),
      ),
    );
  }

  final federated.AudioFlutterPlatform _platform;
  final Duration _probeLifetime;
  final Stopwatch _probeClock = Stopwatch();
  final Map<String, _AuthorizedProbe> _probes = <String, _AuthorizedProbe>{};
  var _nextProbeId = 1;

  @override
  final CaptureBackendDescriptor descriptor;

  @override
  Future<List<CaptureSourceDescriptor>> enumerateSources({
    AudioCancellationToken? cancellationToken,
  }) async {
    _expireProbes();
    final List<federated.PlatformCaptureSourceInfo> sources =
        await _platformSources(cancellationToken);
    return sources
        .map(
          (federated.PlatformCaptureSourceInfo source) =>
              _captureSourceDescriptor(source, descriptor.backendId),
        )
        .toList(growable: false);
  }

  @override
  Future<CaptureProbeResult> probe(
    CaptureProbeRequest request, {
    AudioCancellationToken? cancellationToken,
  }) async {
    final List<federated.PlatformCaptureSourceInfo> sources =
        await _platformSources(cancellationToken);
    final federated.PlatformCaptureSourceInfo? source = _sourceWithId(
      sources,
      request.sourceId,
    );
    final String probeId = _newProbeId();
    if (source == null) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_source_not_found',
        message: 'The requested capture source is no longer available.',
      );
    }

    switch (source.availability) {
      case federated.PlatformCaptureSourceAvailability.permissionRequired:
        return _blockedProbe(
          probeId: probeId,
          request: request,
          status: CaptureProbeStatus.permissionRequired,
          reasonCode: source.availabilityCode ?? 'capture_permission_required',
          message:
              source.availabilityReason ??
              'The requested capture source needs permission.',
        );
      case federated.PlatformCaptureSourceAvailability.unavailable:
        return _blockedProbe(
          probeId: probeId,
          request: request,
          status: CaptureProbeStatus.unavailable,
          reasonCode: source.availabilityCode ?? 'capture_source_unavailable',
          message:
              source.availabilityReason ??
              'The requested capture source is unavailable.',
        );
      case federated.PlatformCaptureSourceAvailability.available:
        break;
    }

    final int sampleRate = request.outputFormat.sampleRate;
    if ((source.supportedSampleRates.isNotEmpty &&
            !source.supportedSampleRates.contains(sampleRate)) ||
        (source.minimumSampleRate != null &&
            sampleRate < source.minimumSampleRate!) ||
        (source.maximumSampleRate != null &&
            sampleRate > source.maximumSampleRate!)) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_sample_rate_unsupported',
        message: 'The source does not support the requested sample rate.',
      );
    }
    final int channelCount = request.outputFormat.channels;
    if ((source.supportedChannelCounts.isNotEmpty &&
            !source.supportedChannelCounts.contains(channelCount)) ||
        (source.minimumChannelCount != null &&
            channelCount < source.minimumChannelCount!) ||
        (source.maximumChannelCount != null &&
            channelCount > source.maximumChannelCount!)) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_channel_count_unsupported',
        message: 'The source does not support the requested channel count.',
      );
    }
    if (request.outputFormat.framesForDuration(request.frameDuration) < 1) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_frame_duration_unsupported',
        message: 'The frame duration contains no complete sample frame.',
      );
    }

    if (request.processIds.isNotEmpty &&
        !source.capabilities.contains(
          federated.PlatformCaptureCapability.processFiltering,
        )) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_process_filtering_unsupported',
        message: 'The selected source cannot filter individual processes.',
      );
    }
    final List<int> effectiveProcessIds = request.processIds.isNotEmpty
        ? request.processIds
        : source.processIds;
    if (request.processIds.isNotEmpty &&
        source.processIds.any(
          (int processId) => !request.processIds.contains(processId),
        )) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_process_selection_mismatch',
        message: 'The requested process set does not include the source.',
      );
    }
    if ((source.kind == federated.PlatformCaptureSourceKind.application ||
            source.kind == federated.PlatformCaptureSourceKind.browser) &&
        effectiveProcessIds.isEmpty) {
      return _blockedProbe(
        probeId: probeId,
        request: request,
        status: CaptureProbeStatus.unavailable,
        reasonCode: 'capture_process_selection_empty',
        message: 'The selected application source has no active process.',
      );
    }

    _probes[probeId] = _AuthorizedProbe(
      requestFingerprint: _requestFingerprint(request),
      sourceId: source.sourceId,
      processIds: List<int>.unmodifiable(effectiveProcessIds),
      bundleIds: _probeBundleIds(sources, source, effectiveProcessIds),
      createdAt: _probeClock.elapsed,
    );
    return CaptureProbeResult(
      probeId: probeId,
      requestId: request.requestId,
      backendId: descriptor.backendId,
      requestedSourceId: request.sourceId,
      status: CaptureProbeStatus.ready,
      resolvedSourceId: source.sourceId,
    );
  }

  @override
  Future<AudioSourceSession> start(
    CaptureStartRequest request, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final _AuthorizedProbe? authorization = _probes.remove(request.probeId);
    if (authorization == null) {
      throw StateError('The capture probe is stale or was already consumed.');
    }
    if (_probeClock.elapsed - authorization.createdAt > _probeLifetime) {
      throw StateError('The capture probe has expired.');
    }
    if (authorization.sourceId != request.selectedSourceId ||
        request.selectedSourceId != request.request.sourceId ||
        authorization.requestFingerprint !=
            _requestFingerprint(request.request)) {
      throw StateError('The start request does not match the capture probe.');
    }
    if (request.fallbackConfirmation != null) {
      throw StateError('This backend did not propose a capture fallback.');
    }

    final List<federated.PlatformCaptureSourceInfo> sources =
        await _platformSources(cancellationToken);
    final federated.PlatformCaptureSourceInfo? source = _sourceWithId(
      sources,
      request.selectedSourceId,
    );
    if (source == null ||
        source.availability !=
            federated.PlatformCaptureSourceAvailability.available) {
      throw StateError(
        'The capture source changed availability after it was probed.',
      );
    }
    if (authorization.processIds.isNotEmpty &&
        !source.capabilities.contains(
          federated.PlatformCaptureCapability.processFiltering,
        )) {
      throw StateError('The capture source lost process-filtering support.');
    }
    if (source.processIds.any(
      (int processId) => !authorization.processIds.contains(processId),
    )) {
      throw StateError('The capture source no longer matches the process set.');
    }
    cancellationToken?.throwIfCancelled();

    final FlutterAudioCaptureSource capture = FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: switch (source.captureKind) {
          federated.PlatformCaptureKind.microphone =>
            AudioCaptureType.microphone,
          federated.PlatformCaptureKind.systemAudio =>
            AudioCaptureType.systemAudio,
        },
        format: request.request.outputFormat,
        frameDuration: request.request.frameDuration,
        maxBufferedDuration: request.request.maxBufferedDuration,
        overflowPolicy: switch (request.request.overflowPolicy) {
          CaptureOverflowPolicy.dropOldest =>
            AudioCaptureOverflowPolicy.dropOldest,
          CaptureOverflowPolicy.dropNewest =>
            AudioCaptureOverflowPolicy.dropNewest,
          CaptureOverflowPolicy.failCapture =>
            AudioCaptureOverflowPolicy.failCapture,
        },
        processIds: authorization.processIds,
        bundleIds: authorization.bundleIds,
        inputDeviceId: source.inputDeviceId,
        logicalSourceId: source.sourceId,
        timingQuality: _timingQuality(source.timingQuality),
      ),
      platform: _platform,
    );
    return capture.prepare(cancellationToken: cancellationToken);
  }

  Future<List<federated.PlatformCaptureSourceInfo>> _platformSources(
    AudioCancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    final List<federated.PlatformCaptureSourceInfo> sources;
    try {
      sources = await _platform.listCaptureSources();
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _captureBackendFailure(
          error,
          code: 'platform_capture_source_enumeration_failed',
          message: 'Capture sources could not be enumerated.',
          providerId: descriptor.backendId,
        ),
        stackTrace,
      );
    }
    cancellationToken?.throwIfCancelled();
    final Set<String> sourceIds = <String>{};
    for (final federated.PlatformCaptureSourceInfo source in sources) {
      if (source.sourceId.trim().isEmpty || !sourceIds.add(source.sourceId)) {
        throw AudioFailure(
          code: 'platform_capture_sources_invalid',
          stage: AudioFailureStage.capture,
          message: 'The platform returned empty or duplicate source IDs.',
          providerId: descriptor.backendId,
          retryable: false,
        );
      }
    }
    return sources;
  }

  String _newProbeId() => '${descriptor.backendId}.probe.${_nextProbeId++}';

  void _expireProbes() {
    final Duration now = _probeClock.elapsed;
    _probes.removeWhere(
      (String _, _AuthorizedProbe probe) =>
          now - probe.createdAt > _probeLifetime,
    );
  }

  CaptureProbeResult _blockedProbe({
    required String probeId,
    required CaptureProbeRequest request,
    required CaptureProbeStatus status,
    required String reasonCode,
    required String message,
  }) => CaptureProbeResult(
    probeId: probeId,
    requestId: request.requestId,
    backendId: descriptor.backendId,
    requestedSourceId: request.sourceId,
    status: status,
    reasonCode: reasonCode,
    message: message,
  );
}

final class _AuthorizedProbe {
  const _AuthorizedProbe({
    required this.requestFingerprint,
    required this.sourceId,
    required this.processIds,
    required this.bundleIds,
    required this.createdAt,
  });

  final String requestFingerprint;
  final String sourceId;
  final List<int> processIds;
  final List<String> bundleIds;
  final Duration createdAt;
}

/// The application identity behind a probed source, when it has one.
///
/// Carried alongside the authorized process set rather than replacing it: the
/// process IDs are what a platform without identity-based capture uses, while
/// a platform that can tap an application (macOS 26 and newer) keeps following
/// it through helper respawns and app restarts. Sources that cannot filter by
/// application, such as a whole-system mix, contribute nothing here.
List<String> _sourceBundleIds(federated.PlatformCaptureSourceInfo source) {
  final String? applicationId = source.applicationId;
  if (applicationId == null ||
      !source.capabilities.contains(
        federated.PlatformCaptureCapability.applicationFiltering,
      )) {
    return const <String>[];
  }
  return List<String>.unmodifiable(<String>[applicationId]);
}

/// Application identities behind the whole authorized process set.
///
/// The authorized PIDs can span several enumerated sources — a helper family
/// the host grouped into one selection — so every source whose processes are
/// part of the authorization contributes its identity, not just the
/// representative. The selector then widens the set with the family and
/// external-media namespaces those applications render audio through, so an
/// identity-based tap follows the same processes the PID set names.
List<String> _probeBundleIds(
  List<federated.PlatformCaptureSourceInfo> sources,
  federated.PlatformCaptureSourceInfo representative,
  List<int> effectiveProcessIds,
) {
  final Set<String> collected = <String>{
    ..._sourceBundleIds(representative),
    for (final federated.PlatformCaptureSourceInfo source in sources)
      if (source.processIds.any(effectiveProcessIds.contains))
        ..._sourceBundleIds(source),
  };
  if (collected.isEmpty) {
    return const <String>[];
  }
  return const SystemAudioProcessSelector().expandBundleIds(
    processes: const <AudioCaptureProcess>[],
    bundleIds: collected,
  );
}

String _requestFingerprint(CaptureProbeRequest request) =>
    jsonEncode(request.toJson());

federated.PlatformCaptureSourceInfo? _sourceWithId(
  List<federated.PlatformCaptureSourceInfo> sources,
  String sourceId,
) {
  for (final federated.PlatformCaptureSourceInfo source in sources) {
    if (source.sourceId == sourceId) {
      return source;
    }
  }
  return null;
}

CaptureSourceDescriptor _captureSourceDescriptor(
  federated.PlatformCaptureSourceInfo source,
  String backendId,
) => CaptureSourceDescriptor(
  sourceId: source.sourceId,
  backendId: backendId,
  kind: _captureSourceKind(source.kind),
  displayName: source.displayName,
  availability: _captureAvailability(source.availability),
  capabilities: source.capabilities.map(_captureCapability).toSet(),
  supportedSampleRates: source.supportedSampleRates,
  supportedChannelCounts: source.supportedChannelCounts,
  processIds: source.processIds,
  isDefault: source.isDefault,
  nativeSourceId: source.nativeSourceId,
  applicationId: source.applicationId,
  availabilityReason:
      source.availability ==
          federated.PlatformCaptureSourceAvailability.unavailable
      ? source.availabilityReason ?? 'The platform source is unavailable.'
      : source.availabilityReason,
);

CaptureSourceKind _captureSourceKind(
  federated.PlatformCaptureSourceKind kind,
) => switch (kind) {
  federated.PlatformCaptureSourceKind.microphone =>
    CaptureSourceKind.microphone,
  federated.PlatformCaptureSourceKind.application =>
    CaptureSourceKind.application,
  federated.PlatformCaptureSourceKind.browser => CaptureSourceKind.browser,
  federated.PlatformCaptureSourceKind.systemMix => CaptureSourceKind.systemMix,
  federated.PlatformCaptureSourceKind.pulseMonitor =>
    CaptureSourceKind.pulseMonitor,
  federated.PlatformCaptureSourceKind.pipeWireMonitor =>
    CaptureSourceKind.pipeWireMonitor,
};

CaptureSourceAvailability _captureAvailability(
  federated.PlatformCaptureSourceAvailability availability,
) => switch (availability) {
  federated.PlatformCaptureSourceAvailability.available =>
    CaptureSourceAvailability.available,
  federated.PlatformCaptureSourceAvailability.permissionRequired =>
    CaptureSourceAvailability.permissionRequired,
  federated.PlatformCaptureSourceAvailability.unavailable =>
    CaptureSourceAvailability.unavailable,
};

CaptureCapability _captureCapability(
  federated.PlatformCaptureCapability capability,
) => switch (capability) {
  federated.PlatformCaptureCapability.processFiltering =>
    CaptureCapability.processFiltering,
  federated.PlatformCaptureCapability.applicationFiltering =>
    CaptureCapability.applicationFiltering,
  federated.PlatformCaptureCapability.browserGrouping =>
    CaptureCapability.browserGrouping,
  federated.PlatformCaptureCapability.systemMix => CaptureCapability.systemMix,
  federated.PlatformCaptureCapability.pauseResume =>
    CaptureCapability.pauseResume,
  federated.PlatformCaptureCapability.sourceChangeEvents =>
    CaptureCapability.sourceChangeEvents,
  federated.PlatformCaptureCapability.nativeMonotonicClock =>
    CaptureCapability.nativeMonotonicClock,
  federated.PlatformCaptureCapability.independentTracks =>
    CaptureCapability.independentTracks,
};

MonotonicTrackTimingQuality _timingQuality(
  federated.PlatformCaptureTimingQuality quality,
) => switch (quality) {
  federated.PlatformCaptureTimingQuality.nativeMapped =>
    MonotonicTrackTimingQuality.nativeMapped,
  federated.PlatformCaptureTimingQuality.synchronized =>
    MonotonicTrackTimingQuality.synchronized,
  federated.PlatformCaptureTimingQuality.synthesized =>
    MonotonicTrackTimingQuality.synthesized,
};

AudioFailure _captureBackendFailure(
  Object error, {
  required String code,
  required String message,
  String? providerId,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.capture,
        message: message,
        providerId: providerId,
        retryable: true,
        safeCause: error.runtimeType.toString(),
      );
