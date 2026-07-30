import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

/// Records every driver the provider asked for and returns scripted results.
final class FakeSherpaRuntime implements SherpaRuntime {
  /// Configurations passed to [createBatchAsr], in call order.
  final List<SherpaBatchAsrConfiguration> asrConfigurations =
      <SherpaBatchAsrConfiguration>[];

  /// Configurations passed to [createStreamingAsr], in call order.
  final List<SherpaStreamingAsrConfiguration> streamingConfigurations =
      <SherpaStreamingAsrConfiguration>[];

  /// Configurations passed to [createDiarizer], in call order.
  final List<SherpaDiarizationConfiguration> diarizationConfigurations =
      <SherpaDiarizationConfiguration>[];

  /// Configurations passed to [createVad], in call order.
  final List<SherpaVadConfiguration> vadConfigurations =
      <SherpaVadConfiguration>[];

  /// Drivers handed out, so tests can assert on close behavior.
  final List<FakeBatchAsrDriver> asrDrivers = <FakeBatchAsrDriver>[];

  /// Streaming drivers handed out, in creation order.
  final List<FakeStreamingAsrDriver> streamingDrivers =
      <FakeStreamingAsrDriver>[];

  /// Updates each streaming driver returns from successive `accept` calls.
  ///
  /// Once exhausted the driver reports an empty hypothesis, which is what
  /// sherpa does for a chunk of silence.
  List<SherpaDriverStreamingUpdate> streamingUpdates =
      const <SherpaDriverStreamingUpdate>[];

  /// Update each streaming driver returns from `finish`.
  SherpaDriverStreamingUpdate streamingFinishUpdate =
      SherpaDriverStreamingUpdate.empty;

  /// Delay applied to the nth `accept`, so ordering can be tested.
  List<Duration> streamingAcceptDelays = const <Duration>[];

  /// Result returned by every recognizer this runtime creates.
  SherpaDriverTranscript transcript = const SherpaDriverTranscript(text: '');

  /// Spans returned by every diarizer this runtime creates.
  List<SherpaDriverSpeakerSpan> spans = const <SherpaDriverSpeakerSpan>[];

  /// Spans returned by the VAD driver on the next accept call.
  List<SherpaDriverSpeechSpan> speechSpans = const <SherpaDriverSpeechSpan>[];

  /// Whether [close] ran.
  bool closed = false;

  @override
  Future<SherpaBatchAsrDriver> createBatchAsr(
    SherpaBatchAsrConfiguration configuration,
  ) async {
    asrConfigurations.add(configuration);
    final driver = FakeBatchAsrDriver(() => transcript);
    asrDrivers.add(driver);
    return driver;
  }

  @override
  Future<SherpaStreamingAsrDriver> createStreamingAsr(
    SherpaStreamingAsrConfiguration configuration,
  ) async {
    streamingConfigurations.add(configuration);
    final driver = FakeStreamingAsrDriver(
      updates: streamingUpdates,
      finishUpdate: streamingFinishUpdate,
      acceptDelays: streamingAcceptDelays,
    );
    streamingDrivers.add(driver);
    return driver;
  }

  @override
  Future<SherpaDiarizationDriver> createDiarizer(
    SherpaDiarizationConfiguration configuration,
  ) async {
    diarizationConfigurations.add(configuration);
    return FakeDiarizationDriver(() => spans);
  }

