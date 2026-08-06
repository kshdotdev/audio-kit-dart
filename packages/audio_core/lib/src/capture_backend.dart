import 'cancellation.dart';
import 'format.dart';
import 'session.dart';

/// Normalized category of a capturable source.
enum CaptureSourceKind {
  microphone,
  application,
  browser,
  systemMix,
  pulseMonitor,
  pipeWireMonitor,
}

/// Whether a backend can currently open a source.
enum CaptureSourceAvailability { available, permissionRequired, unavailable }

/// Independently probeable capture behavior.
enum CaptureCapability {
  processFiltering,
  applicationFiltering,
  browserGrouping,
  systemMix,
  pauseResume,
  sourceChangeEvents,
  nativeMonotonicClock,
  independentTracks,
}

/// Native callback overflow behavior before frames reach the Dart graph.
enum CaptureOverflowPolicy { dropOldest, dropNewest, failCapture }

/// Whether a backend may propose a degraded source selection.
enum CaptureFallbackPolicy {
  /// Never select anything other than the requested source.
  forbid,

  /// A backend may propose a fallback, but cannot start it without a matching
  /// [CaptureFallbackConfirmation].
  requireExplicitConfirmation,
}

/// Stable description of one capture backend adapter.
final class CaptureBackendDescriptor {
  CaptureBackendDescriptor({
    required this.backendId,
    required this.displayName,
    required this.platform,
    required Set<CaptureSourceKind> sourceKinds,
    Set<CaptureCapability> capabilities = const <CaptureCapability>{},
  }) : sourceKinds = Set<CaptureSourceKind>.unmodifiable(sourceKinds),
       capabilities = Set<CaptureCapability>.unmodifiable(capabilities) {
    _requireCaptureIdentifier(backendId, 'backendId');
    _requireCaptureIdentifier(displayName, 'displayName');
    _requireCaptureIdentifier(platform, 'platform');
  }

  factory CaptureBackendDescriptor.fromJson(Map<String, Object?> json) {
    return CaptureBackendDescriptor(
      backendId: _captureRequiredString(json, 'backendId'),
      displayName: _captureRequiredString(json, 'displayName'),
      platform: _captureRequiredString(json, 'platform'),
      sourceKinds: _captureEnumSet(
        CaptureSourceKind.values,
        json['sourceKinds'],
        'sourceKinds',
      ),
      capabilities: _captureEnumSet(
        CaptureCapability.values,
        json['capabilities'],
        'capabilities',
      ),
    );
  }

  final String backendId;
  final String displayName;
  final String platform;
  final Set<CaptureSourceKind> sourceKinds;
  final Set<CaptureCapability> capabilities;

  Map<String, Object?> toJson() => <String, Object?>{
    'backendId': backendId,
    'displayName': displayName,
    'platform': platform,
    'sourceKinds': _orderedEnumNames(CaptureSourceKind.values, sourceKinds),
    'capabilities': _orderedEnumNames(CaptureCapability.values, capabilities),
  };
}

/// Normalized source returned by [CaptureBackend.enumerateSources].
final class CaptureSourceDescriptor {
  CaptureSourceDescriptor({
    required this.sourceId,
    required this.backendId,
    required this.kind,
    required this.displayName,
    required this.availability,
    Set<CaptureCapability> capabilities = const <CaptureCapability>{},
    List<int> supportedSampleRates = const <int>[],
    List<int> supportedChannelCounts = const <int>[],
    List<int> processIds = const <int>[],
    this.isDefault = false,
    this.nativeSourceId,
    this.applicationId,
    this.availabilityReason,
  }) : capabilities = Set<CaptureCapability>.unmodifiable(capabilities),
       supportedSampleRates = List<int>.unmodifiable(
         _sortedUniquePositive(supportedSampleRates, 'supportedSampleRates'),
       ),
       supportedChannelCounts = List<int>.unmodifiable(
         _sortedUniquePositive(
           supportedChannelCounts,
           'supportedChannelCounts',
         ),
       ),
       processIds = List<int>.unmodifiable(
         _sortedUniquePositive(processIds, 'processIds'),
       ) {
    _requireCaptureIdentifier(sourceId, 'sourceId');
    _requireCaptureIdentifier(backendId, 'backendId');
    _requireCaptureIdentifier(displayName, 'displayName');
    _requireCaptureOptionalText(nativeSourceId, 'nativeSourceId');
    _requireCaptureOptionalText(applicationId, 'applicationId');
    _requireCaptureOptionalText(availabilityReason, 'availabilityReason');
    if (availability == CaptureSourceAvailability.unavailable &&
        availabilityReason == null) {
      throw ArgumentError(
        'An unavailable capture source must explain why it is unavailable.',
      );
    }
  }

