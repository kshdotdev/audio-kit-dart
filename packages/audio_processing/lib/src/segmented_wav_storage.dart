import 'dart:typed_data';

/// Minimal file handle needed by segmented recording and recovery.
abstract interface class SegmentedWavStorageFile {
  String get fileName;

  Future<int> length();

  Future<Uint8List> readAt(int offset, int length);

  Future<void> append(Uint8List bytes);

  Future<void> writeAt(int offset, Uint8List bytes);

  Future<void> truncate(int length);

  Future<void> flush();

  Future<void> close();
}

/// Driven storage port implemented by the `dart:io` local adapter in
/// `package:audio_processing/audio_processing_io.dart` and by test adapters.
abstract interface class SegmentedWavStorage {
  Future<void> initialize();

  Future<SegmentedWavStorageFile> createFile(
    String fileName,
    Uint8List initialBytes,
  );

  Future<SegmentedWavStorageFile> openFile(String fileName);

  Future<Uint8List> readFile(String fileName);

  /// Replaces [fileName] only after [bytes] have been flushed completely.
  Future<void> writeFileAtomically(String fileName, Uint8List bytes);
}
