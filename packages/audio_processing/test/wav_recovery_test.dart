import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing_io.dart';
import 'package:test/test.dart';

void main() {
  final AudioFormat monoFormat = AudioFormat(sampleRate: 1000, channels: 1);
  final AudioFormat stereoFormat = AudioFormat(sampleRate: 1000, channels: 2);

  group('repairWavStorageFile', () {
    test('leaves a valid header with whole frames untouched', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'segment.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 4),
      );

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.headerWasValid, isTrue);
      expect(repair.headerChanged, isFalse);
      expect(repair.truncatedByteCount, 0);
      expect(repair.dataLength, 8);
      final Uint8List bytes = await storage.readFile('segment.wav');
      expect(bytes.length, 44 + 8);
      expect(inspectWav(bytes).sampleFrameCount, 4);
    });

    test('rebuilds a garbage header from the expected format', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'segment.wav',
        Uint8List.fromList(<int>[
          ...List<int>.filled(44, 0xff),
          ...List<int>.filled(6, 0x01),
        ]),
      );

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.headerWasValid, isFalse);
      expect(repair.headerChanged, isTrue);
      expect(repair.truncatedByteCount, 0);
      expect(repair.dataLength, 6);
      final WavFileInfo info = inspectWav(
        await storage.readFile('segment.wav'),
      );
      expect(info.sampleFrameCount, 3);
      expect(info.formatCode, WavSampleEncoding.pcm16.formatCode);
      expect(info.bitsPerSample, 16);
      expect(info.channels, 1);
      expect(info.sampleRate, 1000);
    });

    test('rebuilds a header that describes a different format', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'segment.wav',
        _wavBytes(stereoFormat, WavSampleEncoding.pcm16, 2),
      );

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.headerWasValid, isFalse);
      expect(repair.headerChanged, isTrue);
      expect(repair.dataLength, 8);
      expect(inspectWav(await storage.readFile('segment.wav')).channels, 1);
    });

    test('refreshes a stale declared data length', () async {
      final _MemoryStorage storage = _MemoryStorage();
      final SegmentedWavStorageFile file = await storage.createFile(
        'segment.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 0),
      );
      await file.append(Uint8List(8));
      await file.close();

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.headerWasValid, isTrue);
      expect(repair.headerChanged, isTrue);
      expect(repair.truncatedByteCount, 0);
      expect(repair.dataLength, 8);
      expect(
        inspectWav(await storage.readFile('segment.wav')).sampleFrameCount,
        4,
      );
    });

    test('truncates a trailing partial sample frame', () async {
      final _MemoryStorage storage = _MemoryStorage();
      final SegmentedWavStorageFile file = await storage.createFile(
        'segment.wav',
        _wavBytes(stereoFormat, WavSampleEncoding.pcm16, 2),
      );
      await file.append(Uint8List.fromList(<int>[0x01, 0x02, 0x03]));
      await file.close();

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        stereoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.truncatedByteCount, 3);
      expect(repair.dataLength, 8);
      expect(repair.headerWasValid, isTrue);
      expect(repair.headerChanged, isFalse);
      final Uint8List bytes = await storage.readFile('segment.wav');
      expect(bytes.length, 44 + 8);
      expect(inspectWav(bytes).sampleFrameCount, 2);
    });

    test('reports an empty data chunk for a file shorter than the '
        'header', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'segment.wav',
        Uint8List.fromList(List<int>.filled(10, 0x52)),
      );

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.pcm16,
      );

      expect(repair.dataLength, 0);
      expect(repair.truncatedByteCount, 0);
      expect(repair.headerWasValid, isFalse);
      expect(repair.headerChanged, isTrue);
      final Uint8List bytes = await storage.readFile('segment.wav');
      expect(bytes.length, 44);
      expect(inspectWav(bytes).sampleFrameCount, 0);
    });

    test('reports an empty data chunk for an empty file', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile('segment.wav', Uint8List(0));

      final WavHeaderRepairResult repair = await _repair(
        storage,
        'segment.wav',
        monoFormat,
        WavSampleEncoding.float32,
      );

      expect(repair.dataLength, 0);
      expect(repair.truncatedByteCount, 0);
      expect(repair.headerWasValid, isFalse);
      final Uint8List bytes = await storage.readFile('segment.wav');
      expect(bytes.length, 44);
      expect(
        inspectWav(bytes).formatCode,
        WavSampleEncoding.float32.formatCode,
      );
    });
  });

  group('recoverSegmentedWavRecording', () {
    test('finalizes an interrupted segment and rewrites the sidecar', () async {
      final _MemoryStorage storage = _MemoryStorage();
      final SegmentedWavRecordingManifest interrupted = _manifest(
        format: monoFormat,
        state: SegmentedWavRecordingState.recording,
        revision: 3,
        totalFrameCount: 4,
        droppedFrameCount: 2,
        segments: <SegmentedWavSegmentManifest>[
          SegmentedWavSegmentManifest(
            segmentId: 'meeting-1:segment:0',
            fileName: 'meeting-1.0.wav',
            startFrame: 0,
            frameCount: 4,
            finalized: true,
          ),
          SegmentedWavSegmentManifest(
            segmentId: 'meeting-1:segment:1',
            fileName: 'meeting-1.1.wav',
            startFrame: 4,
            frameCount: 0,
            finalized: false,
          ),
        ],
        markers: <SegmentedWavMarker>[
          SegmentedWavMarker(
            markerId: 'meeting-1:marker:0',
            type: SegmentedWavMarkerType.pause,
            frameOffset: 4,
            reason: 'user_paused',
          ),
        ],
      );
      await storage.createFile(
        'meeting-1.0.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 4),
      );
      final SegmentedWavStorageFile torn = await storage.createFile(
        'meeting-1.1.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 0),
      );
      await torn.append(Uint8List(11));
      await torn.close();
      await _writeManifest(storage, 'meeting-1.json', interrupted.toJson());

      final SegmentedWavRecoveryResult recovery =
          await recoverSegmentedWavRecording(
            manifestFileName: 'meeting-1.json',
            storage: storage,
          );

      expect(recovery.manifest.state, SegmentedWavRecordingState.recovered);
      expect(recovery.manifest.revision, 4);
      expect(recovery.manifest.totalFrameCount, 9);
      expect(recovery.manifest.droppedFrameCount, 2);
      expect(recovery.truncatedByteCount, 1);
      expect(recovery.repairedSegmentIds, <String>['meeting-1:segment:1']);
      expect(
        recovery.manifest.segments.map(
          (SegmentedWavSegmentManifest segment) =>
              (segment.startFrame, segment.frameCount, segment.finalized),
        ),
        <(int, int, bool)>[(0, 4, true), (4, 5, true)],
      );
      expect(
        recovery.manifest.markers.single.toJson(),
        interrupted.markers.single.toJson(),
      );
      expect(
        inspectWav(await storage.readFile('meeting-1.1.wav')).sampleFrameCount,
        5,
      );
      expect(
        await _readManifest(storage, 'meeting-1.json'),
        recovery.manifest.toJson(),
      );
    });

    test('leaves intact segments out of the repaired list', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'meeting-2.0.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 6),
      );
      await _writeManifest(
        storage,
        'meeting-2.json',
        _manifest(
          format: monoFormat,
          state: SegmentedWavRecordingState.finished,
          revision: 7,
          totalFrameCount: 6,
          segments: <SegmentedWavSegmentManifest>[
            SegmentedWavSegmentManifest(
              segmentId: 'meeting-2:segment:0',
              fileName: 'meeting-2.0.wav',
              startFrame: 0,
              frameCount: 6,
              finalized: true,
            ),
          ],
        ).toJson(),
      );

      final SegmentedWavRecoveryResult recovery =
          await recoverSegmentedWavRecording(
            manifestFileName: 'meeting-2.json',
            storage: storage,
          );

      expect(recovery.repairedSegmentIds, isEmpty);
      expect(recovery.truncatedByteCount, 0);
      expect(recovery.manifest.revision, 8);
      expect(recovery.manifest.state, SegmentedWavRecordingState.recovered);
      expect(recovery.manifest.totalFrameCount, 6);
    });

    test('drops the persisted failure of a failed recording', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.createFile(
        'meeting-3.0.wav',
        _wavBytes(monoFormat, WavSampleEncoding.pcm16, 3),
      );
      await _writeManifest(
        storage,
        'meeting-3.json',
        _manifest(
          format: monoFormat,
          state: SegmentedWavRecordingState.failed,
          revision: 1,
          totalFrameCount: 3,
          failureCode: 'segmented_wav_io_failed',
          failureMessage: 'Injected append failure.',
          segments: <SegmentedWavSegmentManifest>[
            SegmentedWavSegmentManifest(
              segmentId: 'meeting-3:segment:0',
              fileName: 'meeting-3.0.wav',
              startFrame: 0,
              frameCount: 3,
              finalized: true,
            ),
          ],
        ).toJson(),
      );

      final SegmentedWavRecoveryResult recovery =
          await recoverSegmentedWavRecording(
            manifestFileName: 'meeting-3.json',
            storage: storage,
          );

      expect(recovery.manifest.state, SegmentedWavRecordingState.recovered);
      expect(recovery.manifest.failureCode, isNull);
      expect(recovery.manifest.failureMessage, isNull);
      expect(recovery.manifest.toJson().containsKey('failureCode'), isFalse);
      expect(
        await _readManifest(storage, 'meeting-3.json'),
        recovery.manifest.toJson(),
      );
    });

    test('rejects a sidecar that is not a JSON object', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await storage.writeFileAtomically(
        'array.json',
        Uint8List.fromList(utf8.encode('[]')),
      );
      await storage.writeFileAtomically(
        'string.json',
        Uint8List.fromList(utf8.encode('"not-a-manifest"')),
      );

      await expectLater(
        recoverSegmentedWavRecording(
          manifestFileName: 'array.json',
          storage: storage,
        ),
        throwsFormatException,
      );
      await expectLater(
        recoverSegmentedWavRecording(
          manifestFileName: 'string.json',
          storage: storage,
        ),
        throwsFormatException,
      );
    });

    test('rejects a sidecar with an unsupported schema version', () async {
      final _MemoryStorage storage = _MemoryStorage();
      await _writeManifest(storage, 'future.json', <String, Object?>{
        ..._manifest(
          format: monoFormat,
          state: SegmentedWavRecordingState.finished,
          revision: 0,
          totalFrameCount: 0,
        ).toJson(),
        'schemaVersion': SegmentedWavRecordingManifest.schemaVersion + 1,
      });

      await expectLater(
        recoverSegmentedWavRecording(
          manifestFileName: 'future.json',
          storage: storage,
        ),
        throwsFormatException,
      );
    });
  });

  group('repairWavFileHeader', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'wav_recovery.',
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('repairs a real file killed between append and header '
        'flush', () async {
      final File file = File('${temporaryDirectory.path}/segment.wav');
      await file.writeAsBytes(<int>[
        ..._wavBytes(monoFormat, WavSampleEncoding.pcm16, 4),
        0x01,
        0x02,
        0x03,
      ]);

      final WavHeaderRepairResult repair = await repairWavFileHeader(
        path: file.path,
        format: monoFormat,
        encoding: WavSampleEncoding.pcm16,
      );

      expect(repair.headerWasValid, isTrue);
      expect(repair.headerChanged, isTrue);
      expect(repair.truncatedByteCount, 1);
      expect(repair.dataLength, 10);
      final Uint8List bytes = await file.readAsBytes();
      expect(bytes.length, 44 + 10);
      expect(inspectWav(bytes).sampleFrameCount, 5);
    });

    test('rebuilds a torn header on disk and is idempotent', () async {
      final File file = File('${temporaryDirectory.path}/segment.wav');
      await file.writeAsBytes(<int>[
        ...List<int>.filled(44, 0),
        ...List<int>.filled(8, 7),
      ]);

      final WavHeaderRepairResult first = await repairWavFileHeader(
        path: file.path,
        format: monoFormat,
        encoding: WavSampleEncoding.pcm16,
      );
      final WavHeaderRepairResult second = await repairWavFileHeader(
        path: file.path,
        format: monoFormat,
        encoding: WavSampleEncoding.pcm16,
      );

      expect(first.headerWasValid, isFalse);
      expect(first.headerChanged, isTrue);
      expect(second.headerWasValid, isTrue);
      expect(second.headerChanged, isFalse);
      expect(second.truncatedByteCount, 0);
      expect(second.dataLength, first.dataLength);
      expect(inspectWav(await file.readAsBytes()).sampleFrameCount, 4);
    });

    test('pads a file shorter than the header up to an empty WAV', () async {
      final File file = File('${temporaryDirectory.path}/stub.wav');
      await file.writeAsBytes(<int>[0x52, 0x49, 0x46]);

      final WavHeaderRepairResult repair = await repairWavFileHeader(
        path: file.path,
        format: stereoFormat,
        encoding: WavSampleEncoding.pcm16,
      );

      expect(repair.dataLength, 0);
      expect(repair.truncatedByteCount, 0);
      expect(repair.headerWasValid, isFalse);
      final Uint8List bytes = await file.readAsBytes();
      expect(bytes.length, 44);
      expect(inspectWav(bytes).sampleFrameCount, 0);
      expect(inspectWav(bytes).channels, 2);
    });

    test('reports a missing path as a file-system failure', () async {
      await expectLater(
        repairWavFileHeader(
          path: '${temporaryDirectory.path}/absent.wav',
          format: monoFormat,
          encoding: WavSampleEncoding.pcm16,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects a blank path', () async {
      await expectLater(
        repairWavFileHeader(
          path: '   ',
          format: monoFormat,
          encoding: WavSampleEncoding.pcm16,
        ),
        throwsArgumentError,
      );
    });
  });
}