  @override
  Future<SherpaVadDriver> createVad(
    SherpaVadConfiguration configuration,
  ) async {
    vadConfigurations.add(configuration);
    return FakeVadDriver(() => speechSpans);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Recognizer that returns a scripted transcript.
final class FakeBatchAsrDriver implements SherpaBatchAsrDriver {
  /// Creates a fake recognizer.
  FakeBatchAsrDriver(this._transcript);

  final SherpaDriverTranscript Function() _transcript;

  /// Sample buffers handed to [transcribe].
  final List<Float32List> received = <Float32List>[];

  /// Whether [close] ran.
  bool closed = false;

  @override
  Future<SherpaDriverTranscript> transcribe(Float32List samples) async {
    received.add(samples);
    return _transcript();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Streaming recognizer that replays scripted decoder updates.
final class FakeStreamingAsrDriver implements SherpaStreamingAsrDriver {
  /// Creates a fake streaming recognizer.
  FakeStreamingAsrDriver({
    Iterable<SherpaDriverStreamingUpdate> updates =
        const <SherpaDriverStreamingUpdate>[],
    this.finishUpdate = SherpaDriverStreamingUpdate.empty,
    this.acceptDelays = const <Duration>[],
  }) : _updates = Queue<SherpaDriverStreamingUpdate>.of(updates);

  final Queue<SherpaDriverStreamingUpdate> _updates;

  /// Update returned by [finish].
  SherpaDriverStreamingUpdate finishUpdate;

  /// Delay applied to the nth [accept], so ordering can be tested.
  final List<Duration> acceptDelays;

  /// Thrown by the next [accept], then cleared.
  Object? acceptError;

  /// Sample buffers handed to [accept], in arrival order.
  final List<Float32List> received = <Float32List>[];

  /// Every driver call by name, so ordering against [reset] is observable.
  final List<String> calls = <String>[];

  /// Number of times [reset] ran.
  int resetCount = 0;

  /// Whether [close] ran.
  bool closed = false;

  @override
  Future<SherpaDriverStreamingUpdate> accept(Float32List samples) async {
    final index = received.length;
    received.add(samples);
    calls.add('accept');
    if (index < acceptDelays.length) {
      await Future<void>.delayed(acceptDelays[index]);
    }
    final error = acceptError;
    if (error != null) {
      acceptError = null;
      throw error;
    }
    if (_updates.isEmpty) {
      return SherpaDriverStreamingUpdate.empty;
    }
    return _updates.removeFirst();
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
    resetCount += 1;
  }

  @override
  Future<SherpaDriverStreamingUpdate> finish() async {
    calls.add('finish');
    return finishUpdate;
  }

  @override
  Future<void> close() async {
    calls.add('close');
    closed = true;
  }
}

/// Diarizer that returns scripted spans.
final class FakeDiarizationDriver implements SherpaDiarizationDriver {
  /// Creates a fake diarizer.
  FakeDiarizationDriver(this._spans);

  final List<SherpaDriverSpeakerSpan> Function() _spans;

  /// Whether [close] ran.
  bool closed = false;

  @override
  Future<List<SherpaDriverSpeakerSpan>> diarize(Float32List samples) async =>
      _spans();

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Detector that returns scripted speech spans on the first accept.
final class FakeVadDriver implements SherpaVadDriver {
  /// Creates a fake detector.
  FakeVadDriver(this._spans);

  final List<SherpaDriverSpeechSpan> Function() _spans;
  bool _delivered = false;

  /// Whether [close] ran.
  bool closed = false;

  @override
  Future<List<SherpaDriverSpeechSpan>> accept(Float32List samples) async {
    if (_delivered) {
      return const <SherpaDriverSpeechSpan>[];
    }
    _delivered = true;
    return _spans();
  }

  @override
  Future<List<SherpaDriverSpeechSpan>> flush() async =>
      const <SherpaDriverSpeechSpan>[];

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A finite in-memory source that emits one frame of [samples].
final class FakeAudioSource implements AudioSource {
  /// Creates a source over 16 kHz mono [samples].
  FakeAudioSource(this.samples, {this.sampleRate = 16000});

  /// Samples emitted as a single frame.
  final Float32List samples;

  /// Rate advertised by the session.
  final int sampleRate;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async => _FakeSourceSession(samples, sampleRate);
}

final class _FakeSourceSession implements AudioSourceSession {
  _FakeSourceSession(this._samples, int sampleRate)
    : format = AudioFormat(sampleRate: sampleRate, channels: 1);

  @override
  final String sourceId = 'fake-source';

  @override
  final String trackId = 'fake-track';

  @override
  final String clockId = 'fake-clock';

  final Float32List _samples;
  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast(sync: true);
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );

  @override
  final AudioFormat format;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

  void _transition(AudioSessionState state) {
    _status = AudioSessionStatus(state: state, timestamp: Duration.zero);
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    _transition(AudioSessionState.active);
    if (_samples.isNotEmpty) {
      _frames.add(
        AudioFrame.owned(
          format: format,
          samples: _samples,
          sourceId: sourceId,
          trackId: trackId,
          clockId: clockId,
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      );
    }
    _transition(AudioSessionState.finished);
    await _frames.close();
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {}

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {}

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    _transition(AudioSessionState.finished);
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    _transition(AudioSessionState.aborted);
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }

  @override
  Future<void> close() async {
    if (!_frames.isClosed) {
      await _frames.close();
    }
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      await _statuses.close();
    }
  }
}
