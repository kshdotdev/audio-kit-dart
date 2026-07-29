import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';

import 'graph_voice_speech_output.dart';

/// Diagnostics a running [VoiceFarEndTap] session exposes on top of the
/// standard [AudioSourceSession] contract.
abstract interface class VoiceFarEndTapSession implements AudioSourceSession {
  /// Frames forwarded to the echo canceller, in order.
  int get framesTapped;

  /// Frames dropped because the tap was not running when they were played.
  ///
  /// A non-zero count is not necessarily a fault: audio played before capture
  /// starts or after it stops has no microphone to bleed into, so there is
  /// nothing to cancel. A count that climbs *during* a session means playback
  /// is being fed to the speakers without reaching the canceller, and
  /// cancellation is degrading for a reason that has nothing to do with the
  /// engine.
  int get framesDiscarded;

  /// Playback operations tapped so far.
  ///
  /// One per `GraphVoiceSpeechOutput.play` call, i.e. one per synthesized
  /// sentence.
  int get utterances;
}

/// Fans the synthesized playback signal out as an [AudioSource] usable as an
/// acoustic-echo-cancellation far-end reference.
///
/// ## Why this exists
///
/// An echo canceller subtracts a *reference* — what the speakers are playing —
/// from the microphone. For a meeting recorder that reference is a system
/// loopback capture. For a voice assistant it is something better: the assistant
/// generates the audio itself, so the reference can be the synthesized signal
/// directly, with no second operating-system capture, no second clock, and no
/// measured offset beyond output-device latency.
///
/// The catch is a lifetime mismatch. `GraphVoiceSpeechOutput` plays one finite
/// source per sentence and tears the graph down between them, while
/// `AecMicFilter` binds one far-end source for the whole capture session — its
/// engine is a single stateful native instance. This tap bridges the two: it is
/// one long-lived [AudioSource] fed by a succession of short-lived [AudioSink]
/// sessions, one per `play` call.
///
/// ## Wiring
///
/// The tap's [sink] goes on the *output* as a sibling of device playback, so
/// the router fans each synthesized frame to both. Its [AudioSource] face goes
/// to the canceller as the far end:
///
/// ```dart
/// final tap = VoiceFarEndTap(format: captureFormat);
/// final output = GraphVoiceSpeechOutput(
///   playbackSink: deviceSink,
///   extraRoutes: (format) => <VoiceSpeechOutputRoute>[tap.route()],
/// );
/// final microphone = AecMicFilter(
///   near: rawMicrophone,
///   far: tap,
///   processor: AecProcessor.create(),
/// );
/// ```
///
/// `VoiceFullDuplexSetup` does exactly this and is the supported entry point;
/// the pieces are public because an application composing its own graph needs
/// them.
///
/// ## Pacing
///
/// The reference is only useful if it arrives at roughly the rate it is heard.
/// That falls out of the graph rather than being enforced here: a pausable
/// synthesized source gets a `blockUpstream` playback route by default, and
/// `AudioRouter` dispatches one frame to every route before admitting the next,
/// so the device sink's consumption paces the tap too. A caller that overrides
/// `playbackOptions` with a lossy or non-blocking policy is choosing to let the
/// reference run ahead of the speakers, and the delay estimator will be trying
/// to lock onto an offset that reflects synthesis speed rather than acoustics.
///
/// ## Format
///
/// [format] must be the *capture* format, because that is what the canceller
/// compares against. A synthesized source of any other rate or channel count is
/// rejected at [AudioSink.prepare] rather than silently tapped: a reference at
/// the wrong rate produces no error and no cancellation, which is the worst
/// available outcome. Resample or reconfigure the voice upstream of the output.
final class VoiceFarEndTap implements AudioSource {
  /// Creates a tap that accepts and emits [format].
  VoiceFarEndTap({
    required this.format,
    this.routeId = 'voice-aec-reference',
    this.sourceId = 'voice-far-end',
    this.trackId = 'synthesis',
    this.clockId = 'voice-far-end.clock',
    this.routeOptions,
  }) {
    if (routeId.trim().isEmpty) {
      throw ArgumentError.value(routeId, 'routeId', 'Must not be empty.');
    }
  }

  /// Capture format the reference must match.
  final AudioFormat format;

  /// Route ID used by [route].
  final String routeId;

  /// Source identifier applied to emitted frames.
  final String sourceId;

  /// Track identifier applied to emitted frames.
  final String trackId;

  /// Clock identifier applied to emitted frames.
  ///
  /// The tap is genuinely its own timeline: it splices many synthesized
  /// sources, each of which restarts its own sample offsets at zero.
  final String clockId;

  /// Route options used by [route].
  ///
  /// Defaults to [AudioRouteOptions.lossless]. Dropping reference frames is
  /// worse than dropping microphone frames — a gap in the render stream
  /// desynchronizes cancellation for everything after it — so the reference
  /// route fails loudly instead of silently degrading audio quality.
  final AudioRouteOptions? routeOptions;

  late final _FarEndTapSink _sink = _FarEndTapSink(this);
  _FarEndTapSession? _session;

  /// Sink to attach beside device playback.
  AudioSink get sink => _sink;

  /// The live session, or `null` before [prepare] or after it terminates.
  VoiceFarEndTapSession? get session {
    final _FarEndTapSession? current = _session;
    return current == null || current.status.isTerminal ? null : current;
  }