Future<WavHeaderRepairResult> _repair(
  SegmentedWavStorage storage,
  String fileName,
  AudioFormat format,
  WavSampleEncoding encoding,
) async {
  final SegmentedWavStorageFile file = await storage.openFile(fileName);
  try {
    return await repairWavStorageFile(file, format: format, encoding: encoding);
  } finally {
    await file.close();
  }
}

Uint8List _wavBytes(
  AudioFormat format,
  WavSampleEncoding encoding,
  int frameCount,
) {
  final WavEncoder encoder = WavEncoder(format: format, encoding: encoding);
  if (frameCount > 0) {
    encoder.addFrame(
      AudioFrame(
        format: format,
        samples: Float32List(frameCount * format.channels),
        sourceId: 'source',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
      ),
    );
  }
  return encoder.finish();
}

SegmentedWavRecordingManifest _manifest({
  required AudioFormat format,
  required SegmentedWavRecordingState state,
  required int revision,
  required int totalFrameCount,
  int droppedFrameCount = 0,
  List<SegmentedWavSegmentManifest> segments =
      const <SegmentedWavSegmentManifest>[],
  List<SegmentedWavMarker> markers = const <SegmentedWavMarker>[],
  String? failureCode,
  String? failureMessage,
}) => SegmentedWavRecordingManifest(
  recordingId: 'meeting',
  sourceId: 'microphone-1',
  trackId: 'microphone',
  clockId: 'microphone-1.clock',
  format: format,
  encoding: WavSampleEncoding.pcm16,
  segmentFrameCount: 8,
  queueCapacityFrames: 32,
  queuePolicy: SegmentedWavQueuePolicy.dropOldest,
  gapPolicy: WavGapPolicy.insertSilence,
  state: state,
  revision: revision,
  totalFrameCount: totalFrameCount,
  droppedFrameCount: droppedFrameCount,
  segments: segments,
  markers: markers,
  failureCode: failureCode,
  failureMessage: failureMessage,
);

