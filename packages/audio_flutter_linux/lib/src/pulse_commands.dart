// Command assembly, source enumeration, and monitor resolution derived from
// Control Center's pure-Dart Linux capture backend
// (packages/system_audio_capture/lib/system_audio_capture.dart), MIT (c) 2026
// Samuel Alev. See the NOTICE file at the root of this package.

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
const int _maxSampleRate = 192000;
const int _maxChannelCount = 32;

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
  if (format.sampleRate > _maxSampleRate) {
    throw LinuxAudioFormatException(
      'UnsupportedSampleRate',
      'PulseAudio accepts at most $_maxSampleRate Hz, '
          'got ${format.sampleRate}.',
    );
  }
  if (format.channelCount > _maxChannelCount) {
    throw LinuxAudioFormatException(
      'UnsupportedChannelCount',
      'PulseAudio accepts at most $_maxChannelCount channels, '
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
  if (format.sampleRate > _maxSampleRate) {
    throw LinuxAudioFormatException(
      'UnsupportedSampleRate',
      'PulseAudio accepts at most $_maxSampleRate Hz, '
          'got ${format.sampleRate}.',
    );
  }
  if (format.channelCount > _maxChannelCount) {
    throw LinuxAudioFormatException(
      'UnsupportedChannelCount',
      'PulseAudio accepts at most $_maxChannelCount channels, '
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
}) => <List<String>>[
  <String>[
    LinuxAudioTools.parecord,
    '--raw',
    '--rate=${format.sampleRate}',
    '--channels=${format.channelCount}',
    '--format=s16le',
    if (target != null) '--device=$target',
  ],
  <String>[
    LinuxAudioTools.pwRecord,
    '--rate=${format.sampleRate}',
    '--channels=${format.channelCount}',
    '--format=s16',
    if (target != null) '--target=$target',
    '-',
  ],
];

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
  const PulseSource({required this.name, required this.description});

  final String name;

  /// Human-readable label; `pactl list sources short` only carries the name,
  /// so this falls back to it.
  final String description;

  /// Monitor sources mirror a sink's output and are what system-audio capture
  /// targets.
  bool get isMonitor => name.endsWith('.monitor');
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
    sources.add(PulseSource(name: name, description: name));
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