  factory CaptureSourceDescriptor.fromJson(Map<String, Object?> json) {
    return CaptureSourceDescriptor(
      sourceId: _captureRequiredString(json, 'sourceId'),
      backendId: _captureRequiredString(json, 'backendId'),
      kind: _captureEnumByName(
        CaptureSourceKind.values,
        _captureRequiredString(json, 'kind'),
        'kind',
      ),
      displayName: _captureRequiredString(json, 'displayName'),
      availability: _captureEnumByName(
        CaptureSourceAvailability.values,
        _captureRequiredString(json, 'availability'),
        'availability',
      ),
      capabilities: _captureEnumSet(
        CaptureCapability.values,
        json['capabilities'],
        'capabilities',
      ),
      supportedSampleRates: _captureIntList(json, 'supportedSampleRates'),
      supportedChannelCounts: _captureIntList(json, 'supportedChannelCounts'),
      processIds: _captureIntList(json, 'processIds'),
      isDefault: json['isDefault'] == true,
      nativeSourceId: _captureOptionalString(json, 'nativeSourceId'),
      applicationId: _captureOptionalString(json, 'applicationId'),
      availabilityReason: _captureOptionalString(json, 'availabilityReason'),
    );
  }

  final String sourceId;
  final String backendId;
  final CaptureSourceKind kind;
  final String displayName;
  final CaptureSourceAvailability availability;
  final Set<CaptureCapability> capabilities;
  final List<int> supportedSampleRates;
  final List<int> supportedChannelCounts;
  final List<int> processIds;
  final bool isDefault;
  final String? nativeSourceId;
  final String? applicationId;
  final String? availabilityReason;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'backendId': backendId,
    'kind': kind.name,
    'displayName': displayName,
    'availability': availability.name,
    'capabilities': _orderedEnumNames(CaptureCapability.values, capabilities),
    'supportedSampleRates': supportedSampleRates,
    'supportedChannelCounts': supportedChannelCounts,
    'processIds': processIds,
    if (isDefault) 'isDefault': true,
    if (nativeSourceId != null) 'nativeSourceId': nativeSourceId,
    if (applicationId != null) 'applicationId': applicationId,
    if (availabilityReason != null) 'availabilityReason': availabilityReason,
  };
}

/// Provider-neutral configuration checked before capture allocation.
final class CaptureProbeRequest {
  CaptureProbeRequest({
    required this.requestId,
    required this.sourceId,
    required this.outputFormat,
    this.frameDuration = const Duration(milliseconds: 100),
    this.maxBufferedDuration = const Duration(seconds: 2),
    this.overflowPolicy = CaptureOverflowPolicy.failCapture,
    this.fallbackPolicy = CaptureFallbackPolicy.forbid,
    List<int> processIds = const <int>[],
  }) : processIds = List<int>.unmodifiable(
         _sortedUniquePositive(processIds, 'processIds'),
       ) {
    _requireCaptureIdentifier(requestId, 'requestId');
    _requireCaptureIdentifier(sourceId, 'sourceId');
    if (frameDuration <= Duration.zero) {
      throw ArgumentError.value(
        frameDuration,
        'frameDuration',
        'Must be positive.',
      );
    }
    if (maxBufferedDuration < frameDuration) {
      throw ArgumentError.value(
        maxBufferedDuration,
        'maxBufferedDuration',
        'Must hold at least one frame.',
      );
    }
  }