Future<void> _writeManifest(
  SegmentedWavStorage storage,
  String fileName,
  Map<String, Object?> json,
) => storage.writeFileAtomically(
  fileName,
  Uint8List.fromList(utf8.encode(jsonEncode(json))),
);

Future<Map<String, Object?>> _readManifest(
  SegmentedWavStorage storage,
  String fileName,
) async =>
    (jsonDecode(utf8.decode(await storage.readFile(fileName)))
            as Map<String, dynamic>)
        .cast<String, Object?>();

final class _MemoryStorage implements SegmentedWavStorage {
  final Map<String, _MemoryFileData> files = <String, _MemoryFileData>{};

  @override
  Future<SegmentedWavStorageFile> createFile(
    String fileName,
    Uint8List initialBytes,
  ) async {
    final _MemoryFileData data = _MemoryFileData(initialBytes.toList());
    files[fileName] = data;
    return _MemoryStorageFile(fileName, data);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<SegmentedWavStorageFile> openFile(String fileName) async {
    final _MemoryFileData? data = files[fileName];
    if (data == null) {
      throw StateError('Missing memory file: $fileName.');
    }
    return _MemoryStorageFile(fileName, data);
  }

  @override
  Future<Uint8List> readFile(String fileName) async {
    final _MemoryFileData? data = files[fileName];
    if (data == null) {
      throw StateError('Missing memory file: $fileName.');
    }
    return Uint8List.fromList(data.bytes);
  }

  @override
  Future<void> writeFileAtomically(String fileName, Uint8List bytes) async {
    files[fileName] = _MemoryFileData(bytes.toList());
  }
}

final class _MemoryFileData {
  _MemoryFileData(this.bytes);

