// Command assembly, source enumeration, and monitor resolution derived from
// Control Center's pure-Dart Linux capture backend
// (packages/system_audio_capture/lib/system_audio_capture.dart), MIT (c) 2026
// Samuel Alev. See the NOTICE file at the root of this package.

import 'dart:convert';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Executables this package shells out to.
abstract final class LinuxAudioTools {
  static const String parecord = 'parecord';
  static const String pwRecord = 'pw-record';
  static const String paplay = 'paplay';
  static const String pwPlay = 'pw-play';
  static const String pactl = 'pactl';
}

/// Raised when a request cannot be expressed as PulseAudio/PipeWire arguments.
final class LinuxAudioFormatException implements Exception {
  const LinuxAudioFormatException(this.code, this.message);

  /// Platform-layer failure code, matching the PascalCase convention used by
  /// the Darwin implementation.
  final String code;

  final String message;

  @override
  String toString() => 'LinuxAudioFormatException($code): $message';
}

/// Upper bounds accepted by PulseAudio's sample specification.
const int kLinuxMaximumSampleRate = 192000;
const int kLinuxMaximumChannelCount = 32;

/// Validates that [format] and [frameDuration] can be requested from the
/// capture tools and produce at least one whole frame.
///
/// Formats map straight onto process arguments (`--rate`, `--channels`), so
/// any rate and channel count PulseAudio accepts is supported; combinations it
/// cannot express are rejected here rather than failing mid-capture.
void validateCaptureFormat(
  PlatformPcmFormat format, {
  required Duration frameDuration,
}) {
  if (format.sampleRate > kLinuxMaximumSampleRate) {
    throw LinuxAudioFormatException(
      'UnsupportedSampleRate',
      'PulseAudio accepts at most $kLinuxMaximumSampleRate Hz, '
          'got ${format.sampleRate}.',
    );
  }
  if (format.channelCount > kLinuxMaximumChannelCount) {
    throw LinuxAudioFormatException(
      'UnsupportedChannelCount',
      'PulseAudio accepts at most $kLinuxMaximumChannelCount channels, '
          'got ${format.channelCount}.',
    );
  }
  if (frameDuration <= Duration.zero) {
    throw const LinuxAudioFormatException(
      'InvalidFrameDuration',
      'Frame duration must be positive.',
    );
  }
  if (sampleFramesPerFrame(format, frameDuration) < 1) {
    throw LinuxAudioFormatException(
      'InvalidFrameDuration',
      'Frame duration ${frameDuration.inMicroseconds}us yields no whole '
          'sample frame at ${format.sampleRate} Hz.',
    );
  }
}

/// Validates that [format] can be requested from the playback tools.
void validatePlaybackFormat(PlatformPcmFormat format) {
  if (format.sampleRate > kLinuxMaximumSampleRate) {
    throw LinuxAudioFormatException(
      'UnsupportedSampleRate',
      'PulseAudio accepts at most $kLinuxMaximumSampleRate Hz, '
          'got ${format.sampleRate}.',
    );
  }
  if (format.channelCount > kLinuxMaximumChannelCount) {
    throw LinuxAudioFormatException(
      'UnsupportedChannelCount',
      'PulseAudio accepts at most $kLinuxMaximumChannelCount channels, '
          'got ${format.channelCount}.',
    );
  }
}

/// Per-channel sample frames carried by one delivered audio frame.
int sampleFramesPerFrame(PlatformPcmFormat format, Duration frameDuration) =>
    frameDuration.inMicroseconds *
    format.sampleRate ~/
    Duration.microsecondsPerSecond;

/// Interleaved float32 samples carried by one delivered audio frame.
int samplesPerFrame(PlatformPcmFormat format, Duration frameDuration) =>
    sampleFramesPerFrame(format, frameDuration) * format.channelCount;

/// Command line for a capture, in fallback order: `parecord`, then `pw-record`.
///
/// [target] is a PulseAudio source name — a hardware source for microphone
/// capture, or a sink's `.monitor` source for system audio. A null target
/// leaves device selection to the tool's own default.
List<List<String>> captureCommands({
  required PlatformPcmFormat format,
  required String? target,
  int? monitorStreamIndex,
}) {
  final List<String> pulse = <String>[
    LinuxAudioTools.parecord,
    '--raw',
    '--rate=${format.sampleRate}',
    '--channels=${format.channelCount}',
    '--format=s16le',
    if (monitorStreamIndex != null)
      '--monitor-stream=$monitorStreamIndex'
    else if (target != null)
      '--device=$target',
  ];
  if (monitorStreamIndex != null) {
    // pw-record can address a PipeWire node, but it cannot express Pulse's
    // sink-input monitor selector. Falling back to a source/monitor would
    // silently broaden an application capture into the complete sink mix.
    return <List<String>>[pulse];
  }
  return <List<String>>[
    pulse,
    <String>[
      LinuxAudioTools.pwRecord,
      '--rate=${format.sampleRate}',
      '--channels=${format.channelCount}',
      '--format=s16',
      if (target != null) '--target=$target',
      '-',
    ],
  ];
}

/// Command line for playback, in fallback order: `paplay`, then `pw-play`.
List<List<String>> playbackCommands({required PlatformPcmFormat format}) =>
    <List<String>>[
      <String>[
        LinuxAudioTools.paplay,
        '--raw',
        '--rate=${format.sampleRate}',
        '--channels=${format.channelCount}',
        '--format=s16le',
      ],
      <String>[
        LinuxAudioTools.pwPlay,
        '--rate=${format.sampleRate}',
        '--channels=${format.channelCount}',
        '--format=s16',
        '-',
      ],
    ];

