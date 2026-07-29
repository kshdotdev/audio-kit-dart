import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

final AudioFormat _format = AudioFormat(sampleRate: 16000, channels: 1);

/// 100 ms of audio at [amplitude] on the normalized scale.
Float32List _chunk(double amplitude, {int sampleCount = 1600}) {
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = amplitude * math.sin(2 * math.pi * 220 * i / 16000);
  }
  return samples;
}

final class _FrameBuilder {
  int _sequence = 0;
  int _sampleOffset = 0;

  AudioFrame next(Float32List samples, {String trackId = 'me'}) {
    final frame = AudioFrame.owned(
      format: _format,
      samples: samples,
      sourceId: 'test.source',
      trackId: trackId,
      clockId: 'test.clock',
      sequence: _sequence++,
      sampleOffset: _sampleOffset,
      timestamp: _format.durationForFrames(_sampleOffset),
    );
    _sampleOffset += samples.length;
    return frame;
  }
}

/// Speech chunks then silence chunks, 100 ms each.
Stream<AudioFrame> _frames({required int speech, required int silence}) {
  final builder = _FrameBuilder();
  return Stream<AudioFrame>.fromIterable(<AudioFrame>[
    for (var i = 0; i < speech; i++) builder.next(_chunk(0.3)),
    for (var i = 0; i < silence; i++) builder.next(_chunk(0.0001)),
  ]);
}

void main() {
  group('WindowCutPolicy', () {
    test('rejects an inverted or non-positive policy', () {
      expect(
        () => AudioWindowCutter(
          policy: const WindowCutPolicy(
            minWindow: Duration(seconds: 3),
            maxWindow: Duration(seconds: 1),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => AudioWindowCutter(
          policy: const WindowCutPolicy(minWindow: Duration.zero),
        ),
        throwsArgumentError,
      );
    });

    test('defaults match the reference cut policy', () {
      const policy = WindowCutPolicy();
      expect(policy.minWindow, const Duration(milliseconds: 1500));
      expect(policy.maxWindow, const Duration(milliseconds: 5000));
      expect(policy.silenceFlush, const Duration(milliseconds: 650));
    });
  });

  group('AudioWindowCutter', () {
    test('cuts on trailing silence once past the minimum window', () async {
      final cutter = AudioWindowCutter();
      // 1.6 s of speech, then 0.7 s of silence crosses the flush threshold.
      final windows = await cutter
          .cut(_frames(speech: 16, silence: 7))
          .toList();

      expect(windows, hasLength(1));
      expect(windows.single.start, Duration.zero);
      // The cut lands once trailing silence reaches 650 ms.
      expect(
        windows.single.duration.inMilliseconds,
        allOf(greaterThanOrEqualTo(1500), lessThanOrEqualTo(2400)),
      );
      expect(windows.single.trackId, 'me');
    });

    test('does not cut on silence before the minimum window', () async {
      final cutter = AudioWindowCutter();
      // 0.5 s of speech then 0.7 s of silence: under the 1.5 s floor, so the
      // only window is the one flushed when the stream closes.
      final windows = await cutter.cut(_frames(speech: 5, silence: 7)).toList();

      expect(windows, hasLength(1));
      expect(windows.single.duration.inMilliseconds, 1200);
    });

    test('cuts at the hard cap without any silence', () async {
      final cutter = AudioWindowCutter();
      // 6 s of continuous speech must cut at the 5 s cap.
      final windows = await cutter
          .cut(_frames(speech: 60, silence: 0))
          .toList();

      expect(windows, hasLength(2));
      expect(windows.first.duration, const Duration(milliseconds: 5000));
      expect(windows.first.end, const Duration(milliseconds: 5000));
      expect(windows.last.start, const Duration(milliseconds: 5000));
    });

    test('skips windows that never crossed the speech gate', () async {
      final cutter = AudioWindowCutter();
      // Pure silence: nothing is ever worth a decode.
      final windows = await cutter
          .cut(_frames(speech: 0, silence: 60))
          .toList();

      expect(windows, isEmpty);
    });

    test('flushes a trailing partial window when the stream closes', () async {
      final cutter = AudioWindowCutter();
      final windows = await cutter.cut(_frames(speech: 8, silence: 0)).toList();

      expect(windows, hasLength(1));
      expect(windows.single.duration, const Duration(milliseconds: 800));
    });

    test('emits contiguous windows across a long stream', () async {
      final cutter = AudioWindowCutter();
      final windows = await cutter
          .cut(_frames(speech: 120, silence: 0))
          .toList();

      expect(windows.length, greaterThan(1));
      for (var i = 1; i < windows.length; i++) {
        expect(windows[i].start, windows[i - 1].end);
      }
    });

    test('window samples convert to a finite source for a provider', () async {
      final cutter = AudioWindowCutter();
      final windows = await cutter.cut(_frames(speech: 8, silence: 0)).toList();
      final source = windows.single.toSource();

      expect(source.format, _format);
      expect(source.trackId, 'me');
      expect(source.samples.length, windows.single.samples.length);
    });

    test('honours an injected detector factory', () async {
      var built = 0;
      final cutter = AudioWindowCutter(
        detectorFactory: () {
          built++;
          return const _AlwaysSilent();
        },
      );

      final windows = await cutter
          .cut(_frames(speech: 30, silence: 0))
          .toList();

      // The gate never fires, so every window is skipped as silent.
      expect(built, 1);
      expect(windows, isEmpty);
    });

    test('builds one detector per stream', () async {
      var built = 0;
      final cutter = AudioWindowCutter(
        detectorFactory: () {
          built++;
          return const RmsSpeechActivityDetector();
        },
      );

      await cutter.cut(_frames(speech: 4, silence: 0)).toList();
      await cutter.cut(_frames(speech: 4, silence: 0)).toList();

      expect(built, 2);
    });

    test('forwards source errors', () async {
      final cutter = AudioWindowCutter();
      final frames = Stream<AudioFrame>.error(StateError('capture died'));

      expect(cutter.cut(frames).toList(), throwsStateError);
    });

    test('stops consuming when the consumer cancels', () async {
      final controller = StreamController<AudioFrame>();
      final builder = _FrameBuilder();
      final cutter = AudioWindowCutter();

      final subscription = cutter.cut(controller.stream).listen((_) {});
      controller.add(builder.next(_chunk(0.3)));
      await pumpEventQueue();
      await subscription.cancel();

      expect(controller.hasListener, isFalse);
      await controller.close();
    });
  });
}

final class _AlwaysSilent implements SpeechActivityDetector {
  const _AlwaysSilent();

  @override
  bool isSpeech(Float32List samples) => false;

  @override
  void reset() {}

  @override
  void dispose() {}
}
