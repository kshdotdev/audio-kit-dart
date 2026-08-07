import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'segmented_wav_recorder.',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'rotates bounded WAV segments and durably mirrors the manifest',
    () async {
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
        storage: LocalSegmentedWavStorage(temporaryDirectory.path),
        recordingId: 'meeting-1',
        format: format,
        sourceId: 'microphone-1',
        trackId: 'microphone',
        clockId: 'microphone-1.clock',
        segmentFrameCount: 3,
        queueCapacityFrames: 10,
        encodingBufferBytes: 4,
      );
      await recorder.start();

      final SegmentedWavWriteResult result = await recorder.write(
        _frame(
          format,
          <double>[-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75],
          sourceId: 'microphone-1',
          trackId: 'microphone',
          clockId: 'microphone-1.clock',
        ),
      );
      await recorder.finish();

      expect(result.wasWritten, isTrue);
      expect(recorder.manifest.state, SegmentedWavRecordingState.finished);
      expect(recorder.manifest.totalFrameCount, 8);
      expect(
        recorder.manifest.segments.map(
          (SegmentedWavSegmentManifest segment) =>
              (segment.startFrame, segment.frameCount, segment.finalized),
        ),
        <(int, int, bool)>[(0, 3, true), (3, 3, true), (6, 2, true)],
      );
      for (final SegmentedWavSegmentManifest segment
          in recorder.manifest.segments) {
        final Uint8List bytes = await File(
          '${temporaryDirectory.path}/${segment.fileName}',
        ).readAsBytes();
        expect(inspectWav(bytes).sampleFrameCount, segment.frameCount);
      }
      final Map<String, Object?> persisted = await _readManifest(
        '${temporaryDirectory.path}/${recorder.manifestFileName}',
      );
      expect(persisted, recorder.manifest.toJson());
      expect(
        SegmentedWavRecordingManifest.fromJson(persisted).toJson(),
        persisted,
      );
      await recorder.close();
    },
  );

  test('persists pause, resume, and source-clock change markers', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
      storage: LocalSegmentedWavStorage(temporaryDirectory.path),
      recordingId: 'meeting-markers',
      format: format,
      sourceId: 'source-a',
      trackId: 'system',
      clockId: 'clock-a',
      segmentFrameCount: 10,
      queueCapacityFrames: 10,
    );
    await recorder.start();
    await recorder.write(
      _frame(
        format,
        <double>[0.1, 0.2],
        sourceId: 'source-a',
        trackId: 'system',
        clockId: 'clock-a',
      ),
    );
    await recorder.pause(reason: 'user_paused');
    await recorder.resume();
    await recorder.markSourceChanged(
      sourceId: 'source-b',
      clockId: 'clock-b',
      reason: 'default_device_changed',
    );
    await recorder.write(
      _frame(
        format,
        <double>[0.3, 0.4],
        sourceId: 'source-b',
        trackId: 'system',
        clockId: 'clock-b',
      ),
    );
    await recorder.finish();

    expect(
      recorder.manifest.markers.map((SegmentedWavMarker marker) => marker.type),
      <SegmentedWavMarkerType>[
        SegmentedWavMarkerType.pause,
        SegmentedWavMarkerType.resume,
        SegmentedWavMarkerType.sourceChange,
      ],
    );
    expect(
      recorder.manifest.markers.map(
        (SegmentedWavMarker marker) => marker.frameOffset,
      ),
      <int>[2, 2, 2],
    );
    expect(recorder.manifest.markers.last.toClockId, 'clock-b');
    expect(recorder.manifest.totalFrameCount, 4);
    await recorder.close();
  });

  test('enters a stable failed state when segment IO fails', () async {
    final _MemoryStorage storage = _MemoryStorage()..failAppends = true;
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
      recordingId: 'meeting-failure',
      format: format,
      sourceId: 'source',
      trackId: 'track',
      clockId: 'clock',
      segmentFrameCount: 10,
      queueCapacityFrames: 10,
      storage: storage,
    );
    await recorder.start();

    await expectLater(
      recorder.write(_frame(format, <double>[0.1, 0.2])),
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure failure) => failure.code,
          'code',
          'segmented_wav_io_failed',
        ),
      ),
    );

    expect(recorder.state, SegmentedWavRecordingState.failed);
    expect(recorder.failure?.code, 'segmented_wav_io_failed');
    final SegmentedWavRecordingManifest persisted =
        SegmentedWavRecordingManifest.fromJson(
          _decodeManifest(await storage.readFile(recorder.manifestFileName)),
        );
    expect(persisted.state, SegmentedWavRecordingState.failed);
    expect(persisted.failureCode, 'segmented_wav_io_failed');
    await recorder.close();
  });

  test('drop-newest policy keeps the pending queue bounded', () async {
    final _MemoryStorage storage = _MemoryStorage();
    final Completer<void> appendGate = Completer<void>();
    storage.appendGate = appendGate;
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
      recordingId: 'meeting-queue',
      format: format,
      sourceId: 'source',
      trackId: 'track',
      clockId: 'clock',
      segmentFrameCount: 20,
      queueCapacityFrames: 2,
      queuePolicy: SegmentedWavQueuePolicy.dropNewest,
      storage: storage,
    );
    await recorder.start();

    final Future<SegmentedWavWriteResult> first = recorder.write(
      _frame(format, <double>[0.1, 0.2]),
    );
    await storage.appendStarted.future;
    final Future<SegmentedWavWriteResult> second = recorder.write(
      _frame(format, <double>[0.3, 0.4], sequence: 1, sampleOffset: 2),
    );
    expect(recorder.queuedFrameCount, 2);
    final SegmentedWavWriteResult third = await recorder.write(
      _frame(format, <double>[0.5, 0.6], sequence: 2, sampleOffset: 4),
    );

    expect(third.disposition, SegmentedWavWriteDisposition.droppedNewest);
    expect(recorder.queuedFrameCount, 2);
    appendGate.complete();
    expect((await first).wasWritten, isTrue);
    expect((await second).wasWritten, isTrue);
    await recorder.finish();
    expect(recorder.droppedFrameCount, 2);
    expect(recorder.totalFrameCount, 4);
    await recorder.close();
  });

  test(
    'wait policy applies backpressure until queue capacity returns',
    () async {
      final _MemoryStorage storage = _MemoryStorage();
      final Completer<void> appendGate = Completer<void>();
      storage.appendGate = appendGate;
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
        recordingId: 'meeting-backpressure',
        format: format,
        sourceId: 'source',
        trackId: 'track',
        clockId: 'clock',
        segmentFrameCount: 20,
        queueCapacityFrames: 2,
        queuePolicy: SegmentedWavQueuePolicy.wait,
        storage: storage,
      );
      await recorder.start();

      final Future<SegmentedWavWriteResult> first = recorder.write(
        _frame(format, <double>[0.1, 0.2]),
      );
      await storage.appendStarted.future;
      final Future<SegmentedWavWriteResult> second = recorder.write(
        _frame(format, <double>[0.3, 0.4], sequence: 1, sampleOffset: 2),
      );
      final Future<SegmentedWavWriteResult> waiting = recorder.write(
        _frame(format, <double>[0.5, 0.6], sequence: 2, sampleOffset: 4),
      );
      await Future<void>.delayed(Duration.zero);

      expect(recorder.queuedFrameCount, 2);
      appendGate.complete();
      expect((await first).wasWritten, isTrue);
      expect((await second).wasWritten, isTrue);
      expect((await waiting).wasWritten, isTrue);
      await recorder.finish();
      expect(recorder.totalFrameCount, 6);
      expect(recorder.droppedFrameCount, 0);
      await recorder.close();
    },
  );

  test(
    'fail policy rejects queued work without racing the active write',
    () async {
      final _MemoryStorage storage = _MemoryStorage();
      final Completer<void> appendGate = Completer<void>();
      storage.appendGate = appendGate;
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
        recordingId: 'meeting-queue-failure',
        format: format,
        sourceId: 'source',
        trackId: 'track',
        clockId: 'clock',
        segmentFrameCount: 20,
        queueCapacityFrames: 2,
        queuePolicy: SegmentedWavQueuePolicy.failRecorder,
        storage: storage,
      );
      await recorder.start();

      final Future<SegmentedWavWriteResult> active = recorder.write(
        _frame(format, <double>[0.1, 0.2]),
      );
      await storage.appendStarted.future;
      final Future<SegmentedWavWriteResult> queued = recorder.write(
        _frame(format, <double>[0.3, 0.4], sequence: 1, sampleOffset: 2),
      );
      final Future<void> queuedFailure = expectLater(
        queued,
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'segmented_wav_queue_overflow',
          ),
        ),
      );
      final Future<SegmentedWavWriteResult> overflow = recorder.write(
        _frame(format, <double>[0.5, 0.6], sequence: 2, sampleOffset: 4),
      );
      appendGate.complete();

      expect((await active).wasWritten, isTrue);
      await queuedFailure;
      await expectLater(
        overflow,
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'segmented_wav_queue_overflow',
          ),
        ),
      );
      expect(recorder.state, SegmentedWavRecordingState.failed);
      expect(recorder.queuedFrameCount, 0);
      await recorder.close();
    },
  );

  test('repairs stale headers and truncates a killed partial sample', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final SegmentedWavRecorder recorder = await SegmentedWavRecorder.create(
      storage: LocalSegmentedWavStorage(temporaryDirectory.path),
      recordingId: 'meeting-recovery',
      format: format,
      sourceId: 'source',
      trackId: 'track',
      clockId: 'clock',
      segmentFrameCount: 10,
      queueCapacityFrames: 10,
    );
    await recorder.start();
    await recorder.write(_frame(format, <double>[0.1, 0.2, 0.3, 0.4]));
    await recorder.finish();
    final String segmentPath =
        '${temporaryDirectory.path}/${recorder.manifest.segments.single.fileName}';
    await recorder.close();

    final RandomAccessFile killed = await File(
      segmentPath,
    ).open(mode: FileMode.append);
    await killed.writeFrom(<int>[0x01, 0x00, 0xff]);
    await killed.flush();
    await killed.close();

    final SegmentedWavRecoveryResult recovery =
        await recoverSegmentedWavRecording(
          manifestFileName: recorder.manifestFileName,
          storage: LocalSegmentedWavStorage(temporaryDirectory.path),
        );

    expect(recovery.truncatedByteCount, 1);
    expect(recovery.repairedSegmentIds, <String>['meeting-recovery:segment:0']);
    expect(recovery.manifest.state, SegmentedWavRecordingState.recovered);
    expect(recovery.manifest.segments.single.frameCount, 5);
    final Uint8List repairedBytes = await File(segmentPath).readAsBytes();
    expect(repairedBytes.length, 44 + 10);
    expect(inspectWav(repairedBytes).sampleFrameCount, 5);

    final RandomAccessFile corrupt = await File(
      segmentPath,
    ).open(mode: FileMode.append);
    await corrupt.setPosition(0);
    await corrupt.writeFrom(<int>[0, 0, 0, 0]);
    await corrupt.close();
    final WavHeaderRepairResult headerRepair = await repairWavFileHeader(
      path: segmentPath,
      format: format,
      encoding: WavSampleEncoding.pcm16,
    );
    expect(headerRepair.headerWasValid, isFalse);
    expect(
      inspectWav(await File(segmentPath).readAsBytes()).sampleFrameCount,
      5,
    );
  });
}

