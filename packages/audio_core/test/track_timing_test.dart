import 'dart:convert';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  group('MonotonicTrackTiming construction', () {
    test('defaults to a native-mapped map anchored at sample zero', () {
      final MonotonicTrackTiming timing = MonotonicTrackTiming(
        trackId: 'microphone',
        clockId: 'microphone-1.clock',
        sessionClockId: 'meeting-1.monotonic',
        sampleRate: 48000,
        startOffset: Duration.zero,
      );

      expect(timing.firstSampleOffset, 0);
      expect(timing.quality, MonotonicTrackTimingQuality.nativeMapped);
      expect(timing.startOffset, Duration.zero);
    });

    test('rejects blank identifiers', () {
      MonotonicTrackTiming build({
        String trackId = 'microphone',
        String clockId = 'microphone-1.clock',
        String sessionClockId = 'meeting-1.monotonic',
      }) => MonotonicTrackTiming(
        trackId: trackId,
        clockId: clockId,
        sessionClockId: sessionClockId,
        sampleRate: 48000,
        startOffset: Duration.zero,
      );

      expect(() => build(trackId: ''), throwsArgumentError);
      expect(() => build(trackId: '   '), throwsArgumentError);
      expect(() => build(clockId: ''), throwsArgumentError);
      expect(() => build(clockId: '\t'), throwsArgumentError);
      expect(() => build(sessionClockId: ''), throwsArgumentError);
      expect(() => build(sessionClockId: ' '), throwsArgumentError);
    });

    test('rejects non-positive sample rates and negative offsets', () {
      MonotonicTrackTiming build({
        int sampleRate = 48000,
        Duration startOffset = Duration.zero,
        int firstSampleOffset = 0,
      }) => MonotonicTrackTiming(
        trackId: 'microphone',
        clockId: 'microphone-1.clock',
        sessionClockId: 'meeting-1.monotonic',
        sampleRate: sampleRate,
        startOffset: startOffset,
        firstSampleOffset: firstSampleOffset,
      );

      expect(() => build(sampleRate: 0), throwsArgumentError);
      expect(() => build(sampleRate: -48000), throwsArgumentError);
      expect(
        () => build(startOffset: const Duration(microseconds: -1)),
        throwsArgumentError,
      );
      expect(() => build(firstSampleOffset: -1), throwsArgumentError);
      expect(build(firstSampleOffset: 0).firstSampleOffset, 0);
    });
  });

  group('MonotonicTrackTiming sample mapping', () {
    final MonotonicTrackTiming timing = MonotonicTrackTiming(
      trackId: 'system',
      clockId: 'pipewire.node.7',
      sessionClockId: 'meeting-9.monotonic',
      sampleRate: 1000,
      startOffset: const Duration(milliseconds: 25),
      firstSampleOffset: 100,
    );

    test('anchors the first mapped sample at the start offset', () {
      expect(timing.sessionTimestampForSample(100), timing.startOffset);
    });

    test('advances by integer microseconds from the first mapped sample', () {
      expect(
        timing.sessionTimestampForSample(1100),
        const Duration(milliseconds: 1025),
      );
      expect(
        timing.sessionTimestampForSample(101),
        const Duration(milliseconds: 26),
      );
    });

    test('floors sub-microsecond sample positions instead of rounding', () {
      final MonotonicTrackTiming fast = MonotonicTrackTiming(
        trackId: 'system',
        clockId: 'clock',
        sessionClockId: 'session.clock',
        sampleRate: 3000000,
        startOffset: Duration.zero,
      );

      expect(fast.sessionTimestampForSample(1), Duration.zero);
      expect(
        fast.sessionTimestampForSample(3),
        const Duration(microseconds: 1),
      );
      expect(
        fast.sessionTimestampForSample(5),
        const Duration(microseconds: 1),
      );
    });

    test('refuses to extrapolate before the first mapped sample', () {
      expect(() => timing.sessionTimestampForSample(99), throwsRangeError);
      expect(() => timing.sessionTimestampForSample(0), throwsRangeError);
      expect(() => timing.sessionTimestampForSample(-1), throwsRangeError);
    });
  });

  group('MonotonicTrackTiming durable JSON', () {
    test('round-trips every field through encoded JSON', () {
      final MonotonicTrackTiming timing = MonotonicTrackTiming(
        trackId: 'system',
        clockId: 'wasapi.render.default',
        sessionClockId: 'meeting-3.monotonic',
        sampleRate: 44100,
        startOffset: const Duration(microseconds: 1234567),
        firstSampleOffset: 512,
        quality: MonotonicTrackTimingQuality.synchronized,
      );

      final Map<String, Object?> encoded = _encodeJson(timing.toJson());
      final MonotonicTrackTiming decoded = MonotonicTrackTiming.fromJson(
        encoded,
      );

      expect(decoded.toJson(), timing.toJson());
      expect(decoded.trackId, timing.trackId);
      expect(decoded.clockId, timing.clockId);
      expect(decoded.sessionClockId, timing.sessionClockId);
      expect(decoded.sampleRate, timing.sampleRate);
      expect(decoded.startOffset, timing.startOffset);
      expect(decoded.firstSampleOffset, timing.firstSampleOffset);
      expect(decoded.quality, timing.quality);
    });

    test('pins the durable key and quality spellings', () {
      final MonotonicTrackTiming timing = MonotonicTrackTiming(
        trackId: 'microphone',
        clockId: 'coreaudio.device.42',
        sessionClockId: 'meeting-3.monotonic',
        sampleRate: 48000,
        startOffset: const Duration(milliseconds: 8),
        firstSampleOffset: 96,
        quality: MonotonicTrackTimingQuality.synthesized,
      );

      expect(timing.toJson(), <String, Object?>{
        'trackId': 'microphone',
        'clockId': 'coreaudio.device.42',
        'sessionClockId': 'meeting-3.monotonic',
        'sampleRate': 48000,
        'startOffsetMicroseconds': 8000,
        'firstSampleOffset': 96,
        'quality': 'synthesized',
      });
      expect(
        MonotonicTrackTimingQuality.values.map(
          (MonotonicTrackTimingQuality value) => value.name,
        ),
        <String>['nativeMapped', 'synchronized', 'synthesized'],
      );
    });

    test('rejects sidecars with missing or mistyped fields', () {
      final Map<String, Object?> valid = MonotonicTrackTiming(
        trackId: 'microphone',
        clockId: 'clock',
        sessionClockId: 'session.clock',
        sampleRate: 48000,
        startOffset: const Duration(milliseconds: 5),
        firstSampleOffset: 10,
      ).toJson();

      for (final String key in valid.keys) {
        final Map<String, Object?> missing = Map<String, Object?>.of(valid)
          ..remove(key);
        expect(
          () => MonotonicTrackTiming.fromJson(missing),
          throwsFormatException,
          reason: 'Removing "$key" must be rejected.',
        );
      }
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'trackId': '  ',
        }),
        throwsFormatException,
      );
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'sampleRate': '48000',
        }),
        throwsFormatException,
      );
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'startOffsetMicroseconds': 5000.0,
        }),
        throwsFormatException,
      );
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'quality': 'guessed',
        }),
        throwsFormatException,
      );
    });

    test('propagates constructor invariants out of fromJson', () {
      final Map<String, Object?> valid = MonotonicTrackTiming(
        trackId: 'microphone',
        clockId: 'clock',
        sessionClockId: 'session.clock',
        sampleRate: 48000,
        startOffset: Duration.zero,
      ).toJson();

      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'sampleRate': 0,
        }),
        throwsArgumentError,
      );
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'startOffsetMicroseconds': -1,
        }),
        throwsArgumentError,
      );
      expect(
        () => MonotonicTrackTiming.fromJson(<String, Object?>{
          ...valid,
          'firstSampleOffset': -1,
        }),
        throwsArgumentError,
      );
    });
  });

  group('capture session timing establishment', () {
    test('reuses the native clock as the session clock when mapped', () {
      for (final MonotonicTrackTimingQuality quality
          in <MonotonicTrackTimingQuality>[
            MonotonicTrackTimingQuality.nativeMapped,
            MonotonicTrackTimingQuality.synchronized,
          ]) {
        final MonotonicTrackTiming timing = _establishTiming(
          trackId: 'system',
          clockId: 'coreaudio.tap.9',
          sessionId: 'capture-session-1',
          format: AudioFormat(sampleRate: 48000, channels: 2),
          firstFrameTimestamp: const Duration(milliseconds: 12),
          firstFrameSampleOffset: 480,
          quality: quality,
        );

        expect(timing.sessionClockId, 'coreaudio.tap.9');
        expect(timing.clockId, timing.sessionClockId);
        expect(timing.quality, quality);
      }
    });

    test('synthesizes a session clock id when no native clock exists', () {
      final MonotonicTrackTiming timing = _establishTiming(
        trackId: 'microphone',
        clockId: 'pulse.source.1',
        sessionId: 'capture-session-7',
        format: AudioFormat(sampleRate: 16000, channels: 1),
        firstFrameTimestamp: const Duration(milliseconds: 250),
        firstFrameSampleOffset: 4000,
        quality: MonotonicTrackTimingQuality.synthesized,
      );

      expect(timing.sessionClockId, 'pulse.source.1.session.capture-session-7');
      expect(timing.sessionClockId, isNot(timing.clockId));
      expect(timing.quality, MonotonicTrackTimingQuality.synthesized);
    });

    test('maps the first captured frame back onto its own timestamp', () {
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
      final MonotonicTrackTiming timing = _establishTiming(
        trackId: 'microphone',
        clockId: 'pulse.source.1',
        sessionId: 'capture-session-7',
        format: format,
        firstFrameTimestamp: const Duration(milliseconds: 250),
        firstFrameSampleOffset: 4000,
        quality: MonotonicTrackTimingQuality.synthesized,
      );

      expect(timing.sampleRate, format.sampleRate);
      expect(timing.firstSampleOffset, 4000);
      expect(
        timing.sessionTimestampForSample(4000),
        const Duration(milliseconds: 250),
      );
      expect(
        timing.sessionTimestampForSample(4000 + 16000),
        const Duration(milliseconds: 1250),
      );
      expect(
        MonotonicTrackTiming.fromJson(_encodeJson(timing.toJson())).toJson(),
        timing.toJson(),
      );
    });

    test('carries the established mapping into a captured track manifest', () {
      final AudioFormat format = AudioFormat(sampleRate: 48000, channels: 2);
      final MonotonicTrackTiming timing = _establishTiming(
        trackId: 'system',
        clockId: 'coreaudio.tap.9',
        sessionId: 'capture-session-1',
        format: format,
        firstFrameTimestamp: const Duration(milliseconds: 12),
        firstFrameSampleOffset: 480,
        quality: MonotonicTrackTimingQuality.nativeMapped,
      );
      final CapturedAudioTrackManifest track = CapturedAudioTrackManifest(
        trackId: timing.trackId,
        artifactId: 'audio:meeting-1:system',
        source: AudioCaptureSourceIdentity(
          sourceId: 'coreaudio:tap:9',
          kind: AudioCaptureSourceKind.systemAudio,
        ),
        format: format,
        startOffset: timing.startOffset,
        timing: timing,
      );

      expect(
        CapturedAudioTrackManifest.fromJson(
          _encodeJson(track.toJson()),
        ).timing?.toJson(),
        timing.toJson(),
      );
    });
  });
}

/// Mirrors `_FlutterAudioCaptureSession._establishTiming` in `audio_flutter`.
MonotonicTrackTiming _establishTiming({
  required String trackId,
  required String clockId,
  required String sessionId,
  required AudioFormat format,
  required Duration firstFrameTimestamp,
  required int firstFrameSampleOffset,
  required MonotonicTrackTimingQuality quality,
}) => MonotonicTrackTiming(
  trackId: trackId,
  clockId: clockId,
  sessionClockId: quality == MonotonicTrackTimingQuality.synthesized
      ? '$clockId.session.$sessionId'
      : clockId,
  sampleRate: format.sampleRate,
  startOffset: firstFrameTimestamp,
  firstSampleOffset: firstFrameSampleOffset,
  quality: quality,
);

Map<String, Object?> _encodeJson(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map<String, dynamic>)
        .cast<String, Object?>();
