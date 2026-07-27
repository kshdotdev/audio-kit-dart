import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  group('AudioDownmixer', () {
    test('averages every interleaved channel without clipping', () {
      final downmixer = AudioDownmixer();
      final output = downmixer
          .process(_frame(<double>[1, -1, 0.75, 0.25, -0.5, -0.5], channels: 2))
          .single;

      expect(output.format.channels, 1);
      expect(output.samples, orderedEquals(<double>[0, 0.5, -0.5]));
      expect(output.sequence, 0);
      expect(output.sampleOffset, 0);
    });

    test(
      'keeps format state independent and requires explicit format changes',
      () {
        final downmixer = AudioDownmixer();
        downmixer.process(_frame(<double>[0, 0], channels: 2, trackId: 'a'));
        downmixer.process(_frame(<double>[0, 0, 0], channels: 3, trackId: 'b'));

        expect(
          () => downmixer.process(
            _frame(<double>[0, 0, 0], channels: 3, trackId: 'a'),
          ),
          throwsStateError,
        );
        expect(
          downmixer.process(
            _frame(
              <double>[0, 0, 0],
              channels: 3,
              trackId: 'a',
              discontinuity: AudioDiscontinuity(
                reason: AudioDiscontinuityReason.formatChange,
              ),
            ),
          ),
          hasLength(1),
        );
      },
    );
  });

  group('AudioResampler', () {
    test(
      'upsamples continuously and is invariant to input chunk boundaries',
      () {
        final whole = AudioResampler(outputSampleRate: 8);
        final wholeOutput = <AudioFrame>[
          ...whole.process(_frame(<double>[0, 1, 2, 3], sampleRate: 4)),
          ...whole.flush(),
        ].expand((frame) => frame.samples).toList();

        final chunked = AudioResampler(outputSampleRate: 8);
        final chunkedOutput = <AudioFrame>[
          ...chunked.process(_frame(<double>[0, 1], sampleRate: 4)),
          ...chunked.process(
            _frame(
              <double>[2, 3],
              sampleRate: 4,
              sequence: 1,
              sampleOffset: 2,
              timestamp: const Duration(milliseconds: 500),
            ),
          ),
          ...chunked.flush(),
        ].expand((frame) => frame.samples).toList();

        expect(wholeOutput, closeToList(<double>[0, 0.5, 1, 1.5, 2, 2.5, 3]));
        expect(chunkedOutput, closeToList(wholeOutput));
      },
    );

    test('downsamples and maintains independent state per track', () {
      final resampler = AudioResampler(outputSampleRate: 2);
      final a = <AudioFrame>[
        ...resampler.process(
          _frame(<double>[0, 1, 2], sampleRate: 4, trackId: 'a'),
        ),
        ...resampler.process(
          _frame(
            <double>[3, 4],
            sampleRate: 4,
            trackId: 'a',
            sequence: 1,
            sampleOffset: 3,
          ),
        ),
      ];
      final b = resampler.process(
        _frame(<double>[10, 11, 12], sampleRate: 4, trackId: 'b'),
      );
      final tails = resampler.flush();

      final aSamples = <double>[
        ...a.expand((frame) => frame.samples),
        ...tails
            .where((frame) => frame.trackId == 'a')
            .expand((frame) => frame.samples),
      ];
      final bSamples = <double>[
        ...b.expand((frame) => frame.samples),
        ...tails
            .where((frame) => frame.trackId == 'b')
            .expand((frame) => frame.samples),
      ];
      expect(aSamples, closeToList(<double>[0, 2, 4]));
      expect(bSamples, closeToList(<double>[10, 12]));
    });

    test('resets timeline state at discontinuities', () {
      final resampler = AudioResampler(outputSampleRate: 8);
      resampler.process(_frame(<double>[0, 1], sampleRate: 4));
      final restarted = resampler
          .process(
            _frame(
              <double>[10, 11],
              sampleRate: 4,
              sequence: 8,
              sampleOffset: 40,
              timestamp: const Duration(seconds: 2),
              discontinuity: AudioDiscontinuity(
                reason: AudioDiscontinuityReason.sourceRestart,
              ),
            ),
          )
          .single;

      expect(restarted.sampleOffset, 80);
      expect(restarted.timestamp, const Duration(seconds: 2));
      expect(
        restarted.discontinuity?.reason,
        AudioDiscontinuityReason.sourceRestart,
      );
      expect(restarted.samples, closeToList(<double>[10, 10.5]));
    });

    test('scales dropped sample-frame counts onto the output timeline', () {
      final upsampler = AudioResampler(outputSampleRate: 8);
      final AudioFrame upsampled = upsampler
          .process(
            _frame(
              <double>[10, 11],
              sampleRate: 4,
              sequence: 4,
              sampleOffset: 4,
              timestamp: const Duration(seconds: 1),
              discontinuity: AudioDiscontinuity(
                reason: AudioDiscontinuityReason.droppedFrames,
                droppedFrameCount: 1,
                droppedSampleFrameCount: 2,
                previousSequence: 2,
              ),
            ),
          )
          .single;
      expect(upsampled.sampleOffset, 8);
      expect(upsampled.discontinuity?.droppedFrameCount, 1);
      expect(upsampled.discontinuity?.droppedSampleFrameCount, 4);
      expect(upsampled.discontinuity?.previousSequence, 2);

      final downsampler = AudioResampler(outputSampleRate: 2);
      final AudioFrame downsampled = downsampler
          .process(
            _frame(
              <double>[10, 11, 12],
              sampleRate: 4,
              discontinuity: AudioDiscontinuity(
                reason: AudioDiscontinuityReason.droppedFrames,
                droppedSampleFrameCount: 2,
              ),
            ),
          )
          .single;
      expect(downsampled.discontinuity?.droppedSampleFrameCount, 1);
    });

    test('reports inferred offset gaps in output-rate sample frames', () {
      final AudioResampler resampler = AudioResampler(outputSampleRate: 8);
      final AudioFrame first = resampler
          .process(_frame(<double>[0, 1], sampleRate: 4))
          .single;
      final AudioFrame restarted = resampler
          .process(
            _frame(
              <double>[4, 5],
              sampleRate: 4,
              sequence: 1,
              sampleOffset: 4,
              timestamp: const Duration(seconds: 1),
            ),
          )
          .single;

      expect(first.endSampleOffset, 2);
      expect(restarted.sampleOffset, 8);
      expect(restarted.timestamp, const Duration(seconds: 1));
      expect(restarted.discontinuity?.droppedSampleFrameCount, 4);
    });
  });

  group('AudioRechunker', () {
    test(
      'emits fixed chunks and a correctly timestamped final partial frame',
      () {
        final rechunker = AudioRechunker(targetFrameCount: 4);
        final output = <AudioFrame>[
          ...rechunker.process(_frame(<double>[0, 1])),
          ...rechunker.process(
            _frame(
              <double>[2, 3, 4],
              sequence: 1,
              sampleOffset: 2,
              timestamp: const Duration(milliseconds: 2),
            ),
          ),
          ...rechunker.flush(),
        ];

        expect(output, hasLength(2));
        expect(output[0].samples, orderedEquals(<double>[0, 1, 2, 3]));
        expect(output[0].sampleOffset, 0);
        expect(output[1].samples, orderedEquals(<double>[4]));
        expect(output[1].sampleOffset, 4);
        expect(output[1].timestamp, const Duration(milliseconds: 4));
      },
    );

    test('does not couple interleaved logical tracks', () {
      final rechunker = AudioRechunker(targetFrameCount: 3);
      expect(rechunker.process(_frame(<double>[1, 2], trackId: 'a')), isEmpty);
      final b = rechunker.process(_frame(<double>[10, 11, 12], trackId: 'b'));
      final a = rechunker.process(
        _frame(<double>[3], trackId: 'a', sequence: 1, sampleOffset: 2),
      );

      expect(a.single.samples, orderedEquals(<double>[1, 2, 3]));
      expect(b.single.samples, orderedEquals(<double>[10, 11, 12]));
    });

    test('flushes old partial content before a discontinuity', () {
      final rechunker = AudioRechunker(targetFrameCount: 4);
      rechunker.process(_frame(<double>[0, 1]));
      final output = rechunker.process(
        _frame(
          <double>[8, 9, 10, 11],
          sequence: 10,
          sampleOffset: 8,
          discontinuity: AudioDiscontinuity(
            reason: AudioDiscontinuityReason.droppedFrames,
            droppedFrameCount: 1,
            droppedSampleFrameCount: 6,
          ),
        ),
      );

      expect(output, hasLength(2));
      expect(output[0].samples, orderedEquals(<double>[0, 1]));
      expect(output[1].samples, orderedEquals(<double>[8, 9, 10, 11]));
      expect(
        output[1].discontinuity?.reason,
        AudioDiscontinuityReason.droppedFrames,
      );
    });
  });

  group('AudioMeter', () {
    test('reports aggregate and per-channel RMS, peak, and dBFS', () {
      final meter = AudioMeter();
      final reading = meter.process(_frame(<double>[1, 0, -1, 0], channels: 2));

      expect(reading.rms, closeTo(1 / math.sqrt(2), 1e-10));
      expect(reading.peak, 1);
      expect(reading.decibelsFullScale, closeTo(-3.0102999566, 1e-9));
      expect(reading.rmsByChannel[0], 1);
      expect(reading.rmsByChannel[1], 0);
      expect(reading.peakByChannel, orderedEquals(<double>[1, 0]));
    });

    test('smooths each track independently and resets on discontinuity', () {
      final meter = AudioMeter(
        attack: const Duration(milliseconds: 1),
        release: const Duration(seconds: 1),
      );
      meter.process(_frame(<double>[1], trackId: 'a'));
      final falling = meter.process(
        _frame(<double>[0], trackId: 'a', sequence: 1, sampleOffset: 1),
      );
      final independent = meter.process(_frame(<double>[0], trackId: 'b'));
      final reset = meter.process(
        _frame(
          <double>[0],
          trackId: 'a',
          sequence: 2,
          sampleOffset: 2,
          discontinuity: AudioDiscontinuity(
            reason: AudioDiscontinuityReason.clockReset,
          ),
        ),
      );

      expect(falling.smoothedRms, greaterThan(0.9));
      expect(independent.smoothedRms, 0);
      expect(reset.smoothedRms, 0);
      expect(independent.decibelsFullScale, -120);
    });
  });

  group('WavEncoder', () {
    test('writes a valid canonical PCM16 header and quantized samples', () {
      final encoder = WavEncoder(
        format: AudioFormat(sampleRate: 16000, channels: 1),
      );
      encoder.addFrame(_frame(<double>[-1, 0, 1], sampleRate: 16000));
      final bytes = encoder.finish();
      final info = inspectWav(bytes);
      final data = ByteData.sublistView(bytes);

      expect(info.formatCode, 1);
      expect(info.channels, 1);
      expect(info.sampleRate, 16000);
      expect(info.bitsPerSample, 16);
      expect(info.sampleFrameCount, 3);
      expect(data.getInt16(44, Endian.little), -32768);
      expect(data.getInt16(46, Endian.little), 0);
      expect(data.getInt16(48, Endian.little), 32767);
      expect(encoder.finish(), orderedEquals(bytes));
      expect(
        () => encoder.addFrame(_frame(<double>[0], sampleRate: 16000)),
        throwsStateError,
      );
    });

    test('writes IEEE float WAV samples', () {
      final encoder = WavEncoder(
        format: AudioFormat(sampleRate: 48000, channels: 2),
        encoding: WavSampleEncoding.float32,
      );
      encoder.addFrame(
        _frame(<double>[0.25, -0.5], sampleRate: 48000, channels: 2),
      );
      final bytes = encoder.finish();
      final info = inspectWav(bytes);
      final data = ByteData.sublistView(bytes);

      expect(info.formatCode, 3);
      expect(info.bitsPerSample, 32);
      expect(data.getFloat32(44, Endian.little), closeTo(0.25, 1e-7));
      expect(data.getFloat32(48, Endian.little), closeTo(-0.5, 1e-7));
    });

    test('rejects gaps by default and can explicitly insert silence', () {
      final format = AudioFormat(sampleRate: 1000, channels: 1);
      final strict = WavEncoder(format: format);
      strict.addFrame(_frame(<double>[1, 1]));
      expect(
        () =>
            strict.addFrame(_frame(<double>[1], sequence: 1, sampleOffset: 4)),
        throwsStateError,
      );

      final filling = WavEncoder(
        format: format,
        gapPolicy: WavGapPolicy.insertSilence,
      );
      filling
        ..addFrame(_frame(<double>[1, 1]))
        ..addFrame(_frame(<double>[1], sequence: 1, sampleOffset: 4));
      final bytes = filling.finish();
      final info = inspectWav(bytes);
      final data = ByteData.sublistView(bytes);

      expect(info.sampleFrameCount, 5);
      expect(data.getInt16(48, Endian.little), 0);
      expect(data.getInt16(50, Endian.little), 0);
      expect(data.getInt16(52, Endian.little), 32767);
    });

    test('does not label a discontinuous first frame as lossless', () {
      final format = AudioFormat(sampleRate: 1000, channels: 1);
      final discontinuous = _frame(
        <double>[1],
        sequence: 4,
        sampleOffset: 8,
        discontinuity: AudioDiscontinuity(
          reason: AudioDiscontinuityReason.droppedFrames,
          droppedFrameCount: 2,
          droppedSampleFrameCount: 2,
        ),
      );

      expect(
        () => WavEncoder(format: format).addFrame(discontinuous),
        throwsStateError,
      );

      final filling = WavEncoder(
        format: format,
        gapPolicy: WavGapPolicy.insertSilence,
      )..addFrame(discontinuous);
      final bytes = filling.finish();
      expect(inspectWav(bytes).sampleFrameCount, 3);
      final data = ByteData.sublistView(bytes);
      expect(data.getInt16(44, Endian.little), 0);
      expect(data.getInt16(46, Endian.little), 0);
      expect(data.getInt16(48, Endian.little), 32767);
    });

    test('encodes simultaneous tracks independently', () {
      final encoder = MultiTrackWavEncoder();
      encoder
        ..addFrame(_frame(<double>[1], trackId: 'a'))
        ..addFrame(_frame(<double>[0, 0], trackId: 'b'));
      final files = encoder.finishAll();

      expect(files, hasLength(2));
      expect(
        inspectWav(
          files.entries.singleWhere((entry) => entry.key.trackId == 'a').value,
        ).sampleFrameCount,
        1,
      );
      expect(
        inspectWav(
          files.entries.singleWhere((entry) => entry.key.trackId == 'b').value,
        ).sampleFrameCount,
        2,
      );
      expect(encoder.streams, isEmpty);
    });

    test('rejects malformed or truncated files', () {
      expect(() => inspectWav(Uint8List(2)), throwsFormatException);
      final valid = WavEncoder(
        format: AudioFormat(sampleRate: 1000, channels: 1),
      )..addFrame(_frame(<double>[0]));
      final truncated = valid.finish().sublist(0, 44);
      expect(() => inspectWav(truncated), throwsFormatException);
    });
  });
}

AudioFrame _frame(
  List<double> samples, {
  int sampleRate = 1000,
  int channels = 1,
  String trackId = 'track',
  int sequence = 0,
  int sampleOffset = 0,
  Duration timestamp = Duration.zero,
  AudioDiscontinuity? discontinuity,
}) => AudioFrame(
  format: AudioFormat(sampleRate: sampleRate, channels: channels),
  samples: Float32List.fromList(samples),
  sourceId: 'source',
  trackId: trackId,
  clockId: 'clock',
  sequence: sequence,
  sampleOffset: sampleOffset,
  timestamp: timestamp,
  discontinuity: discontinuity,
);

Matcher closeToList(List<double> expected, {double delta = 1e-6}) =>
    pairwiseCompare<double, double>(
      expected,
      (actual, value) => (actual - value).abs() <= delta,
      'values within $delta',
    );
