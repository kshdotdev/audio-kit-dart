import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';

import 'failure.dart';

/// The single rate every sherpa model in this package consumes.
const int sherpaSampleRate = 16000;

/// Stateful conversion from one fixed input format to 16 kHz mono float32.
///
/// sherpa-onnx consumes `Float32List` natively, so there is deliberately no
/// PCM16 detour here: frames stay in the sample format `audio_core` already
/// guarantees, and the only transforms are downmix and resample.
final class SherpaMonoConverter {
  /// Creates a converter fixed to [inputFormat].
  SherpaMonoConverter(this.inputFormat);

  /// Fixed caller-facing format.
  final AudioFormat inputFormat;

  final AudioDownmixer _downmixer = AudioDownmixer();
  final AudioResampler _resampler = AudioResampler(
    outputSampleRate: sherpaSampleRate,
  );
  AudioStreamKey? _stream;

  /// Converts one frame while retaining resampler state.
  List<AudioFrame> process(AudioFrame frame) {
    if (frame.format != inputFormat) {
      throw sherpaAudioFailure(
        'sherpa_format_mismatch',
        AudioFailureStage.processing,
        'The audio frame format does not match the prepared session.',
      );
    }
    if (frame.discontinuity != null) {
      throw sherpaAudioFailure(
        'sherpa_discontinuous_audio',
        AudioFailureStage.processing,
        'sherpa-onnx cannot safely process a discontinuous speech route.',
      );
    }
    final key = AudioStreamKey.fromFrame(frame);
    final existing = _stream;
    if (existing != null && existing != key) {
      throw sherpaAudioFailure(
        'sherpa_multiple_tracks',
        AudioFailureStage.processing,
        'A sherpa-onnx speech session accepts exactly one audio track.',
      );
    }
    _stream = key;

    final output = <AudioFrame>[];
    for (final mono in _downmixer.process(frame)) {
      output.addAll(_resampler.process(mono));
    }
    return output;
  }

  /// Flushes the resampler look-behind.
  List<AudioFrame> flush() {
    final key = _stream;
    if (key == null) {
      return const <AudioFrame>[];
    }
    return _resampler.flush(stream: key);
  }

  /// Discards all transform state.
  void reset() {
    _downmixer.reset();
    _resampler.reset();
    _stream = null;
  }
}

/// Collected 16 kHz mono float32 audio from a finite source.
final class SherpaCollectedAudio {
  /// Creates a collected-audio result.
  const SherpaCollectedAudio({required this.samples, required this.duration});

  /// Contiguous 16 kHz mono samples.
  final Float32List samples;

  /// Duration implied by [samples].
  final Duration duration;
}

/// Starts and drains a finite [source], returning 16 kHz mono float32 audio.
///
/// Subscribes before starting so no frame is missed, and always closes the
/// session it opened.
Future<SherpaCollectedAudio> collectSherpaAudio(
  AudioSource source, {
  required int maximumConvertedSamples,
  AudioCancellationToken? cancellation,
  void Function(double progress)? onProgress,
}) async {
  if (maximumConvertedSamples <= 0) {
    throw ArgumentError.value(
      maximumConvertedSamples,
      'maximumConvertedSamples',
      'Must be positive.',
    );
  }
  cancellation?.throwIfCancelled();
  onProgress?.call(0);

  AudioSourceSession? session;
  StreamSubscription<AudioFrame>? framesSubscription;
  StreamSubscription<AudioSessionStatus>? statusSubscription;
  final done = Completer<void>();
  Object? completionError;
  StackTrace? completionStackTrace;
  final Future<void> observedDone = done.future.catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    completionError = error;
    completionStackTrace = stackTrace;
  });
  final chunks = <Float32List>[];
  var sampleCount = 0;
  var acceptingFrames = true;
  SherpaMonoConverter? converter;

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!done.isCompleted) {
      acceptingFrames = false;
      done.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void append(AudioFrame output) {
    if (!acceptingFrames) {
      return;
    }
    if (output.samples.length > maximumConvertedSamples - sampleCount) {
      throw sherpaSpeechFailure(
        'sherpa_batch_audio_too_long',
        'preprocessing',
        'The audio source exceeds the configured sherpa batch limit.',
      );
    }
    final samples = Float32List.fromList(output.samples);
    chunks.add(samples);
    sampleCount += samples.length;
  }

  try {
    session = await source.prepare(cancellationToken: cancellation);
    cancellation?.throwIfCancelled();
    converter = SherpaMonoConverter(session.format);

    framesSubscription = session.frames.listen(
      (frame) {
        if (!acceptingFrames) {
          return;
        }
        try {
          for (final output in converter!.process(frame)) {
            append(output);
          }
        } catch (error, stackTrace) {
          completeError(error, stackTrace);
        }
      },
      onError: completeError,
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    statusSubscription = session.statuses.listen((status) {
      final failure = status.failure;
      if (status.state == AudioSessionState.failed && failure != null) {
        completeError(failure);
      }
    });

    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((_) async {
          if (!done.isCompleted) {
            completeError(AudioCancelledException(cancellation.cancellation!));
          }
          await session?.abort(
            failure: sherpaAudioFailure(
              'sherpa_cancelled',
              AudioFailureStage.provider,
              'The sherpa-onnx operation was cancelled.',
            ),
          );
        }),
      );
    }

    await session.start(cancellationToken: cancellation);
    onProgress?.call(0.25);
    await observedDone;
    if (completionError case final Object error) {
      Error.throwWithStackTrace(
        error,
        completionStackTrace ?? StackTrace.current,
      );
    }

    for (final output in converter.flush()) {
      append(output);
    }
    onProgress?.call(0.5);
  } finally {
    await framesSubscription?.cancel();
    await statusSubscription?.cancel();
    await session?.close();
  }

  final samples = Float32List(sampleCount);
  var offset = 0;
  for (final chunk in chunks) {
    samples.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return SherpaCollectedAudio(
    samples: samples,
    duration: AudioFormat(
      sampleRate: sherpaSampleRate,
      channels: 1,
    ).durationForFrames(sampleCount),
  );
}
