import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'speech_activity.dart';

// Derived from Control Center's `meeting_transcription_service.dart`
// (MIT © 2026 Samuel Alev): the rolling-window cut policy, the silent-window
// skip, in-order decoding, and the per-stream generation guard. Adapted to
// consume float32 [AudioFrame]s and to buffer internally rather than pausing
// upstream, because realtime audio sources reject `pause`. See NOTICE.

/// A cut window of contiguous audio, positioned on its track's timeline.
final class AudioWindow {
  /// Creates a window that takes ownership of [samples].
  AudioWindow.owned({
    required this.format,
    required this.samples,
    required this.trackId,
    required this.start,
    required this.end,
  });

  /// PCM layout of [samples].
  final AudioFormat format;

  /// Interleaved float32 samples for this window.
  final Float32List samples;

  /// Track the window was cut from.
  final String trackId;

  /// Inclusive start offset from the track's first sample.
  final Duration start;

  /// Exclusive end offset from the track's first sample.
  final Duration end;

  /// Length of the window.
  Duration get duration => end - start;

  /// Builds a cold, finite source over this window for a batch provider.
  BufferedAudioSource toSource({String sourceId = 'speech_pipeline.window'}) =>
      BufferedAudioSource.owned(
        format: format,
        samples: samples,
        sourceId: sourceId,
        trackId: trackId,
      );
}

/// Cut policy for [AudioWindowCutter].
final class WindowCutPolicy {
  /// Creates a policy.
  const WindowCutPolicy({
    this.minWindow = const Duration(milliseconds: 1500),
    this.maxWindow = const Duration(milliseconds: 5000),
    this.silenceFlush = const Duration(milliseconds: 650),
  });

  /// Minimum audio accumulated before a silence-triggered cut is allowed.
  final Duration minWindow;

  /// Hard cap that forces a cut even without trailing silence.
  final Duration maxWindow;

  /// Trailing silence that triggers a cut once past [minWindow].
  final Duration silenceFlush;

  void _validate() {
    if (minWindow <= Duration.zero) {
      throw ArgumentError.value(minWindow, 'minWindow', 'Must be positive.');
    }
    if (maxWindow < minWindow) {
      throw ArgumentError.value(
        maxWindow,
        'maxWindow',
        'Must not precede minWindow.',
      );
    }
    if (silenceFlush <= Duration.zero) {
      throw ArgumentError.value(
        silenceFlush,
        'silenceFlush',
        'Must be positive.',
      );
    }
  }
}

/// Cuts a continuous frame stream into decodable windows.
///
/// A window is cut when trailing silence reaches [WindowCutPolicy.silenceFlush]
/// and the window already holds [WindowCutPolicy.minWindow] of audio, or when
/// it reaches [WindowCutPolicy.maxWindow].
///
/// Windows that never crossed the speech gate are dropped without being
/// emitted: recognizers render silence as hallucinated non-speech tokens, and a
/// quiet track would otherwise produce a decode roughly every
/// [WindowCutPolicy.minWindow] for nothing.
final class AudioWindowCutter {
  /// Creates a cutter.
  AudioWindowCutter({
    this.policy = const WindowCutPolicy(),
    SpeechActivityDetector Function()? detectorFactory,
  }) : _detectorFactory = detectorFactory ?? RmsSpeechActivityDetector.new {
    policy._validate();
  }

  /// Cut policy applied to every stream.
  final WindowCutPolicy policy;

  final SpeechActivityDetector Function() _detectorFactory;

  /// Cuts [frames] into windows containing speech.
  ///
  /// A fresh detector is built per call, so each track carries independent
  /// gate state. Frames must share one format; a format change ends the
  /// current window and starts a new one.
  Stream<AudioWindow> cut(Stream<AudioFrame> frames) {
    final controller = StreamController<AudioWindow>();
    final detector = _detectorFactory()..reset();
    final pending = <Float32List>[];

    AudioFormat? format;
    String trackId = 'audio';
    var pendingSampleCount = 0;
    var windowStartSampleFrames = 0;
    var consumedSampleFrames = 0;
    var trailingSilence = Duration.zero;
    var windowHadSpeech = false;

    Duration offsetFor(int sampleFrames) =>
        format?.durationForFrames(sampleFrames) ?? Duration.zero;

    void flush() {
      final activeFormat = format;
      if (activeFormat == null || pendingSampleCount == 0) {
        pending.clear();
        pendingSampleCount = 0;
        windowHadSpeech = false;
        return;
      }
      final hadSpeech = windowHadSpeech;
      windowHadSpeech = false;

      final merged = Float32List(pendingSampleCount);
      var cursor = 0;
      for (final chunk in pending) {
        merged.setRange(cursor, cursor + chunk.length, chunk);
        cursor += chunk.length;
      }
      pending.clear();
      final sampleFrames = pendingSampleCount ~/ activeFormat.channels;
      pendingSampleCount = 0;

      final start = offsetFor(windowStartSampleFrames);
      final end = offsetFor(windowStartSampleFrames + sampleFrames);
      windowStartSampleFrames += sampleFrames;

      if (!hadSpeech) {
        // Pure-silence window: never worth a decode.
        return;
      }
      if (!controller.isClosed) {
        controller.add(
          AudioWindow.owned(
            format: activeFormat,
            samples: merged,
            trackId: trackId,
            start: start,
            end: end,
          ),
        );
      }
    }

    late StreamSubscription<AudioFrame> subscription;
    subscription = frames.listen(
      (frame) {
        if (format != null && frame.format != format) {
          flush(); // Format changed: close the window before switching.
        }
        format = frame.format;
        trackId = frame.trackId;

        pending.add(frame.samples);
        pendingSampleCount += frame.samples.length;
        final frameSampleFrames = frame.samples.length ~/ frame.format.channels;
        consumedSampleFrames += frameSampleFrames;

        if (detector.isSpeech(frame.samples)) {
          trailingSilence = Duration.zero;
          windowHadSpeech = true;
        } else {
          trailingSilence += frame.format.durationForFrames(frameSampleFrames);
        }

        final windowLength = offsetFor(
          consumedSampleFrames - windowStartSampleFrames,
        );
        final hitSilence =
            trailingSilence >= policy.silenceFlush &&
            windowLength >= policy.minWindow;
        final hitMax = windowLength >= policy.maxWindow;
        if (hitSilence || hitMax) {
          trailingSilence = Duration.zero;
          flush();
        }
      },
      onError: controller.addError,
      onDone: () async {
        flush();
        detector.dispose();
        await controller.close();
      },
      cancelOnError: false,
    );

    controller.onCancel = () async {
      detector.dispose();
      await subscription.cancel();
    };
    return controller.stream;
  }
}