  /// A ready-made output route carrying [sink].
  VoiceSpeechOutputRoute route({AudioRouteOptions? options}) =>
      VoiceSpeechOutputRoute(
        id: routeId,
        sink: _sink,
        options: options ?? routeOptions ?? AudioRouteOptions.lossless(),
      );

  @override
  Future<VoiceFarEndTapSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final _FarEndTapSession? existing = _session;
    if (existing != null && !existing.status.isTerminal) {
      throw StateError(
        'A far-end tap drives one capture session at a time. Close the '
        'previous session before preparing another.',
      );
    }
    return _session = _FarEndTapSession(this);
  }
}

final class _FarEndTapSink implements AudioSink {
  _FarEndTapSink(this._tap);

  final VoiceFarEndTap _tap;

  @override
  Future<AudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (format != _tap.format) {
      throw ArgumentError.value(
        format,
        'format',
        'The echo-cancellation reference must match the capture format '
            '${_tap.format}. A reference at a different rate or channel count '
            'produces no error and no cancellation, so it is rejected here. '
            'Resample the synthesized audio before the output.',
      );
    }
    return _FarEndTapSinkSession(_tap, format);
  }
}

/// One playback operation's writer into the tap.
///
/// Terminating this session ends only this utterance's contribution; the tap's
/// own source session outlives every one of them.
final class _FarEndTapSinkSession implements AudioSinkSession {
  _FarEndTapSinkSession(this._tap, this.format);

  final VoiceFarEndTap _tap;

  @override
  final AudioFormat format;

  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.active,
    timestamp: Duration.zero,
  );
  bool _first = true;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_status.isTerminal) {
      throw StateError('The far-end tap writer is no longer accepting frames.');
    }
    final bool first = _first;
    _first = false;
    _tap._session?.accept(frame, startsUtterance: first);
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _transition(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_status.isTerminal) {
      return;
    }
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    if (!_status.isTerminal) {
      _transition(AudioSessionState.aborted);
    }
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
  }

  void _transition(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: Duration.zero,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}

final class _FarEndTapSession implements VoiceFarEndTapSession {
  _FarEndTapSession(this._tap);

  final VoiceFarEndTap _tap;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    // Pausing would propagate backpressure from the echo canceller into the
    // playback graph and stall the speakers. Buffering here instead is the
    // lesser evil, and the reference route's own bound is what actually caps it.
    pauseSupported: false,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Stopwatch _clock = Stopwatch();

  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  int _sequence = 0;
  int _sampleOffset = 0;
  int _discarded = 0;
  int _utterances = 0;

  @override
  int get framesTapped => _sequence;

  @override
  int get framesDiscarded => _discarded;

  @override
  int get utterances => _utterances;

  @override
  AudioFormat get format => _tap.format;

  @override
  String get sourceId => _tap.sourceId;

  @override
  String get trackId => _tap.trackId;

  @override
  String get clockId => _tap.clockId;

  @override
  AudioSourceCapabilities get capabilities =>
      const AudioSourceCapabilities(isRealtime: true);

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => Stream<AudioSessionStatus>.multi((
    MultiStreamController<AudioSessionStatus> controller,
  ) {
    controller.add(_status);
    final StreamSubscription<AudioSessionStatus> subscription = _statuses.stream
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Forwards one played frame, or counts it as discarded.
  void accept(AudioFrame frame, {required bool startsUtterance}) {
    if (startsUtterance) {
      _utterances += 1;
    }
    if (_status.state != AudioSessionState.active || _frames.isClosed) {
      // Audio that plays while the tap is not running has no live microphone
      // to bleed into, so there is nothing to cancel and nothing to align.
      _discarded += 1;
      return;
    }
    // Copied rather than adopted: the playback route holds the same samples,
    // and `AudioFrame.owned` is a claim of exclusivity this does not have.
    final AudioFrame tapped = AudioFrame(
      format: format,
      samples: frame.samples,
      sourceId: sourceId,
      trackId: trackId,
      clockId: clockId,
      sequence: _sequence,
      sampleOffset: _sampleOffset,
      timestamp: format.durationForFrames(_sampleOffset),
      // Each utterance is a different synthesized source whose own offsets
      // restarted at zero, and silence separated it from the last one.
      discontinuity: startsUtterance && _sequence > 0
          ? AudioDiscontinuity(
              reason: AudioDiscontinuityReason.sourceRestart,
              previousSequence: _sequence - 1,
              description: 'New synthesized utterance.',
            )
          : null,
    );
    _sequence += 1;
    _sampleOffset += tapped.frameCount;
    _frames.add(tapped);
  }

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('A far-end tap session can only start once.');
    }
    _clock.start();
    _transition(AudioSessionState.starting);
    _transition(AudioSessionState.active);
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError(
        'A far-end tap cannot be paused: it would apply backpressure to '
        'playback, and a gap in the reference desynchronizes cancellation for '
        'everything after it.',
      );

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('A far-end tap cannot be paused, so nor resumed.');

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.isTerminal) {
      return;
    }
    _transition(AudioSessionState.finishing);
    _closeFrames();
    _transition(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_status.isTerminal) {
      return;
    }
    _closeFrames();
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (!_status.isTerminal) {
      await abort();
    }
    _closeFrames();
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    _clock.stop();
  }

  void _closeFrames() {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }

  void _transition(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}
