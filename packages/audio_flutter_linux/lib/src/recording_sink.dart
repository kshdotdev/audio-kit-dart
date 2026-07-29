import 'dart:io';
import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Source-side recorder fed the same signed 16-bit PCM the capture tool emits.
///
/// The Darwin implementation records natively; on Linux the bytes already pass
/// through Dart, so the recording is written here.
abstract interface class LinuxRecordingSink {
  Future<void> open();

  void add(List<int> pcm16);

  /// Finalizes the file, patching any size fields.
  Future<void> close();

  /// Discards the recording without finalizing it.
  Future<void> abort();
}

/// Builds the sink used for [PlatformCaptureRequest.rawRecordingPath].
typedef LinuxRecordingSinkFactory =
    LinuxRecordingSink Function(String path, PlatformPcmFormat format);

/// Streaming WAV writer: a placeholder header is written up front and the two
/// size fields are patched on [close], so an aborted capture still leaves a
/// readable prefix on disk.
final class WavFileRecordingSink implements LinuxRecordingSink {
  WavFileRecordingSink(this.path, this.format);

  static const int _headerBytes = 44;
  static const int _bitsPerSample = 16;

  final String path;
  final PlatformPcmFormat format;

  RandomAccessFile? _file;
  int _dataBytes = 0;

  @override
  Future<void> open() async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    final RandomAccessFile handle = await file.open(mode: FileMode.write);
    await handle.writeFrom(_header(0));
    _file = handle;
    _dataBytes = 0;
  }

  @override
  void add(List<int> pcm16) {
    final RandomAccessFile? handle = _file;
    if (handle == null) {
      return;
    }
    handle.writeFromSync(pcm16);
    _dataBytes += pcm16.length;
  }

  @override
  Future<void> close() async {
    final RandomAccessFile? handle = _file;
    if (handle == null) {
      return;
    }
    _file = null;
    await handle.setPosition(0);
    await handle.writeFrom(_header(_dataBytes));
    await handle.flush();
    await handle.close();
  }

  @override
  Future<void> abort() async {
    // A partially written recording is still worth keeping, so aborting
    // finalizes the header exactly like a graceful stop.
    await close();
  }

  Uint8List _header(int dataBytes) {
    final int byteRate =
        format.sampleRate * format.channelCount * (_bitsPerSample ~/ 8);
    final int blockAlign = format.channelCount * (_bitsPerSample ~/ 8);
    final Uint8List header = Uint8List(_headerBytes);
    final ByteData data = ByteData.sublistView(header);
    header.setRange(0, 4, 'RIFF'.codeUnits);
    data.setUint32(4, _headerBytes - 8 + dataBytes, Endian.little);
    header.setRange(8, 12, 'WAVE'.codeUnits);
    header.setRange(12, 16, 'fmt '.codeUnits);
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, format.channelCount, Endian.little)
      ..setUint32(24, format.sampleRate, Endian.little)
      ..setUint32(28, byteRate, Endian.little)
      ..setUint16(32, blockAlign, Endian.little)
      ..setUint16(34, _bitsPerSample, Endian.little);
    header.setRange(36, 40, 'data'.codeUnits);
    data.setUint32(40, dataBytes, Endian.little);
    return header;
  }
}
