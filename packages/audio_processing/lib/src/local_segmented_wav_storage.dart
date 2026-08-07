import 'dart:io';
import 'dart:typed_data';

import 'segmented_wav_storage.dart';

/// Local Dart IO adapter rooted at one recording directory.
final class LocalSegmentedWavStorage implements SegmentedWavStorage {
  LocalSegmentedWavStorage(this.directoryPath) {
    if (directoryPath.trim().isEmpty) {
      throw ArgumentError.value(
        directoryPath,
        'directoryPath',
        'Must not be empty.',
      );
    }
  }

  final String directoryPath;
  var _temporarySequence = 0;

  @override
  Future<void> initialize() => Directory(directoryPath).create(recursive: true);

  @override
  Future<SegmentedWavStorageFile> createFile(
    String fileName,
    Uint8List initialBytes,
  ) async {
    final File file = _file(fileName);
    final RandomAccessFile handle = await file.open(mode: FileMode.write);
    try {
      await handle.writeFrom(initialBytes);
      return _LocalSegmentedWavStorageFile(fileName, handle);
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  @override
  Future<SegmentedWavStorageFile> openFile(String fileName) async {
    final File file = _file(fileName);
    if (!await file.exists()) {
      throw FileSystemException('Recording segment does not exist.', file.path);
    }
    final RandomAccessFile handle = await file.open(mode: FileMode.append);
    return _LocalSegmentedWavStorageFile(fileName, handle);
  }

  @override
  Future<Uint8List> readFile(String fileName) => _file(fileName).readAsBytes();

  @override
  Future<void> writeFileAtomically(String fileName, Uint8List bytes) async {
    final File destination = _file(fileName);
    final int sequence = _temporarySequence++;
    final File temporary = File(
      '${destination.path}.${pid.toString()}.$sequence.tmp',
    );
    RandomAccessFile? handle;
    try {
      handle = await temporary.open(mode: FileMode.write);
      await handle.writeFrom(bytes);
      await handle.flush();
      await handle.close();
      handle = null;
      await temporary.rename(destination.path);
    } catch (_) {
      if (handle != null) {
        await handle.close();
      }
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  File _file(String fileName) {
    _validateFileName(fileName);
    return File('$directoryPath${Platform.pathSeparator}$fileName');
  }
}

final class _LocalSegmentedWavStorageFile implements SegmentedWavStorageFile {
  _LocalSegmentedWavStorageFile(this.fileName, this._handle);

  @override
  final String fileName;

  final RandomAccessFile _handle;
  bool _closed = false;

  @override
  Future<void> append(Uint8List bytes) async {
    _requireOpen();
    await _handle.setPosition(await _handle.length());
    await _handle.writeFrom(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _handle.close();
  }

  @override
  Future<void> flush() {
    _requireOpen();
    return _handle.flush();
  }

  @override
  Future<int> length() {
    _requireOpen();
    return _handle.length();
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    _requireOpen();
    if (offset < 0 || length < 0) {
      throw ArgumentError('Read offsets and lengths must not be negative.');
    }
    await _handle.setPosition(offset);
    return _handle.read(length);
  }

  @override
  Future<void> truncate(int length) async {
    _requireOpen();
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'Must not be negative.');
    }
    await _handle.truncate(length);
  }

  @override
  Future<void> writeAt(int offset, Uint8List bytes) async {
    _requireOpen();
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Must not be negative.');
    }
    await _handle.setPosition(offset);
    await _handle.writeFrom(bytes);
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('Storage file $fileName is closed.');
    }
  }
}

void _validateFileName(String fileName) {
  if (fileName.trim().isEmpty ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.contains('/') ||
      fileName.contains(r'\')) {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'Must be a plain file name inside the recording directory.',
    );
  }
}
