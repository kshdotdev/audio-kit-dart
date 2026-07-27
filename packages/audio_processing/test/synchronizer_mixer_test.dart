import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 10, channels: 1);

  test('aligns offset tracks and preserves their independent samples', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 4,
      maxLatenessBlocks: 1,
    );

    expect(
      synchronizer.add(
        _frame(format, 'mic', 0, Duration.zero, <double>[1, 2, 3, 4]),
      ),
      isEmpty,
    );
    final List<SynchronizedAudioBlock> first = synchronizer.add(
      _frame(format, 'system', 0, const Duration(milliseconds: 100), <double>[
        10,
        20,
        30,
        40,
      ]),
    );

    expect(first, hasLength(1));
    expect(first.single.frames['mic']!.samples, <double>[1, 2, 3, 4]);
    expect(first.single.frames['system']!.samples, <double>[0, 10, 20, 30]);
    expect(
      first.single.frames['system']!.discontinuity?.droppedSampleFrameCount,
      0,
    );

    expect(
      synchronizer.add(
        _frame(format, 'mic', 4, const Duration(milliseconds: 400), <double>[
          5,
          6,
          7,
          8,
        ]),
      ),
      isEmpty,
    );
    final List<SynchronizedAudioBlock> second = synchronizer.add(
      _frame(format, 'system', 4, const Duration(milliseconds: 500), <double>[
        50,
        60,
        70,
        80,
      ]),
    );
    expect(second.single.frames['mic']!.samples, <double>[5, 6, 7, 8]);
    expect(second.single.frames['system']!.samples, <double>[40, 50, 60, 70]);

    final List<SynchronizedAudioBlock> tail = synchronizer.flush();
    expect(tail, hasLength(1));
    expect(tail.single.frames['system']!.samples, <double>[80, 0, 0, 0]);
  });

  test(
    'bounded lateness lets a healthy track advance with explicit silence',
    () {
      final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
        format: format,
        trackIds: <String>{'mic', 'system'},
        blockFrameCount: 2,
        maxLatenessBlocks: 1,
      );

      final List<SynchronizedAudioBlock> output = synchronizer.add(
        _frame(format, 'mic', 0, Duration.zero, <double>[1, 2, 3, 4]),
      );

      expect(output, hasLength(1));
      expect(output.single.frames['system']!.samples, <double>[0, 0]);
      expect(
        output.single.frames['system']!.discontinuity?.droppedSampleFrameCount,
        0,
      );
    },
  );

  test('callback order can move the buffered origin before first output', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 4,
      maxLatenessBlocks: 1,
    );

    expect(
      synchronizer.add(
        _frame(format, 'mic', 0, const Duration(milliseconds: 400), <double>[
          5,
          6,
          7,
          8,
        ]),
      ),
      isEmpty,
    );

    final List<SynchronizedAudioBlock> output = synchronizer.add(
      _frame(format, 'system', 0, Duration.zero, <double>[1, 2, 3, 4]),
    );

    expect(output, hasLength(1));
    expect(output.single.sequence, 0);
    expect(output.single.timestamp, Duration.zero);
    expect(output.single.frames['system']!.samples, <double>[1, 2, 3, 4]);
    expect(output.single.frames['mic']!.samples, <double>[0, 0, 0, 0]);
  });

  test('rejects implicit cross-clock and late-frame merging', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 2,
      maxLatenessBlocks: 0,
    );
    synchronizer.add(_frame(format, 'mic', 0, Duration.zero, <double>[1, 2]));

    expect(
      () => synchronizer.add(
        _frame(format, 'system', 0, Duration.zero, <double>[
          3,
          4,
        ], clockId: 'another-clock'),
      ),
      throwsA(
        isA<AudioSynchronizationFailure>().having(
          (AudioSynchronizationFailure failure) => failure.code,
          'code',
          'clock_domain_mismatch',
        ),
      ),
    );
    expect(
      () => synchronizer.add(
        _frame(format, 'mic', 0, Duration.zero, <double>[1, 2]),
      ),
      throwsA(isA<AudioSynchronizationFailure>()),
    );
  });

  test('rejects huge sparse gaps before changing buffered timeline state', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 2,
      maxLatenessBlocks: 1,
      maxTimelineGapBlocks: 4,
      maxBufferedBlocks: 8,
    );
    expect(
      synchronizer.add(_frame(format, 'mic', 0, Duration.zero, <double>[1, 2])),
      isEmpty,
    );

    expect(
      () => synchronizer.add(
        _frame(format, 'system', 0, const Duration(days: 365), <double>[3, 4]),
      ),
      throwsA(
        isA<AudioSynchronizationFailure>().having(
          (AudioSynchronizationFailure failure) => failure.code,
          'code',
          'timeline_gap_exceeded',
        ),
      ),
    );

    final List<SynchronizedAudioBlock> output = synchronizer.add(
      _frame(format, 'system', 0, Duration.zero, <double>[3, 4]),
    );
    expect(output, hasLength(1));
    expect(output.single.frames['mic']!.samples, <double>[1, 2]);
    expect(output.single.frames['system']!.samples, <double>[3, 4]);
  });

  test('rejects an oversized input frame before block materialization', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic'},
      blockFrameCount: 2,
      maxLatenessBlocks: 0,
      maxBufferedBlocks: 2,
    );

    expect(
      () => synchronizer.add(
        _frame(format, 'mic', 0, Duration.zero, <double>[1, 2, 3, 4, 5, 6]),
      ),
      throwsA(
        isA<AudioSynchronizationFailure>().having(
          (AudioSynchronizationFailure failure) => failure.code,
          'code',
          'frame_exceeds_buffer_limit',
        ),
      ),
    );
  });

  test('fully missing blocks preserve the known track and clock identity', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 2,
      maxLatenessBlocks: 1,
    );
    expect(
      synchronizer.add(
        _frame(format, 'system', 0, Duration.zero, <double>[10, 20]),
      ),
      isEmpty,
    );
    expect(
      synchronizer.add(_frame(format, 'mic', 0, Duration.zero, <double>[1, 2])),
      hasLength(1),
    );

    final SynchronizedAudioBlock missing = synchronizer
        .add(
          _frame(format, 'mic', 2, const Duration(milliseconds: 200), <double>[
            3,
            4,
            5,
            6,
          ]),
        )
        .single;
    expect(missing.frames['system']!.samples, <double>[0, 0]);
    expect(missing.frames['system']!.sourceId, 'system-source');
    expect(missing.frames['system']!.trackId, 'system');
    expect(missing.frames['system']!.clockId, 'host-time');
  });

  test('synchronized blocks defensively copy their frame map', () {
    final AudioFrame frame = _frame(format, 'mic', 0, Duration.zero, <double>[
      1,
      2,
    ]);
    final Map<String, AudioFrame> mutable = <String, AudioFrame>{'mic': frame};
    final SynchronizedAudioBlock block = SynchronizedAudioBlock(
      sequence: 0,
      timestamp: Duration.zero,
      format: format,
      frames: mutable,
    );

    mutable
      ..clear()
      ..['replacement'] = frame;

    expect(block.frames.keys, <String>['mic']);
    expect(() => block.frames['replacement'] = frame, throwsUnsupportedError);
  });

  test('mixer applies gains, normalization, clipping, and gap metadata', () {
    final AudioFrame mic = _frame(format, 'mic', 0, Duration.zero, <double>[
      0.8,
      -0.8,
    ]);
    final AudioFrame system = _frame(
      format,
      'system',
      0,
      Duration.zero,
      <double>[0.8, -0.8],
      discontinuity: AudioDiscontinuity(
        reason: AudioDiscontinuityReason.unknown,
        droppedSampleFrameCount: 1,
      ),
    );
    final SynchronizedAudioBlock block = SynchronizedAudioBlock(
      sequence: 0,
      timestamp: Duration.zero,
      format: format,
      frames: <String, AudioFrame>{'mic': mic, 'system': system},
    );

    final AudioFrame clipped = AudioMixer().mix(block);
    expect(clipped.samples, <double>[1, -1]);
    expect(clipped.discontinuity?.droppedSampleFrameCount, 0);

    final AudioFrame normalized = AudioMixer(
      mode: AudioMixMode.normalized,
      gains: <String, double>{'mic': 1, 'system': 1},
    ).mix(block);
    expect(normalized.samples[0], closeTo(0.8, 1e-6));
    expect(normalized.samples[1], closeTo(-0.8, 1e-6));
  });

  test('materialized synchronized silence is not inserted twice by WAV', () {
    final AudioTimelineSynchronizer synchronizer = AudioTimelineSynchronizer(
      format: format,
      trackIds: <String>{'mic', 'system'},
      blockFrameCount: 2,
      maxLatenessBlocks: 0,
    );
    final List<SynchronizedAudioBlock> blocks = <SynchronizedAudioBlock>[
      ...synchronizer.add(
        _frame(format, 'mic', 0, Duration.zero, <double>[1, 2, 3, 4]),
      ),
      ...synchronizer.flush(),
    ];
    final AudioMixer mixer = AudioMixer();
    final WavEncoder encoder = WavEncoder(
      format: format,
      gapPolicy: WavGapPolicy.insertSilence,
    );
    for (final SynchronizedAudioBlock block in blocks) {
      final AudioFrame mixed = mixer.mix(block);
      expect(mixed.discontinuity?.droppedSampleFrameCount, 0);
      encoder.addFrame(mixed);
    }

    expect(inspectWav(encoder.finish()).sampleFrameCount, 4);
  });
}

AudioFrame _frame(
  AudioFormat format,
  String trackId,
  int sampleOffset,
  Duration timestamp,
  List<double> samples, {
  String clockId = 'host-time',
  AudioDiscontinuity? discontinuity,
}) => AudioFrame.owned(
  format: format,
  samples: Float32List.fromList(samples),
  sourceId: '$trackId-source',
  trackId: trackId,
  clockId: clockId,
  sequence: sampleOffset ~/ samples.length,
  sampleOffset: sampleOffset,
  timestamp: timestamp,
  discontinuity: discontinuity,
);