  final List<int> bytes;
}

final class _MemoryStorageFile implements SegmentedWavStorageFile {
  _MemoryStorageFile(this.fileName, this._data);

  @override
  final String fileName;

  final _MemoryFileData _data;
  bool _closed = false;

  @override
  Future<void> append(Uint8List bytes) async {
    _requireOpen();
    _data.bytes.addAll(bytes);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<void> flush() async {
    _requireOpen();
  }

  @override
  Future<int> length() async {
    _requireOpen();
    return _data.bytes.length;
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    _requireOpen();
    final int end = (offset + length).clamp(0, _data.bytes.length).toInt();
    return Uint8List.fromList(_data.bytes.sublist(offset, end));
  }

  @override
  Future<void> truncate(int length) async {
    _requireOpen();
    if (length < _data.bytes.length) {
      _data.bytes.removeRange(length, _data.bytes.length);
    } else {
      _data.bytes.addAll(List<int>.filled(length - _data.bytes.length, 0));
    }
  }

  @override
  Future<void> writeAt(int offset, Uint8List bytes) async {
    _requireOpen();
    final int requiredLength = offset + bytes.length;
    if (requiredLength > _data.bytes.length) {
      _data.bytes.addAll(
        List<int>.filled(requiredLength - _data.bytes.length, 0),
      );
    }
    _data.bytes.setRange(offset, requiredLength, bytes);
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('Memory file is closed.');
    }
  }
}
