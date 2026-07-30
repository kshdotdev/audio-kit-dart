// Tool fallback order, monitor targeting, and the always-drain-stderr rule are
// derived from Control Center's pure-Dart Linux capture backend
// (packages/system_audio_capture/lib/system_audio_capture.dart), MIT (c) 2026
// Samuel Alev. See the NOTICE file at the root of this package.

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

import 'frame_ring.dart';
import 'pcm.dart';
import 'process_runner.dart';
import 'pulse_commands.dart';
import 'recording_sink.dart';

/// How long a started capture may deliver nothing before it is declared dead.
///
/// Mirrors the Darwin watchdog: a source that never produces audio fails loudly
/// instead of hanging a caller that is waiting for frames.
const Duration kLinuxCaptureStallTimeout = Duration(seconds: 2);

/// Bytes of child stderr retained for failure messages.
const int _stderrExcerptLimit = 512;

/// One `parecord`/`pw-record` capture, exposed through the pull-model contract.
final class LinuxCaptureSession {
  LinuxCaptureSession({
    required this.sessionId,
    required this.request,
    required this.target,
    required this.runner,
    this.stallTimeout = kLinuxCaptureStallTimeout,
    LinuxRecordingSinkFactory? recordingSinkFactory,
  }) : _recordingSinkFactory = recordingSinkFactory ?? WavFileRecordingSink.new,
       _samplesPerFrame = samplesPerFrame(
         request.outputFormat,
         request.frameDuration,
       ),
       _sampleFramesPerFrame = sampleFramesPerFrame(
         request.outputFormat,
         request.frameDuration,
       ),
       _ring = FrameRing(
         capacity: _ringCapacity(request),
         policy: request.overflowPolicy,
       );

  final int sessionId;
  final PlatformCaptureRequest request;

  /// Resolved PulseAudio source name, or null to accept the tool's default.
  final String? target;

  final LinuxProcessRunner runner;

  /// How long the session may deliver nothing before failing.
  final Duration stallTimeout;

  final LinuxRecordingSinkFactory _recordingSinkFactory;
  final int _samplesPerFrame;
  final int _sampleFramesPerFrame;
  final FrameRing _ring;

  final StreamController<PlatformAudioSessionEvent> _events =
      StreamController<PlatformAudioSessionEvent>.broadcast();

  LinuxProcessHandle? _process;
  StreamSubscription<List<int>>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Timer? _stallWatchdog;
  LinuxRecordingSink? _recording;

  final BytesBuilder _pending = BytesBuilder(copy: true);
  final StringBuffer _stderrExcerpt = StringBuffer();

  Completer<void>? _waiter;
  int _sequence = 0;
  int _sampleOffset = 0;
  bool _receivedAudio = false;
  bool _ended = false;
  bool _stopping = false;
  bool _disposed = false;

  Stream<PlatformAudioSessionEvent> get events => _events.stream;

  PlatformCaptureSessionInfo get info => PlatformCaptureSessionInfo(
    sessionId: sessionId,
    sourceId: target ?? _defaultSourceId,
    trackId: switch (request.kind) {
      PlatformCaptureKind.microphone => 'me',
      PlatformCaptureKind.systemAudio => 'them',
    },
    clockId: 'linux-pulse',
    format: request.outputFormat,
  );

  String get _defaultSourceId => switch (request.kind) {
    PlatformCaptureKind.microphone => 'default-source',
    PlatformCaptureKind.systemAudio => 'default-monitor',
  };

  void emitPrepared() => _emit(PlatformAudioSessionPhase.prepared);

  Future<void> start() async {
    if (_process != null) {
      return;
    }
    _emit(PlatformAudioSessionPhase.starting);

    final String? recordingPath = request.rawRecordingPath;
    if (recordingPath != null) {
      final LinuxRecordingSink sink = _recordingSinkFactory(
        recordingPath,
        request.outputFormat,
      );
      await sink.open();
      _recording = sink;
    }

    final List<List<String>> attempts = captureCommands(
      format: request.outputFormat,
      target: target,
    );
    Object? lastError;
    for (final List<String> command in attempts) {
      try {
        final LinuxProcessHandle process = await runner.start(
          command.first,
          command.sublist(1),
        );
        _process = process;
        _wire(process);
        _armStallWatchdog();
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }

    await _failStart(
      'CaptureToolUnavailable',
      'No capture tool could be started (tried '
          '${attempts.map((List<String> c) => c.first).join(', ')})'
          '${lastError == null ? '' : ': $lastError'}.',
    );
  }

  Future<PlatformAudioFrameBatch> read({
    required int maxFrames,
    required Duration timeout,
  }) async {
    if (_ring.isEmpty && !_ended) {
      await _awaitFrames(timeout);
    }
    final List<PlatformAudioFrame> frames = _ring.take(maxFrames);
    return PlatformAudioFrameBatch(
      frames: frames,
      endOfStream: _ended && _ring.isEmpty,
    );
  }

  Future<void> stop() async {
    if (_stopping || _disposed) {
      return;
    }
    _stopping = true;
    _emit(PlatformAudioSessionPhase.stopping);
    _stallWatchdog?.cancel();
    _stallWatchdog = null;

    final LinuxProcessHandle? process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode;
    }
    await _teardownStreams();
    await _closeRecording(aborted: false);
    _ended = true;
    _signalWaiter();
    _emit(PlatformAudioSessionPhase.stopped);
  }

