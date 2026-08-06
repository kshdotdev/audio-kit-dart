import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'segmented_wav_storage.dart';
import 'wav.dart';
import 'wav_recovery.dart';

/// Repairs a canonical WAV after a kill between data append and header flush.
///
/// [format] and [encoding] are required because a torn header cannot safely
/// describe its own payload. Recovery keeps only complete interleaved sample
/// frames and performs all reads in a fixed 44-byte window.
Future<WavHeaderRepairResult> repairWavFileHeader({
  required String path,
  required AudioFormat format,
  required WavSampleEncoding encoding,
}) async {
  if (path.trim().isEmpty) {
    throw ArgumentError.value(path, 'path', 'Must not be empty.');
  }
  final File source = File(path);
  if (!await source.exists()) {
    throw FileSystemException('WAV file does not exist.', path);
  }
  final RandomAccessFile file = await source.open(mode: FileMode.append);
  final _RandomAccessRepairFile repairFile = _RandomAccessRepairFile(file);
  try {
    return await repairWavStorageFile(
      repairFile,
      format: format,
      encoding: encoding,
    );
  } finally {
    await repairFile.close();
  }
}

final class _RandomAccessRepairFile implements SegmentedWavStorageFile {
  _RandomAccessRepairFile(this._file);

  final RandomAccessFile _file;

  @override
  String get fileName => _file.path;

  @override
  Future<void> append(Uint8List bytes) async {
    await _file.setPosition(await _file.length());
    await _file.writeFrom(bytes);
  }

  @override
  Future<void> close() => _file.close();

  @override
  Future<void> flush() => _file.flush();

  @override
  Future<int> length() => _file.length();

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    await _file.setPosition(offset);
    return _file.read(length);
  }

  @override
  Future<void> truncate(int length) => _file.truncate(length);

  @override
  Future<void> writeAt(int offset, Uint8List bytes) async {
    await _file.setPosition(offset);
    await _file.writeFrom(bytes);
  }
}
