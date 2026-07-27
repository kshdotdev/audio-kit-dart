import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'audio_processing_wav_sink.',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('streams samples and gracefully finalizes a valid WAV header', () async {
    final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
    final String path = '${temporaryDirectory.path}/recording.wav';
    final WavFileAudioSink sink = WavFileAudioSink(
      path: path,
      encodingBufferBytes: 3,
    );
    final WavFileAudioSinkSession session = await sink.prepare(format);
    final List<AudioSessionState> states = <AudioSessionState>[];
    final StreamSubscription<AudioSessionStatus> statuses = session.statuses
        .listen((AudioSessionStatus status) => states.add(status.state));

    await session.write(_frame(format, <double>[-1, 0]));
    await session.write(
      _frame(
        format,
        <double>[1],
        sequence: 1,
        sampleOffset: 2,
        timestamp: const Duration(microseconds: 125),
      ),
    );
    await session.finish();

    final Uint8List bytes = await File(path).readAsBytes();
    final WavFileInfo info = inspectWav(bytes);
    final ByteData data = ByteData.sublistView(bytes);
    expect(info.sampleFrameCount, 3);
    expect(session.dataLength, 6);
    expect(data.getInt16(44, Endian.little), -32768);
    expect(data.getInt16(46, Endian.little), 0);
    expect(data.getInt16(48, Endian.little), 32767);
    expect(session.status.state, AudioSessionState.finished);

    await session.finish();
    await session.close();
    await session.close();
    await statuses.cancel();
    expect(session.status.state, AudioSessionState.closed);
    expect(
      states,
      containsAllInOrder(<AudioSessionState>[
        AudioSessionState.prepared,
        AudioSessionState.active,
        AudioSessionState.finishing,
        AudioSessionState.finished,
        AudioSessionState.closed,
      ]),
    );
  });

  test('inserts a source gap in bounded chunks exactly once', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final String path = '${temporaryDirectory.path}/gap.wav';
    final WavFileAudioSinkSession session = await WavFileAudioSink(
      path: path,
      gapPolicy: WavGapPolicy.insertSilence,
      encodingBufferBytes: 2,
    ).prepare(format);

    await session.write(_frame(format, <double>[1]));
    await session.write(
      _frame(
        format,
        <double>[1],
        sequence: 2,
        sampleOffset: 3,
        timestamp: const Duration(milliseconds: 3),
        discontinuity: AudioDiscontinuity(
          reason: AudioDiscontinuityReason.droppedFrames,
          droppedFrameCount: 1,
          droppedSampleFrameCount: 2,
        ),
      ),
    );
    await session.finish();

    final Uint8List bytes = await File(path).readAsBytes();
    final ByteData data = ByteData.sublistView(bytes);
    expect(inspectWav(bytes).sampleFrameCount, 4);
    expect(data.getInt16(44, Endian.little), 32767);
    expect(data.getInt16(46, Endian.little), 0);
    expect(data.getInt16(48, Endian.little), 0);
    expect(data.getInt16(50, Endian.little), 32767);
    await session.close();
  });

  test(
    'strict continuity failures leave a finalized accepted prefix',
    () async {
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final String path = '${temporaryDirectory.path}/failed.wav';
      final WavFileAudioSinkSession session = await WavFileAudioSink(
        path: path,
      ).prepare(format);
      await session.write(_frame(format, <double>[0.5, -0.5]));

      await expectLater(
        session.write(
          _frame(
            format,
            <double>[1],
            sequence: 2,
            sampleOffset: 4,
            timestamp: const Duration(milliseconds: 4),
          ),
        ),
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'wav_file_sequence_gap',
          ),
        ),
      );

      expect(session.status.state, AudioSessionState.failed);
      expect(inspectWav(await File(path).readAsBytes()).sampleFrameCount, 2);
      await session.close();
    },
  );

  test('rejects format, stream, timestamp, and offset regressions', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);

    Future<void> expectFailure(
      String name,
      AudioFrame first,
      AudioFrame invalid,
      String code,
    ) async {
      final String path = '${temporaryDirectory.path}/$name.wav';
      final WavFileAudioSinkSession session = await WavFileAudioSink(
        path: path,
        gapPolicy: WavGapPolicy.insertSilence,
      ).prepare(format);
      await session.write(first);
      await expectLater(
        session.write(invalid),
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            code,
          ),
        ),
      );
      await session.close();
    }

    final AudioFrame first = _frame(format, <double>[1]);
    await expectFailure(
      'format',
      first,
      _frame(
        AudioFormat(sampleRate: 2000, channels: 1),
        <double>[1],
        sequence: 1,
        sampleOffset: 1,
      ),
      'wav_file_format_mismatch',
    );
    await expectFailure(
      'stream',
      first,
      _frame(
        format,
        <double>[1],
        sourceId: 'another-source',
        sequence: 1,
        sampleOffset: 1,
      ),
      'wav_file_stream_mismatch',
    );
    await expectFailure(
      'timestamp',
      _frame(format, <double>[1], timestamp: const Duration(milliseconds: 2)),
      _frame(
        format,
        <double>[1],
        sequence: 1,
        sampleOffset: 1,
        timestamp: const Duration(milliseconds: 1),
      ),
      'wav_file_timestamp_regression',
    );
    await expectFailure(
      'offset',
      _frame(format, <double>[1, 2]),
      _frame(format, <double>[1], sequence: 1, sampleOffset: 1),
      'wav_file_offset_regression',
    );
  });

  test(
    'abort can finalize accepted audio or delete the partial file',
    () async {
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final String finalizedPath = '${temporaryDirectory.path}/aborted.wav';
      final WavFileAudioSinkSession finalized = await WavFileAudioSink(
        path: finalizedPath,
      ).prepare(format);
      await finalized.write(_frame(format, <double>[1, 0]));
      await finalized.abort();

      expect(finalized.status.state, AudioSessionState.aborted);
      expect(
        inspectWav(await File(finalizedPath).readAsBytes()).sampleFrameCount,
        2,
      );
      await finalized.close();

      final String deletedPath = '${temporaryDirectory.path}/deleted.wav';
      final WavFileAudioSinkSession deleted = await WavFileAudioSink(
        path: deletedPath,
        abortPolicy: WavFileAbortPolicy.deletePartial,
      ).prepare(format);
      await deleted.write(_frame(format, <double>[1]));
      await deleted.abort();

      expect(deleted.status.state, AudioSessionState.aborted);
      expect(await File(deletedPath).exists(), isFalse);
      await deleted.close();
    },
  );

  test(
    'close before finish is idempotent and finalizes an empty file',
    () async {
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 2);
      final String path = '${temporaryDirectory.path}/empty.wav';
      final WavFileAudioSinkSession session = await WavFileAudioSink(
        path: path,
      ).prepare(format);

      await session.close();
      await session.close();

      final WavFileInfo info = inspectWav(await File(path).readAsBytes());
      expect(info.channels, 2);
      expect(info.sampleFrameCount, 0);
      expect(session.status.state, AudioSessionState.closed);
    },
  );

  test('encoding buffer must hold a complete interleaved sample frame', () {
    final WavFileAudioSink sink = WavFileAudioSink(
      path: '${temporaryDirectory.path}/invalid.wav',
      encodingBufferBytes: 3,
    );

    expect(
      () => sink.prepare(AudioFormat(sampleRate: 1000, channels: 2)),
      throwsArgumentError,
    );
  });

  test('abort interrupts a bounded in-flight file write', () async {
    final AudioFormat format = AudioFormat(sampleRate: 48000, channels: 1);
    final String path = '${temporaryDirectory.path}/interrupt.wav';
    final WavFileAudioSinkSession session = await WavFileAudioSink(
      path: path,
      encodingBufferBytes: 2,
    ).prepare(format);
    final Future<Object?> writeResult = session
        .write(_frame(format, Float32List(100000).toList(growable: false)))
        .then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );

    await Future<void>.delayed(Duration.zero);
    await Future.wait<void>(<Future<void>>[session.abort(), session.abort()]);

    expect(await writeResult, isA<AudioCancelledException>());
    expect(session.status.state, AudioSessionState.aborted);
    final WavFileInfo info = inspectWav(await File(path).readAsBytes());
    expect(info.sampleFrameCount, lessThan(100000));
    await session.close();
  });

  test('paused status observer cannot hang file close', () async {
    final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
    final WavFileAudioSinkSession session = await WavFileAudioSink(
      path: '${temporaryDirectory.path}/paused-observer.wav',
    ).prepare(format);
    final StreamSubscription<AudioSessionStatus> observer = session.statuses
        .listen((_) {});
    observer.pause();

    await session.close().timeout(const Duration(seconds: 1));

    expect(session.status.state, AudioSessionState.closed);
    await observer.cancel();
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
  Duration timestamp = Duration.zero,
  AudioDiscontinuity? discontinuity,
}) => AudioFrame.owned(
  format: format,
  samples: Float32List.fromList(samples),
  sourceId: sourceId,
  trackId: trackId,
  clockId: clockId,
  sequence: sequence,
  sampleOffset: sampleOffset,
  timestamp: timestamp,
  discontinuity: discontinuity,
);
