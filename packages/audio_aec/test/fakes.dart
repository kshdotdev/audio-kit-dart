// Test doubles shared by the audio_aec suite.
//
// The point of the [AecBindings] seam is that everything above it runs without
// a native library. [FakeAecBindings] is that fake: it models cancellation as
// exact subtraction of the far-end block the filter paired with each capture
// block, so a test can inject a known echo and assert it is gone — and, just as
// importantly, assert *which* reference block the filter chose to pair.

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:audio_core/audio_core.dart';

/// Opaque non-null handle. Never dereferenced: the fake keys its state on
/// itself, not on the pointer, so this only has to be distinguishable from
/// [nullptr].
final Pointer<Void> fakeAecHandle = Pointer<Void>.fromAddress(0xAEC0);

/// An [AecBindings] that records every call and cancels by subtraction.
final class FakeAecBindings implements AecBindings {
  /// Creates a fake. When [createReturnsNull] the native constructor reports
  /// failure, which is how a real engine refuses an unsupported format.
  FakeAecBindings({
    this.createReturnsNull = false,
    this.versionString = 'fake-aec+subtraction',
    this.erl,
    this.erle,
    this.residual,
    this.delayMs,
  });

  /// Whether [create] should report failure.
  final bool createReturnsNull;

  /// Value [version] returns.
  final String? versionString;

  /// Metric values written by [getMetrics]; `null` writes the sentinel.
  double? erl;

  /// See [erl].
  double? erle;

  /// See [erl].
  double? residual;

  /// See [erl]. `null` writes `-1`.
  int? delayMs;

  /// Every native call, in order, as bare symbol names.
  final List<String> calls = <String>[];

  /// `(sampleRate, channels)` of each [create].
  final List<({int sampleRate, int channels})> createCalls =
      <({int sampleRate, int channels})>[];

  /// Far-end blocks received, in order.
  final List<Int16List> reverseBlocks = <Int16List>[];

  /// Near-end blocks received, in order.
  final List<Int16List> captureBlocks = <Int16List>[];

  /// Cleaned blocks produced, in order.
  final List<Int16List> cleanedBlocks = <Int16List>[];

  /// `stream_delay_ms` received by each [processCapture], in order.
  final List<int> streamDelays = <int>[];

  /// Block sizes received, in order — the 10 ms contract, as observed.
  final List<int> frameCounts = <int>[];

  /// Number of [destroy] calls.
  int destroyCount = 0;

  final Queue<Int16List> _pendingReference = Queue<Int16List>();

  /// Far-end blocks fed but not yet consumed by a capture.
  int get pendingReferenceCount => _pendingReference.length;

  @override
  Pointer<Void> create(int sampleRateHz, int numChannels) {
    calls.add('create');
    createCalls.add((sampleRate: sampleRateHz, channels: numChannels));
    return createReturnsNull ? nullptr : fakeAecHandle;
  }

  @override
  void processReverse(Pointer<Void> handle, Pointer<Int16> ref, int frames) {
    calls.add('reverse');
    frameCounts.add(frames);
    final Int16List block = Int16List.fromList(ref.asTypedList(frames));
    reverseBlocks.add(block);
    _pendingReference.add(block);
  }

  @override
  void processCapture(
    Pointer<Void> handle,
    Pointer<Int16> cap,
    Pointer<Int16> out,
    int frames,
    int streamDelayMs,
  ) {
    calls.add('capture');
    frameCounts.add(frames);
    streamDelays.add(streamDelayMs);
    final Int16List capture = cap.asTypedList(frames);
    final Int16List cleaned = out.asTypedList(frames);
    // One render block per capture block: pair with the oldest unconsumed
    // reference, exactly as a real engine's render buffer would.
    final Int16List? reference = _pendingReference.isEmpty
        ? null
        : _pendingReference.removeFirst();
    for (var index = 0; index < frames; index += 1) {
      final int value = reference == null
          ? capture[index]
          : capture[index] - reference[index];
      cleaned[index] = value < -32768
          ? -32768
          : (value > 32767 ? 32767 : value);
    }
    captureBlocks.add(Int16List.fromList(capture));
    cleanedBlocks.add(Int16List.fromList(cleaned));
  }