/// One entry of `pactl list sources short`.
final class PulseSource {
  const PulseSource({
    required this.name,
    required this.description,
    this.driver = '',
  });

  final String name;

  /// Sound-server driver reported by `pactl` (for example `PipeWire`).
  final String driver;

  /// Human-readable label; `pactl list sources short` only carries the name,
  /// so this falls back to it.
  final String description;

  /// Monitor sources mirror a sink's output and are what system-audio capture
  /// targets.
  bool get isMonitor => name.endsWith('.monitor');

  /// Whether PulseAudio's source namespace is backed by PipeWire.
  bool get isPipeWire => driver.toLowerCase().contains('pipewire');
}

/// One addressable render stream returned by `pactl list sink-inputs`.
///
/// PulseAudio calls an application's render stream a "sink input". A record
/// stream attached to the sink monitor can select exactly one of these with
/// `pa_stream_set_monitor_stream`; `parecord --monitor-stream` exposes that
/// API without moving the application or creating a virtual sink.
final class PulseSinkInput {
  const PulseSinkInput({
    required this.index,
    required this.processId,
    required this.applicationId,
    required this.displayName,
    required this.corked,
  });

  final int index;
  final int? processId;
  final String applicationId;
  final String displayName;
  final bool corked;

  bool get isBrowser {
    final String value = '$applicationId $displayName'.toLowerCase();
    return <String>[
      'chrome',
      'chromium',
      'firefox',
      'microsoft-edge',
      'msedge',
      'brave',
      'opera',
      'vivaldi',
    ].any(value.contains);
  }
}

/// Stable native selector carried through `PlatformCaptureRequest`.
const String kPulseMonitorStreamPrefix = 'pulse-monitor-stream:';

/// Encodes a Pulse sink-input index without confusing it with a source name.
String pulseMonitorStreamTarget(int index) =>
    '$kPulseMonitorStreamPrefix$index';

/// Decodes an addressable sink-input selector, or null for an ordinary source.
int? parsePulseMonitorStreamTarget(String? target) {
  if (target == null || !target.startsWith(kPulseMonitorStreamPrefix)) {
    return null;
  }
  final int? index = int.tryParse(
    target.substring(kPulseMonitorStreamPrefix.length),
  );
  return index != null && index >= 0 ? index : null;
}

/// Parses `pactl --format=json list sink-inputs` defensively.
///
/// Properties are optional by contract. Entries without a local numeric
/// process ID remain useful diagnostics but are not exposed as process-filtered
/// sources because matching them to a requested PID would be guesswork.
List<PulseSinkInput> parseSinkInputsJson(String output) {
  if (output.trim().isEmpty) {
    return const <PulseSinkInput>[];
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(output);
  } on FormatException {
    return const <PulseSinkInput>[];
  }
  if (decoded is! List<Object?>) {
    return const <PulseSinkInput>[];
  }

  final List<PulseSinkInput> streams = <PulseSinkInput>[];
  for (final Object? value in decoded) {
    if (value is! Map<String, Object?>) {
      continue;
    }
    final int? index = _jsonInt(value['index']);
    if (index == null || index < 0) {
      continue;
    }
    final Map<String, Object?> properties = switch (value['properties']) {
      final Map<String, Object?> map => map,
      _ => const <String, Object?>{},
    };
    final int? processId = _jsonInt(properties['application.process.id']);
    final String applicationId =
        _firstNonEmpty(<Object?>[
          properties['application.desktop'],
          properties['application.process.binary'],
          properties['application.name'],
        ]) ??
        'pulse-stream-$index';
    final String displayName =
        _firstNonEmpty(<Object?>[
          properties['application.name'],
          properties['media.name'],
          properties['application.process.binary'],
        ]) ??
        applicationId;
    streams.add(
      PulseSinkInput(
        index: index,
        processId: processId != null && processId > 0 ? processId : null,
        applicationId: applicationId,
        displayName: displayName,
        corked: value['corked'] == true || value['corked'] == 'yes',
      ),
    );
  }
  return streams;
}

int? _jsonInt(Object? value) => switch (value) {
  final int number => number,
  final String text => int.tryParse(text),
  _ => null,
};

String? _firstNonEmpty(List<Object?> values) {
  for (final Object? value in values) {
    if (value case final String text when text.trim().isNotEmpty) {
      return text.trim();
    }
  }
  return null;
}

/// Parses `pactl list sources short`, whose columns are
/// `index<TAB>name<TAB>driver<TAB>sample-spec<TAB>state`.
List<PulseSource> parseSourcesShort(String output) {
  final List<PulseSource> sources = <PulseSource>[];
  for (final String line in output.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final List<String> columns = trimmed.split(RegExp(r'\s+'));
    if (columns.length < 2) {
      continue;
    }
    final String name = columns[1];
    if (name.isEmpty) {
      continue;
    }
    sources.add(
      PulseSource(
        name: name,
        description: name,
        driver: columns.length > 2 ? columns[2] : '',
      ),
    );
  }
  return sources;
}

/// Derives the default sink's monitor source name from `pactl get-default-sink`.
String? defaultSinkMonitor(String output) {
  final String sink = output.trim();
  if (sink.isEmpty) {
    return null;
  }
  return sink.endsWith('.monitor') ? sink : '$sink.monitor';
}