  factory CaptureProbeRequest.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> format = _captureRequiredMap(json, 'format');
    final String sampleFormat = _captureRequiredString(format, 'sampleFormat');
    if (sampleFormat != AudioSampleFormat.float32.name) {
      throw FormatException('Unsupported sample format: $sampleFormat.');
    }
    return CaptureProbeRequest(
      requestId: _captureRequiredString(json, 'requestId'),
      sourceId: _captureRequiredString(json, 'sourceId'),
      outputFormat: AudioFormat(
        sampleRate: _captureRequiredInt(format, 'sampleRate'),
        channels: _captureRequiredInt(format, 'channels'),
      ),
      frameDuration: Duration(
        microseconds: _captureRequiredInt(json, 'frameDurationMicroseconds'),
      ),
      maxBufferedDuration: Duration(
        microseconds: _captureRequiredInt(
          json,
          'maxBufferedDurationMicroseconds',
        ),
      ),
      overflowPolicy: _captureEnumByName(
        CaptureOverflowPolicy.values,
        _captureRequiredString(json, 'overflowPolicy'),
        'overflowPolicy',
      ),
      fallbackPolicy: _captureEnumByName(
        CaptureFallbackPolicy.values,
        _captureRequiredString(json, 'fallbackPolicy'),
        'fallbackPolicy',
      ),
      processIds: _captureIntList(json, 'processIds'),
    );
  }

  final String requestId;
  final String sourceId;
  final AudioFormat outputFormat;
  final Duration frameDuration;
  final Duration maxBufferedDuration;
  final CaptureOverflowPolicy overflowPolicy;
  final CaptureFallbackPolicy fallbackPolicy;
  final List<int> processIds;

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'sourceId': sourceId,
    'format': <String, Object?>{
      'sampleRate': outputFormat.sampleRate,
      'channels': outputFormat.channels,
      'sampleFormat': outputFormat.sampleFormat.name,
    },
    'frameDurationMicroseconds': frameDuration.inMicroseconds,
    'maxBufferedDurationMicroseconds': maxBufferedDuration.inMicroseconds,
    'overflowPolicy': overflowPolicy.name,
    'fallbackPolicy': fallbackPolicy.name,
    'processIds': processIds,
  };
}

/// Degraded source proposed by a backend but not yet authorized.
final class CaptureFallbackProposal {
  CaptureFallbackProposal({
    required this.confirmationId,
    required this.requestedSourceId,
    required this.fallbackSourceId,
    required this.reasonCode,
    required this.message,
  }) {
    _requireCaptureIdentifier(confirmationId, 'confirmationId');
    _requireCaptureIdentifier(requestedSourceId, 'requestedSourceId');
    _requireCaptureIdentifier(fallbackSourceId, 'fallbackSourceId');
    _requireCaptureIdentifier(reasonCode, 'reasonCode');
    _requireCaptureIdentifier(message, 'message');
    if (requestedSourceId == fallbackSourceId) {
      throw ArgumentError('A fallback must select a different source.');
    }
  }

  factory CaptureFallbackProposal.fromJson(Map<String, Object?> json) {
    return CaptureFallbackProposal(
      confirmationId: _captureRequiredString(json, 'confirmationId'),
      requestedSourceId: _captureRequiredString(json, 'requestedSourceId'),
      fallbackSourceId: _captureRequiredString(json, 'fallbackSourceId'),
      reasonCode: _captureRequiredString(json, 'reasonCode'),
      message: _captureRequiredString(json, 'message'),
    );
  }

  final String confirmationId;
  final String requestedSourceId;
  final String fallbackSourceId;
  final String reasonCode;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'confirmationId': confirmationId,
    'requestedSourceId': requestedSourceId,
    'fallbackSourceId': fallbackSourceId,
    'reasonCode': reasonCode,
    'message': message,
  };
}

/// Explicit host/user authorization for one exact fallback proposal.
final class CaptureFallbackConfirmation {
  CaptureFallbackConfirmation({
    required this.confirmationId,
    required this.acceptedSourceId,
  }) {
    _requireCaptureIdentifier(confirmationId, 'confirmationId');
    _requireCaptureIdentifier(acceptedSourceId, 'acceptedSourceId');
  }

  factory CaptureFallbackConfirmation.fromJson(Map<String, Object?> json) {
    return CaptureFallbackConfirmation(
      confirmationId: _captureRequiredString(json, 'confirmationId'),
      acceptedSourceId: _captureRequiredString(json, 'acceptedSourceId'),
    );
  }

  final String confirmationId;
  final String acceptedSourceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'confirmationId': confirmationId,
    'acceptedSourceId': acceptedSourceId,
  };
}

/// Result of checking permissions, format, and source availability.
enum CaptureProbeStatus {
  ready,
  fallbackProposed,
  permissionRequired,
  unavailable,
}

