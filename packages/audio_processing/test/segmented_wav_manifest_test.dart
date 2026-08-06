import 'dart:convert';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  group('durable segmented WAV sidecar format', () {
    test('round-trips every populated field through encoded JSON', () {
      final SegmentedWavRecordingManifest manifest = _fullManifest();

      final Map<String, Object?> encoded = _encodeJson(manifest.toJson());
      final SegmentedWavRecordingManifest decoded =
          SegmentedWavRecordingManifest.fromJson(encoded);

      expect(decoded.toJson(), manifest.toJson());
      expect(decoded.recordingId, 'meeting-7');
      expect(decoded.sourceId, 'microphone-1');
      expect(decoded.trackId, 'microphone');
      expect(decoded.clockId, 'microphone-1.clock');
      expect(decoded.format, AudioFormat(sampleRate: 48000, channels: 2));
      expect(decoded.encoding, WavSampleEncoding.pcm16);
      expect(decoded.segmentFrameCount, 8);
      expect(decoded.queueCapacityFrames, 64);
      expect(decoded.queuePolicy, SegmentedWavQueuePolicy.dropOldest);
      expect(decoded.gapPolicy, WavGapPolicy.insertSilence);
      expect(decoded.state, SegmentedWavRecordingState.failed);
      expect(decoded.revision, 5);
      expect(decoded.totalFrameCount, 13);
      expect(decoded.droppedFrameCount, 2);
      expect(decoded.failureCode, 'segmented_wav_io_failed');
      expect(decoded.failureMessage, 'The recording segment append failed.');
      expect(decoded.segments.length, 2);
      expect(decoded.markers.length, 3);
      expect(
        decoded.markers.map((SegmentedWavMarker marker) => marker.type),
        <SegmentedWavMarkerType>[
          SegmentedWavMarkerType.pause,
          SegmentedWavMarkerType.resume,
          SegmentedWavMarkerType.sourceChange,
        ],
      );
    });

    test('pins the on-disk shape of a fully populated sidecar', () {
      expect(_fullManifest().toJson(), <String, Object?>{
        'schemaVersion': 1,
        'recordingId': 'meeting-7',
        'sourceId': 'microphone-1',
        'trackId': 'microphone',
        'clockId': 'microphone-1.clock',
        'format': <String, Object?>{
          'sampleRate': 48000,
          'channels': 2,
          'sampleFormat': 'float32',
        },
        'encoding': 'pcm16',
        'segmentFrameCount': 8,
        'queueCapacityFrames': 64,
        'queuePolicy': 'dropOldest',
        'gapPolicy': 'insertSilence',
        'state': 'failed',
        'revision': 5,
        'totalFrameCount': 13,
        'droppedFrameCount': 2,
        'segments': <Map<String, Object?>>[
          <String, Object?>{
            'segmentId': 'meeting-7:segment:0',
            'fileName': 'meeting-7.0.wav',
            'startFrame': 0,
            'frameCount': 8,
            'finalized': true,
          },
          <String, Object?>{
            'segmentId': 'meeting-7:segment:1',
            'fileName': 'meeting-7.1.wav',
            'startFrame': 8,
            'frameCount': 5,
            'finalized': false,
          },
        ],
        'markers': <Map<String, Object?>>[
          <String, Object?>{
            'markerId': 'meeting-7:marker:0',
            'type': 'pause',
            'frameOffset': 8,
            'reason': 'user_paused',
          },
          <String, Object?>{
            'markerId': 'meeting-7:marker:1',
            'type': 'resume',
            'frameOffset': 8,
          },
          <String, Object?>{
            'markerId': 'meeting-7:marker:2',
            'type': 'sourceChange',
            'frameOffset': 8,
            'fromSourceId': 'microphone-1',
            'toSourceId': 'microphone-2',
            'fromClockId': 'microphone-1.clock',
            'toClockId': 'microphone-2.clock',
            'reason': 'default_device_changed',
          },
        ],
        'failureCode': 'segmented_wav_io_failed',
        'failureMessage': 'The recording segment append failed.',
      });
    });

    test('pins the enum spellings the durable format depends on', () {
      expect(
        SegmentedWavRecordingState.values.map(
          (SegmentedWavRecordingState value) => value.name,
        ),
        <String>[
          'prepared',
          'recording',
          'paused',
          'finished',
          'recovered',
          'failed',
        ],
      );
      expect(
        SegmentedWavQueuePolicy.values.map(
          (SegmentedWavQueuePolicy value) => value.name,
        ),
        <String>['wait', 'dropNewest', 'dropOldest', 'failRecorder'],
      );
      expect(
        WavGapPolicy.values.map((WavGapPolicy value) => value.name),
        <String>['reject', 'insertSilence'],
      );
      expect(
        SegmentedWavMarkerType.values.map(
          (SegmentedWavMarkerType value) => value.name,
        ),
        <String>['pause', 'resume', 'sourceChange'],
      );
      expect(
        WavSampleEncoding.values.map((WavSampleEncoding value) => value.name),
        <String>['pcm16', 'float32'],
      );
      expect(SegmentedWavRecordingManifest.schemaVersion, 1);
    });

    test('round-trips every state, queue policy, and gap policy', () {
      for (final SegmentedWavRecordingState state
          in SegmentedWavRecordingState.values) {
        for (final SegmentedWavQueuePolicy queuePolicy
            in SegmentedWavQueuePolicy.values) {
          for (final WavGapPolicy gapPolicy in WavGapPolicy.values) {
            final bool failed = state == SegmentedWavRecordingState.failed;
            final SegmentedWavRecordingManifest manifest = _manifest(
              state: state,
              queuePolicy: queuePolicy,
              gapPolicy: gapPolicy,
              failureCode: failed ? 'segmented_wav_io_failed' : null,
              failureMessage: failed ? 'Injected append failure.' : null,
            );

            expect(
              SegmentedWavRecordingManifest.fromJson(
                _encodeJson(manifest.toJson()),
              ).toJson(),
              manifest.toJson(),
              reason: '$state/$queuePolicy/$gapPolicy must round-trip.',
            );
          }
        }
      }
    });

    test('omits absent optional fields instead of writing nulls', () {
      final Map<String, Object?> json = _manifest().toJson();

      expect(json.containsKey('failureCode'), isFalse);
      expect(json.containsKey('failureMessage'), isFalse);
      expect(
        SegmentedWavMarker(
          markerId: 'marker',
          type: SegmentedWavMarkerType.resume,
          frameOffset: 0,
        ).toJson(),
        <String, Object?>{
          'markerId': 'marker',
          'type': 'resume',
          'frameOffset': 0,
        },
      );
    });

    test('ignores unknown keys so newer sidecars stay readable', () {
      final SegmentedWavRecordingManifest manifest = _manifest();
      final Map<String, Object?> json = <String, Object?>{
        ...manifest.toJson(),
        'writerVersion': '9.9.9',
      };

      expect(
        SegmentedWavRecordingManifest.fromJson(json).toJson(),
        manifest.toJson(),
      );
    });

    test('exposes segments and markers as unmodifiable views', () {
      final SegmentedWavRecordingManifest manifest = _fullManifest();

      expect(
        () => manifest.segments.add(manifest.segments.first),
        throwsUnsupportedError,
      );
      expect(
        () => manifest.markers.add(manifest.markers.first),
        throwsUnsupportedError,
      );
    });
  });

  group('SegmentedWavSegmentManifest validation', () {
    test('rejects blank identifiers and negative frame positions', () {
      expect(() => _segment(segmentId: ''), throwsArgumentError);
      expect(() => _segment(segmentId: '  '), throwsArgumentError);
      expect(() => _segment(fileName: ''), throwsArgumentError);
      expect(() => _segment(startFrame: -1), throwsArgumentError);
      expect(() => _segment(frameCount: -1), throwsArgumentError);
      expect(_segment(frameCount: 0).frameCount, 0);
    });

    test('rejects sidecar entries with missing or mistyped fields', () {
      final Map<String, Object?> valid = _segment().toJson();

      for (final String key in valid.keys) {
        expect(
          () => SegmentedWavSegmentManifest.fromJson(
            Map<String, Object?>.of(valid)..remove(key),
          ),
          throwsFormatException,
          reason: 'Removing "$key" must be rejected.',
        );
      }
      expect(
        () => SegmentedWavSegmentManifest.fromJson(<String, Object?>{
          ...valid,
          'finalized': 'true',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavSegmentManifest.fromJson(<String, Object?>{
          ...valid,
          'startFrame': 0.0,
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavSegmentManifest.fromJson(<String, Object?>{
          ...valid,
          'fileName': '',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavSegmentManifest.fromJson(<String, Object?>{
          ...valid,
          'startFrame': -1,
        }),
        throwsArgumentError,
      );
    });
  });

  group('SegmentedWavMarker validation', () {
    test('rejects blank identifiers, blank text, and negative offsets', () {
      expect(() => _marker(markerId: ''), throwsArgumentError);
      expect(() => _marker(frameOffset: -1), throwsArgumentError);
      expect(() => _marker(reason: ''), throwsArgumentError);
      expect(() => _marker(reason: '   '), throwsArgumentError);
      expect(() => _marker(fromSourceId: ''), throwsArgumentError);
      expect(() => _marker(toClockId: ' '), throwsArgumentError);
    });

    test('requires complete mappings on a source-change marker', () {
      SegmentedWavMarker build({
        String? fromSourceId = 'microphone-1',
        String? toSourceId = 'microphone-2',
        String? fromClockId = 'microphone-1.clock',
        String? toClockId = 'microphone-2.clock',
      }) => SegmentedWavMarker(
        markerId: 'marker',
        type: SegmentedWavMarkerType.sourceChange,
        frameOffset: 4,
        fromSourceId: fromSourceId,
        toSourceId: toSourceId,
        fromClockId: fromClockId,
        toClockId: toClockId,
      );

      expect(build().frameOffset, 4);
      expect(() => build(fromSourceId: null), throwsArgumentError);
      expect(() => build(toSourceId: null), throwsArgumentError);
      expect(() => build(fromClockId: null), throwsArgumentError);
      expect(() => build(toClockId: null), throwsArgumentError);
    });

    test('rejects sidecar entries with missing or mistyped fields', () {
      final Map<String, Object?> valid = _marker(
        reason: 'user_paused',
      ).toJson();

      expect(
        () => SegmentedWavMarker.fromJson(
          Map<String, Object?>.of(valid)..remove('markerId'),
        ),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavMarker.fromJson(
          Map<String, Object?>.of(valid)..remove('type'),
        ),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavMarker.fromJson(
          Map<String, Object?>.of(valid)..remove('frameOffset'),
        ),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavMarker.fromJson(<String, Object?>{
          ...valid,
          'type': 'deviceChange',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavMarker.fromJson(<String, Object?>{
          ...valid,
          'reason': '',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavMarker.fromJson(<String, Object?>{
          ...valid,
          'frameOffset': '8',
        }),
        throwsFormatException,
      );
      expect(
        SegmentedWavMarker.fromJson(
          Map<String, Object?>.of(valid)..remove('reason'),
        ).reason,
        isNull,
      );
    });
  });

  group('SegmentedWavRecordingManifest validation', () {
    test('rejects blank identifiers', () {
      expect(() => _manifest(recordingId: ''), throwsArgumentError);
      expect(() => _manifest(sourceId: ' '), throwsArgumentError);
      expect(() => _manifest(trackId: ''), throwsArgumentError);
      expect(() => _manifest(clockId: '\t'), throwsArgumentError);
    });

    test('rejects non-positive sizing and negative counters', () {
      expect(() => _manifest(segmentFrameCount: 0), throwsArgumentError);
      expect(() => _manifest(segmentFrameCount: -1), throwsArgumentError);
      expect(() => _manifest(queueCapacityFrames: 0), throwsArgumentError);
      expect(() => _manifest(revision: -1), throwsArgumentError);
      expect(() => _manifest(totalFrameCount: -1), throwsArgumentError);
      expect(() => _manifest(droppedFrameCount: -1), throwsArgumentError);
    });

    test('ties failure fields to the failed state', () {
      expect(
        () => _manifest(state: SegmentedWavRecordingState.failed),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          state: SegmentedWavRecordingState.failed,
          failureCode: 'segmented_wav_io_failed',
        ),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          state: SegmentedWavRecordingState.finished,
          failureCode: 'segmented_wav_io_failed',
          failureMessage: 'Injected append failure.',
        ),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          state: SegmentedWavRecordingState.failed,
          failureCode: '',
          failureMessage: 'Injected append failure.',
        ),
        throwsArgumentError,
      );
      expect(
        _manifest(
          state: SegmentedWavRecordingState.failed,
          failureCode: 'segmented_wav_io_failed',
          failureMessage: 'Injected append failure.',
        ).failureCode,
        'segmented_wav_io_failed',
      );
    });

    test('rejects duplicate, overlapping, or unaccounted segments', () {
      expect(
        () => _manifest(
          totalFrameCount: 8,
          segments: <SegmentedWavSegmentManifest>[
            _segment(segmentId: 'segment:0', fileName: 'a.wav', frameCount: 4),
            _segment(
              segmentId: 'segment:0',
              fileName: 'b.wav',
              startFrame: 4,
              frameCount: 4,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          totalFrameCount: 8,
          segments: <SegmentedWavSegmentManifest>[
            _segment(segmentId: 'segment:0', fileName: 'a.wav', frameCount: 4),
            _segment(
              segmentId: 'segment:1',
              fileName: 'a.wav',
              startFrame: 4,
              frameCount: 4,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          totalFrameCount: 8,
          segments: <SegmentedWavSegmentManifest>[
            _segment(segmentId: 'segment:0', fileName: 'a.wav', frameCount: 4),
            _segment(
              segmentId: 'segment:1',
              fileName: 'b.wav',
              startFrame: 3,
              frameCount: 4,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _manifest(
          totalFrameCount: 3,
          segments: <SegmentedWavSegmentManifest>[
            _segment(segmentId: 'segment:0', fileName: 'a.wav', frameCount: 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        _manifest(
          totalFrameCount: 9,
          segments: <SegmentedWavSegmentManifest>[
            _segment(segmentId: 'segment:0', fileName: 'a.wav', frameCount: 4),
            _segment(
              segmentId: 'segment:1',
              fileName: 'b.wav',
              startFrame: 5,
              frameCount: 4,
            ),
          ],
        ).segments.length,
        2,
      );
    });

    test('rejects duplicate marker identifiers', () {
      expect(
        () => _manifest(
          markers: <SegmentedWavMarker>[
            _marker(markerId: 'marker:0'),
            _marker(markerId: 'marker:0', frameOffset: 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        _manifest(
          markers: <SegmentedWavMarker>[
            _marker(markerId: 'marker:0'),
            _marker(markerId: 'marker:1', frameOffset: 4),
          ],
        ).markers.length,
        2,
      );
    });
  });

  group('SegmentedWavRecordingManifest.fromJson rejection', () {
    test('rejects a missing or unsupported schema version', () {
      final Map<String, Object?> valid = _manifest().toJson();

      expect(
        () => SegmentedWavRecordingManifest.fromJson(
          Map<String, Object?>.of(valid)..remove('schemaVersion'),
        ),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'schemaVersion': 2,
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'schemaVersion': '1',
        }),
        throwsFormatException,
      );
    });

    test('rejects a missing required key', () {
      final Map<String, Object?> valid = _manifest().toJson();

      for (final String key in valid.keys) {
        expect(
          () => SegmentedWavRecordingManifest.fromJson(
            Map<String, Object?>.of(valid)..remove(key),
          ),
          throwsFormatException,
          reason: 'Removing "$key" must be rejected.',
        );
      }
    });

    test('rejects a malformed format block', () {
      final Map<String, Object?> valid = _manifest().toJson();

      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'format': 'pcm',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'format': <String, Object?>{
            'sampleRate': 48000,
            'channels': 2,
            'sampleFormat': 'int16',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'format': <String, Object?>{'channels': 2, 'sampleFormat': 'float32'},
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'format': <String, Object?>{
            'sampleRate': 0,
            'channels': 2,
            'sampleFormat': 'float32',
          },
        }),
        throwsArgumentError,
      );
    });

    test('rejects unknown enum spellings', () {
      final Map<String, Object?> valid = _manifest().toJson();

      for (final MapEntry<String, Object?> override in <String, Object?>{
        'encoding': 'pcm24',
        'queuePolicy': 'dropEverything',
        'gapPolicy': 'ignore',
        'state': 'aborted',
      }.entries) {
        expect(
          () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
            ...valid,
            override.key: override.value,
          }),
          throwsFormatException,
          reason: '"${override.key}" must reject "${override.value}".',
        );
      }
    });

    test('rejects mistyped scalars and collections', () {
      final Map<String, Object?> valid = _manifest().toJson();

      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'recordingId': '',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'revision': '5',
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'droppedFrameCount': 1.5,
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'segments': <String, Object?>{},
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'segments': <Object?>[42],
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'markers': <Object?>[
            <String, Object?>{'type': 'pause', 'frameOffset': 0},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'failureCode': '',
        }),
        throwsFormatException,
      );
    });

    test('propagates constructor invariants out of fromJson', () {
      final Map<String, Object?> valid = _fullManifest().toJson();

      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'totalFrameCount': 1,
        }),
        throwsArgumentError,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'state': 'finished',
        }),
        throwsArgumentError,
      );
      expect(
        () => SegmentedWavRecordingManifest.fromJson(<String, Object?>{
          ...valid,
          'segmentFrameCount': 0,
        }),
        throwsArgumentError,
      );
    });
  });
}

SegmentedWavRecordingManifest _fullManifest() => _manifest(
  state: SegmentedWavRecordingState.failed,
  revision: 5,
  totalFrameCount: 13,
  droppedFrameCount: 2,
  failureCode: 'segmented_wav_io_failed',
  failureMessage: 'The recording segment append failed.',
  segments: <SegmentedWavSegmentManifest>[
    _segment(
      segmentId: 'meeting-7:segment:0',
      fileName: 'meeting-7.0.wav',
      frameCount: 8,
    ),
    _segment(
      segmentId: 'meeting-7:segment:1',
      fileName: 'meeting-7.1.wav',
      startFrame: 8,
      frameCount: 5,
      finalized: false,
    ),
  ],
  markers: <SegmentedWavMarker>[
    _marker(
      markerId: 'meeting-7:marker:0',
      frameOffset: 8,
      reason: 'user_paused',
    ),
    _marker(
      markerId: 'meeting-7:marker:1',
      type: SegmentedWavMarkerType.resume,
      frameOffset: 8,
    ),
    _marker(
      markerId: 'meeting-7:marker:2',
      type: SegmentedWavMarkerType.sourceChange,
      frameOffset: 8,
      fromSourceId: 'microphone-1',
      toSourceId: 'microphone-2',
      fromClockId: 'microphone-1.clock',
      toClockId: 'microphone-2.clock',
      reason: 'default_device_changed',
    ),
  ],
);

SegmentedWavRecordingManifest _manifest({
  String recordingId = 'meeting-7',
  String sourceId = 'microphone-1',
  String trackId = 'microphone',
  String clockId = 'microphone-1.clock',
  AudioFormat? format,
  WavSampleEncoding encoding = WavSampleEncoding.pcm16,
  int segmentFrameCount = 8,
  int queueCapacityFrames = 64,
  SegmentedWavQueuePolicy queuePolicy = SegmentedWavQueuePolicy.dropOldest,
  WavGapPolicy gapPolicy = WavGapPolicy.insertSilence,
  SegmentedWavRecordingState state = SegmentedWavRecordingState.recording,
  int revision = 0,
  int totalFrameCount = 0,
  int droppedFrameCount = 0,
  List<SegmentedWavSegmentManifest> segments =
      const <SegmentedWavSegmentManifest>[],
  List<SegmentedWavMarker> markers = const <SegmentedWavMarker>[],
  String? failureCode,
  String? failureMessage,
}) => SegmentedWavRecordingManifest(
  recordingId: recordingId,
  sourceId: sourceId,
  trackId: trackId,
  clockId: clockId,
  format: format ?? AudioFormat(sampleRate: 48000, channels: 2),
  encoding: encoding,
  segmentFrameCount: segmentFrameCount,
  queueCapacityFrames: queueCapacityFrames,
  queuePolicy: queuePolicy,
  gapPolicy: gapPolicy,
  state: state,
  revision: revision,
  totalFrameCount: totalFrameCount,
  droppedFrameCount: droppedFrameCount,
  segments: segments,
  markers: markers,
  failureCode: failureCode,
  failureMessage: failureMessage,
);

SegmentedWavSegmentManifest _segment({
  String segmentId = 'meeting-7:segment:0',
  String fileName = 'meeting-7.0.wav',
  int startFrame = 0,
  int frameCount = 8,
  bool finalized = true,
}) => SegmentedWavSegmentManifest(
  segmentId: segmentId,
  fileName: fileName,
  startFrame: startFrame,
  frameCount: frameCount,
  finalized: finalized,
);

SegmentedWavMarker _marker({
  String markerId = 'meeting-7:marker:0',
  SegmentedWavMarkerType type = SegmentedWavMarkerType.pause,
  int frameOffset = 0,
  String? fromSourceId,
  String? toSourceId,
  String? fromClockId,
  String? toClockId,
  String? reason,
}) => SegmentedWavMarker(
  markerId: markerId,
  type: type,
  frameOffset: frameOffset,
  fromSourceId: fromSourceId,
  toSourceId: toSourceId,
  fromClockId: fromClockId,
  toClockId: toClockId,
  reason: reason,
);

Map<String, Object?> _encodeJson(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map<String, dynamic>)
        .cast<String, Object?>();