AudioFrame _frame(
  AudioFormat format,
  List<double> samples, {
  String sourceId = 'source',
  String trackId = 'track',
  String clockId = 'clock',
  int sequence = 0,
  int sampleOffset = 0,
}) => AudioFrame(
  format: format,
  samples: Float32List.fromList(samples),
  sourceId: sourceId,
  trackId: trackId,
  clockId: clockId,
  sequence: sequence,
  sampleOffset: sampleOffset,
  timestamp: format.durationForFrames(sampleOffset),
);

Future<Map<String, Object?>> _readManifest(String path) async =>
    _decodeManifest(await File(path).readAsBytes());

Map<String, Object?> _decodeManifest(Uint8List bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
        .cast<String, Object?>();

final class _MemoryStorage implements SegmentedWavStorage {
  final Map<String, _MemoryFileData> files = <String, _MemoryFileData>{};
  final Completer<void> appendStarted = Completer<void>();
  Completer<void>? appendGate;
  bool failAppends = false;

  @override
  Future<SegmentedWavStorageFile> createFile(
    String fileName,
    Uint8List initialBytes,
  ) async {
    final _MemoryFileData data = _MemoryFileData(initialBytes.toList());
    files[fileName] = data;
    return _MemoryStorageFile(fileName, data, this);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<SegmentedWavStorageFile> openFile(String fileName) async {
    final _MemoryFileData? data = files[fileName];
    if (data == null) {
      throw StateError('Missing memory file: $fileName.');
    }
    return _MemoryStorageFile(fileName, data, this);
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
  _MemoryStorageFile(this.fileName, this._data, this._storage);

  @override
  final String fileName;

  final _MemoryFileData _data;
  final _MemoryStorage _storage;
  bool _closed = false;

  @override
  Future<void> append(Uint8List bytes) async {
    _requireOpen();
    if (!_storage.appendStarted.isCompleted) {
      _storage.appendStarted.complete();
    }
    final Completer<void>? gate = _storage.appendGate;
    if (gate != null) {
      await gate.future;
    }
    if (_storage.failAppends) {
      throw FileSystemException('Injected append failure.');
    }
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