/// Durable result of [CaptureBackend.probe].
final class CaptureProbeResult {
  CaptureProbeResult({
    required this.probeId,
    required this.requestId,
    required this.backendId,
    required this.requestedSourceId,
    required this.status,
    this.resolvedSourceId,
    this.fallback,
    this.reasonCode,
    this.message,
  }) {
    _requireCaptureIdentifier(probeId, 'probeId');
    _requireCaptureIdentifier(requestId, 'requestId');
    _requireCaptureIdentifier(backendId, 'backendId');
    _requireCaptureIdentifier(requestedSourceId, 'requestedSourceId');
    _requireCaptureOptionalText(resolvedSourceId, 'resolvedSourceId');
    _requireCaptureOptionalText(reasonCode, 'reasonCode');
    _requireCaptureOptionalText(message, 'message');
    switch (status) {
      case CaptureProbeStatus.ready:
        if (resolvedSourceId == null || fallback != null) {
          throw ArgumentError(
            'A ready probe needs one resolved source and no fallback.',
          );
        }
        if (resolvedSourceId != requestedSourceId) {
          throw ArgumentError(
            'Selecting another ready source requires an explicit fallback.',
          );
        }
      case CaptureProbeStatus.fallbackProposed:
        if (fallback == null || resolvedSourceId != null) {
          throw ArgumentError(
            'A fallback probe needs one unconfirmed proposal.',
          );
        }
        if (fallback!.requestedSourceId != requestedSourceId) {
          throw ArgumentError('The fallback proposal is for another source.');
        }
      case CaptureProbeStatus.permissionRequired:
      case CaptureProbeStatus.unavailable:
        if (resolvedSourceId != null || fallback != null) {
          throw ArgumentError(
            'A blocked probe cannot resolve or propose a source.',
          );
        }
        if (reasonCode == null || message == null) {
          throw ArgumentError('A blocked probe must include a stable reason.');
        }
    }
  }

  factory CaptureProbeResult.fromJson(Map<String, Object?> json) {
    final Object? fallback = json['fallback'];
    return CaptureProbeResult(
      probeId: _captureRequiredString(json, 'probeId'),
      requestId: _captureRequiredString(json, 'requestId'),
      backendId: _captureRequiredString(json, 'backendId'),
      requestedSourceId: _captureRequiredString(json, 'requestedSourceId'),
      status: _captureEnumByName(
        CaptureProbeStatus.values,
        _captureRequiredString(json, 'status'),
        'status',
      ),
      resolvedSourceId: _captureOptionalString(json, 'resolvedSourceId'),
      fallback: fallback == null
          ? null
          : CaptureFallbackProposal.fromJson(
              _captureAsMap(fallback, 'fallback'),
            ),
      reasonCode: _captureOptionalString(json, 'reasonCode'),
      message: _captureOptionalString(json, 'message'),
    );
  }

  final String probeId;
  final String requestId;
  final String backendId;
  final String requestedSourceId;
  final CaptureProbeStatus status;
  final String? resolvedSourceId;
  final CaptureFallbackProposal? fallback;
  final String? reasonCode;
  final String? message;

  /// Creates the only source selection a backend may start for [request].
  ///
  /// A fallback cannot pass this boundary without an exact confirmation ID and
  /// accepted source ID. Backends must still reject expired probe IDs.
  CaptureStartRequest authorize(
    CaptureProbeRequest request, {
    CaptureFallbackConfirmation? confirmation,
  }) {
    if (request.requestId != requestId ||
        request.sourceId != requestedSourceId) {
      throw StateError('The probe result does not belong to this request.');
    }
    switch (status) {
      case CaptureProbeStatus.ready:
        if (confirmation != null) {
          throw StateError('A ready source does not accept fallback consent.');
        }
        return CaptureStartRequest._(
          probeId: probeId,
          request: request,
          selectedSourceId: resolvedSourceId!,
        );
      case CaptureProbeStatus.fallbackProposed:
        final CaptureFallbackProposal proposal = fallback!;
        if (request.fallbackPolicy !=
            CaptureFallbackPolicy.requireExplicitConfirmation) {
          throw StateError('The request forbids capture fallback.');
        }
        if (confirmation == null ||
            confirmation.confirmationId != proposal.confirmationId ||
            confirmation.acceptedSourceId != proposal.fallbackSourceId) {
          throw StateError('The fallback has not been explicitly confirmed.');
        }
        return CaptureStartRequest._(
          probeId: probeId,
          request: request,
          selectedSourceId: proposal.fallbackSourceId,
          fallbackConfirmation: confirmation,
        );
      case CaptureProbeStatus.permissionRequired:
      case CaptureProbeStatus.unavailable:
        throw StateError('The probed capture source is not ready.');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'probeId': probeId,
    'requestId': requestId,
    'backendId': backendId,
    'requestedSourceId': requestedSourceId,
    'status': status.name,
    if (resolvedSourceId != null) 'resolvedSourceId': resolvedSourceId,
    if (fallback != null) 'fallback': fallback!.toJson(),
    if (reasonCode != null) 'reasonCode': reasonCode,
    if (message != null) 'message': message,
  };
}

/// Authorized input to [CaptureBackend.start].
final class CaptureStartRequest {
  CaptureStartRequest._({
    required this.probeId,
    required this.request,
    required this.selectedSourceId,
    this.fallbackConfirmation,
  });