  Future<void> abort() async {
    if (_disposed) {
      return;
    }
    _stopping = true;
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _process?.kill();
    await _teardownStreams();
    await _closeRecording(aborted: true);
    _ring.clear();
    _ended = true;
    _signalWaiter();
    _emit(PlatformAudioSessionPhase.stopped, code: 'CaptureAborted');
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _process?.kill();
    await _teardownStreams();
    await _closeRecording(aborted: true);
    _ring.clear();
    _ended = true;
    _signalWaiter();
    await _events.close();
  }

  void _wire(LinuxProcessHandle process) {
    _stdout = process.stdout.listen(
      _onBytes,
      onError: (Object error) => _fail('CaptureReadFailed', '$error'),
      onDone: _onStdoutDone,
      cancelOnError: false,
    );
    // Control Center's lesson: an undrained stderr pipe fills and blocks the
    // child, so it is always consumed, and kept for failure diagnostics.
    _stderr = process.stderr.listen(_onStderr, cancelOnError: false);
  }

  void _onStderr(List<int> chunk) {
    if (_stderrExcerpt.length >= _stderrExcerptLimit) {
      return;
    }
    _stderrExcerpt.write(String.fromCharCodes(chunk));
  }

  void _onBytes(List<int> chunk) {
    if (_stopping || _disposed || chunk.isEmpty) {
      return;
    }
    if (!_receivedAudio) {
      _receivedAudio = true;
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      _emit(PlatformAudioSessionPhase.running, receivingAudio: true);
    }

    _recording?.add(chunk);
    _pending.add(chunk);

    final int frameBytes = _samplesPerFrame * 2;
    if (_pending.length < frameBytes) {
      return;
    }

    final Uint8List buffered = _pending.takeBytes();
    var offset = 0;
    var produced = false;
    while (buffered.length - offset >= frameBytes) {
      final Uint8List slice = Uint8List.sublistView(
        buffered,
        offset,
        offset + frameBytes,
      );
      offset += frameBytes;
      if (_admit(decodeS16le(slice))) {
        produced = true;
      } else {
        return;
      }
    }
    if (offset < buffered.length) {
      _pending.add(Uint8List.sublistView(buffered, offset));
    }
    if (produced) {
      _signalWaiter();
    }
  }

  /// Builds one frame and offers it to the ring, returning false when a
  /// fail-fast overflow has terminated the session.
  bool _admit(Float32List samples) {
    final PlatformAudioFrame frame = PlatformAudioFrame(
      sessionId: sessionId,
      sequence: _sequence,
      sampleOffset: _sampleOffset,
      timestamp: Duration(
        microseconds:
            _sampleOffset *
            Duration.microsecondsPerSecond ~/
            request.outputFormat.sampleRate,
      ),
      samples: samples,
    );
    // Both counters track produced audio, not delivered audio, so a dropped
    // frame leaves a sequence gap and the timeline stays honest.
    _sequence++;
    _sampleOffset += _sampleFramesPerFrame;

    final FrameRingAdmission admission = _ring.add(frame);
    if (admission == FrameRingAdmission.overflowed) {
      _fail(
        'CaptureMailboxOverflow',
        'Capture buffer of ${_ring.capacity} frames overflowed under a '
            'fail-fast overflow policy.',
      );
      return false;
    }
    return true;
  }

  void _onStdoutDone() {
    if (_stopping || _disposed) {
      return;
    }
    unawaited(_handleUnexpectedExit());
  }

  Future<void> _handleUnexpectedExit() async {
    final int? exitCode = await _process?.exitCode;
    if (_stopping || _disposed) {
      return;
    }
    _fail(
      'CaptureProcessExited',
      'Capture process exited'
          '${exitCode == null ? '' : ' with code $exitCode'}'
          '${_stderrExcerpt.isEmpty ? '' : ': ${_stderrExcerpt.toString().trim()}'}',
    );
  }

  void _armStallWatchdog() {
    _stallWatchdog = Timer(stallTimeout, () {
      if (_receivedAudio || _stopping || _disposed) {
        return;
      }
      _fail(
        'SystemCaptureDead',
        'No audio within ${stallTimeout.inMilliseconds}ms of starting '
            '${target ?? 'the default source'}.',
      );
    });
  }

  Future<void> _failStart(String code, String message) async {
    await _closeRecording(aborted: true);
    _fail(code, message);
  }

  void _fail(String code, String message) {
    if (_ended) {
      return;
    }
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _ended = true;
    _process?.kill();
    unawaited(_teardownStreams());
    unawaited(_closeRecording(aborted: true));
    _signalWaiter();
    _emit(
      PlatformAudioSessionPhase.failed,
      code: code,
      message: message,
      receivingAudio: _receivedAudio,
    );
  }

  Future<void> _teardownStreams() async {
    await _stdout?.cancel();
    _stdout = null;
    await _stderr?.cancel();
    _stderr = null;
  }

  Future<void> _closeRecording({required bool aborted}) async {
    final LinuxRecordingSink? recording = _recording;
    if (recording == null) {
      return;
    }
    _recording = null;
    if (aborted) {
      await recording.abort();
    } else {
      await recording.close();
    }
  }

  Future<void> _awaitFrames(Duration timeout) async {
    final Completer<void> waiter = Completer<void>();
    _waiter = waiter;
    final Timer timer = Timer(timeout, () {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
      if (identical(_waiter, waiter)) {
        _waiter = null;
      }
    }
  }

  void _signalWaiter() {
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
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

  static int _ringCapacity(PlatformCaptureRequest request) {
    final int frameMicros = request.frameDuration.inMicroseconds;
    if (frameMicros <= 0) {
      return 1;
    }
    final int capacity =
        request.maxBufferedDuration.inMicroseconds ~/ frameMicros;
    return capacity < 1 ? 1 : capacity;
  }
}
