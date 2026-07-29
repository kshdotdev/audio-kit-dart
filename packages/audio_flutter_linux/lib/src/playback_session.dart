import 'dart:async';
import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

import 'pcm.dart';
import 'process_runner.dart';
import 'pulse_commands.dart';

/// One `paplay`/`pw-play` sink fed interleaved float32 frames.
///
/// Backpressure is the child's stdin: every write awaits its flush, so a
/// producer outrunning the device is throttled by the pipe rather than by an
/// unbounded queue in Dart.
final class LinuxPlaybackSession {
  LinuxPlaybackSession({
    required this.sessionId,
    required this.request,
    required this.runner,
  });

  final int sessionId;
  final PlatformPlaybackRequest request;
  final LinuxProcessRunner runner;

  final StreamController<PlatformAudioSessionEvent> _events =
      StreamController<PlatformAudioSessionEvent>.broadcast();

  LinuxProcessHandle? _process;
  StreamSubscription<List<int>>? _stderr;
  final StringBuffer _stderrExcerpt = StringBuffer();
  bool _finished = false;
  bool _disposed = false;

  Stream<PlatformAudioSessionEvent> get events => _events.stream;

  PlatformPlaybackSessionInfo get info => PlatformPlaybackSessionInfo(
    sessionId: sessionId,
    clockId: 'linux-pulse',
    format: request.inputFormat,
  );

  void emitPrepared() => _emit(PlatformAudioSessionPhase.prepared);

  Future<void> start() async {
    if (_process != null) {
      return;
    }
    _emit(PlatformAudioSessionPhase.starting);

    final List<List<String>> attempts = playbackCommands(
      format: request.inputFormat,
    );
    Object? lastError;
    for (final List<String> command in attempts) {
      try {
        final LinuxProcessHandle process = await runner.start(
          command.first,
          command.sublist(1),
        );
        _process = process;
        _stderr = process.stderr.listen(_onStderr, cancelOnError: false);
        _emit(PlatformAudioSessionPhase.running, receivingAudio: true);
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }

    _emit(
      PlatformAudioSessionPhase.failed,
      code: 'PlaybackToolUnavailable',
      message:
          'No playback tool could be started (tried '
          '${attempts.map((List<String> c) => c.first).join(', ')})'
          '${lastError == null ? '' : ': $lastError'}.',
    );
  }

  Future<void> write(List<PlatformAudioFrame> frames) async {
    final LinuxProcessHandle? process = _process;
    if (process == null || _finished || _disposed) {
      return;
    }
    for (final PlatformAudioFrame frame in frames) {
      final Uint8List bytes = encodeS16le(frame.samples);
      if (bytes.isEmpty) {
        continue;
      }
      await process.writeStdin(bytes);
    }
  }

  /// Closes stdin and waits for the tool to drain what it already has.
  Future<void> finish() async {
    if (_finished || _disposed) {
      return;
    }
    _finished = true;
    _emit(PlatformAudioSessionPhase.stopping);
    final LinuxProcessHandle? process = _process;
    if (process != null) {
      await process.closeStdin();
      await process.exitCode;
    }
    await _teardown();
    _emit(PlatformAudioSessionPhase.stopped);
  }

  Future<void> abort() async {
    if (_disposed) {
      return;
    }
    _finished = true;
    _process?.kill();
    await _teardown();
    _emit(PlatformAudioSessionPhase.stopped, code: 'PlaybackAborted');
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _process?.kill();
    await _teardown();
    await _events.close();
  }

  void _onStderr(List<int> chunk) {
    if (_stderrExcerpt.length >= 512) {
      return;
    }
    _stderrExcerpt.write(String.fromCharCodes(chunk));
  }

  Future<void> _teardown() async {
    await _stderr?.cancel();
    _stderr = null;
  }

  void _emit(
    PlatformAudioSessionPhase phase, {
    String? code,
    String? message,
    bool? receivingAudio,
  }) {
    if (_events.isClosed) {
      return;
    }
    _events.add(
      PlatformAudioSessionEvent(
        sessionId: sessionId,
        phase: phase,
        code: code,
        message: message,
        receivingAudio: receivingAudio,
      ),
    );
  }
}