  /// Reads a previously authorized start request from durable JSON.
  ///
  /// Backends must revalidate the probe ID before allocation; deserialization
  /// alone never grants capture permission or fallback consent.
  factory CaptureStartRequest.fromJson(Map<String, Object?> json) {
    return CaptureStartRequest._(
      probeId: _captureRequiredString(json, 'probeId'),
      request: CaptureProbeRequest.fromJson(
        _captureRequiredMap(json, 'request'),
      ),
      selectedSourceId: _captureRequiredString(json, 'selectedSourceId'),
      fallbackConfirmation: json['fallbackConfirmation'] == null
          ? null
          : CaptureFallbackConfirmation.fromJson(
              _captureRequiredMap(json, 'fallbackConfirmation'),
            ),
    );
  }

  final String probeId;
  final CaptureProbeRequest request;
  final String selectedSourceId;
  final CaptureFallbackConfirmation? fallbackConfirmation;

  Map<String, Object?> toJson() => <String, Object?>{
    'probeId': probeId,
    'request': request.toJson(),
    'selectedSourceId': selectedSourceId,
    if (fallbackConfirmation != null)
      'fallbackConfirmation': fallbackConfirmation!.toJson(),
  };
}

/// Platform-neutral capture port implemented by native or process adapters.
///
/// [enumerateSources] reports only capability-checked descriptors. [probe]
/// performs format, permission, and liveness preflight without allocating a
/// long-lived capture. [start] returns a prepared [AudioSourceSession]; callers
/// subscribe to its streams before invoking [AudioSourceSession.start].
abstract interface class CaptureBackend {
  CaptureBackendDescriptor get descriptor;

  Future<List<CaptureSourceDescriptor>> enumerateSources({
    AudioCancellationToken? cancellationToken,
  });

  Future<CaptureProbeResult> probe(
    CaptureProbeRequest request, {
    AudioCancellationToken? cancellationToken,
  });

  /// Allocates the exact source authorized by [request].
  ///
  /// Implementations must reject stale probe IDs and must never silently choose
  /// another source. The returned session remains prepared until its own
  /// `start` method is called.
  Future<AudioSourceSession> start(
    CaptureStartRequest request, {
    AudioCancellationToken? cancellationToken,
  });
}

void _requireCaptureIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

void _requireCaptureOptionalText(String? value, String name) {
  if (value != null) {
    _requireCaptureIdentifier(value, name);
  }
}

List<int> _sortedUniquePositive(List<int> values, String name) {
  if (values.any((int value) => value <= 0)) {
    throw ArgumentError.value(values, name, 'Values must be positive.');
  }
  final List<int> result = values.toSet().toList()..sort();
  if (result.length != values.length) {
    throw ArgumentError.value(values, name, 'Values must be unique.');
  }
  return result;
}

String _captureRequiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string.');
  }
  return value;
}

String? _captureOptionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string when present.');
  }
  return value;
}

int _captureRequiredInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw FormatException('"$key" must be an integer.');
  }
  return value;
}

List<int> _captureIntList(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('"$key" must be a JSON array.');
  }
  return <int>[
    for (final Object? item in value)
      if (item is int)
        item
      else
        throw FormatException('Every "$key" item must be an integer.'),
  ];
}

Map<String, Object?> _captureRequiredMap(
  Map<String, Object?> json,
  String key,
) => _captureAsMap(json[key], key);

Map<String, Object?> _captureAsMap(Object? value, String name) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('"$name" must be a JSON object.');
  }
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw FormatException('"$name" must have string keys.');
    }
    result[key] = entry.value;
  }
  return result;
}

T _captureEnumByName<T extends Enum>(
  List<T> values,
  String name,
  String field,
) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('Unknown "$field" value: $name.');
}

Set<T> _captureEnumSet<T extends Enum>(
  List<T> values,
  Object? input,
  String field,
) {
  if (input is! List<Object?>) {
    throw FormatException('"$field" must be a JSON array.');
  }
  return <T>{
    for (final Object? item in input)
      if (item is String)
        _captureEnumByName(values, item, field)
      else
        throw FormatException('Every "$field" item must be a string.'),
  };
}

List<String> _orderedEnumNames<T extends Enum>(List<T> order, Set<T> values) =>
    <String>[
      for (final T value in order)
        if (values.contains(value)) value.name,
    ];