  @override
  void getMetrics(
    Pointer<Void> handle,
    Pointer<Double> erlOut,
    Pointer<Double> erleOut,
    Pointer<Double> residualOut,
    Pointer<Int32> delayOut,
  ) {
    calls.add('metrics');
    erlOut.value = erl ?? kAecMetricUnavailable;
    erleOut.value = erle ?? kAecMetricUnavailable;
    residualOut.value = residual ?? kAecMetricUnavailable;
    delayOut.value = delayMs ?? -1;
  }

  @override
  void destroy(Pointer<Void> handle) {
    calls.add('destroy');
    destroyCount += 1;
  }

  @override
  String? version() {
    calls.add('version');
    return versionString;
  }
}

/// An [AudioSource] the test drives frame by frame, so arrival order and timing
/// are exact rather than whatever the event loop happens to do.
final class ManualAudioSource implements AudioSource {
  /// Creates a manually driven source.
  ManualAudioSource({
    required this.format,
    this.sourceId = 'manual',
    this.trackId = 'audio',
    this.clockId = 'manual.clock',
    this.isRealtime = true,
  });

  /// Format of emitted frames.
  final AudioFormat format;

  /// Identifier applied to emitted frames.
  final String sourceId;

  /// See [sourceId].
  final String trackId;

  /// See [sourceId].
  final String clockId;

  /// Reported through [AudioSourceCapabilities.isRealtime].
  final bool isRealtime;

  /// The prepared session, once [prepare] has run.
  ManualAudioSourceSession? session;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return session = ManualAudioSourceSession(this);
  }
}

/// Session of a [ManualAudioSource].
final class ManualAudioSourceSession implements AudioSourceSession {
  /// Creates a session for [source].
  ManualAudioSourceSession(this.source);

  /// Owning source.
  final ManualAudioSource source;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: false,
  );
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  int _sequence = 0;
  int _sampleOffset = 0;
  bool _started = false;

  /// Whether [start] has run.
  bool get isStarted => _started;

  /// Number of frames pushed.
  int get pushedFrameCount => _sequence;

  /// Emits [samples] as one frame.
  void push(Float32List samples, {AudioDiscontinuity? discontinuity}) {
    if (_frames.isClosed) {
      return;
    }
    _frames.add(
      AudioFrame.owned(
        format: source.format,
        samples: samples,
        sourceId: source.sourceId,
        trackId: source.trackId,
        clockId: source.clockId,
        sequence: _sequence,
        sampleOffset: _sampleOffset,
        timestamp: source.format.durationForFrames(_sampleOffset),
        discontinuity: discontinuity,
      ),
    );
    _sequence += 1;
    _sampleOffset += samples.length ~/ source.format.channels;
  }

  /// Ends the stream.
  void finish() {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }

  @override
  AudioFormat get format => source.format;

  @override
  String get sourceId => source.sourceId;

  @override
  String get trackId => source.trackId;

  @override
  String get clockId => source.clockId;

  @override
  AudioSourceCapabilities get capabilities =>
      AudioSourceCapabilities(isRealtime: source.isRealtime);

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _started = true;
    _transition(AudioSessionState.active);
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Manual sources are realtime.');

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async =>
      throw UnsupportedError('Manual sources are realtime.');

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    finish();
    _transition(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    finish();
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() async {
    finish();
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

/// Mono float32 block of [frames] samples at `+/-amplitude`.
///
/// The alternating sign keeps it from being a DC block while leaving the RMS
/// exactly [amplitude], which is what the delay estimator reads.
Float32List tone(int frames, double amplitude) {
  final Float32List samples = Float32List(frames);
  for (var index = 0; index < frames; index += 1) {
    samples[index] = index.isEven ? amplitude : -amplitude;
  }
  return samples;
}

/// Sum of two equal-length blocks, clamped — a microphone picking up speech
/// plus speaker bleed.
Float32List mix(Float32List a, Float32List b) {
  final Float32List samples = Float32List(a.length);
  for (var index = 0; index < a.length; index += 1) {
    samples[index] = (a[index] + b[index]).clamp(-1.0, 1.0);
  }
  return samples;
}

/// Yields one event-loop turn, delivering every pending stream event.
Future<void> tick() => Future<void>.delayed(Duration.zero);
