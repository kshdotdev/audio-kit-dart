import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'segmented_wav_manifest.dart';
import 'segmented_wav_storage.dart';
import 'wav.dart';
import 'wav_io_helpers.dart';

/// Result of repairing one canonical WAV header and trailing partial frame.
final class WavHeaderRepairResult {
  const WavHeaderRepairResult({
    required this.dataLength,
    required this.truncatedByteCount,
    required this.headerWasValid,
    required this.headerChanged,
  });

  final int dataLength;
  final int truncatedByteCount;
  final bool headerWasValid;
  final bool headerChanged;
}

/// Result of recovering every segment and replacing its durable sidecar.
final class SegmentedWavRecoveryResult {
  SegmentedWavRecoveryResult({
    required this.manifest,
    required List<String> repairedSegmentIds,
    required this.truncatedByteCount,
  }) : repairedSegmentIds = List<String>.unmodifiable(repairedSegmentIds);

  final SegmentedWavRecordingManifest manifest;
  final List<String> repairedSegmentIds;
  final int truncatedByteCount;
}

/// Repairs segments named by a durable sidecar after an interrupted process.
Future<SegmentedWavRecoveryResult> recoverSegmentedWavRecording({
  required String manifestFileName,
  required SegmentedWavStorage storage,
}) async {
  await storage.initialize();
  final Uint8List manifestBytes = await storage.readFile(manifestFileName);
  final Object? decoded = jsonDecode(utf8.decode(manifestBytes));
  if (decoded is! Map<Object?, Object?>) {
    throw const FormatException('The segmented WAV sidecar is not an object.');
  }
  final Map<String, Object?> json = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in decoded.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw const FormatException(
        'The segmented WAV sidecar has a non-string key.',
      );
    }
    json[key] = entry.value;
  }
  final SegmentedWavRecordingManifest original =
      SegmentedWavRecordingManifest.fromJson(json);
  final List<SegmentedWavSegmentManifest> repairedSegments =
      <SegmentedWavSegmentManifest>[];
  final List<String> repairedIds = <String>[];
  var truncatedBytes = 0;
  var totalFrames = 0;
  for (final SegmentedWavSegmentManifest segment in original.segments) {
    final SegmentedWavStorageFile file = await storage.openFile(
      segment.fileName,
    );
    late final WavHeaderRepairResult repair;
    try {
      repair = await repairWavStorageFile(
        file,
        format: original.format,
        encoding: original.encoding,
      );
    } finally {
      await file.close();
    }
    final int bytesPerFrame =
        original.format.channels * original.encoding.bytesPerSample;
    final int frameCount = repair.dataLength ~/ bytesPerFrame;
    final SegmentedWavSegmentManifest repaired = SegmentedWavSegmentManifest(
      segmentId: segment.segmentId,
      fileName: segment.fileName,
      startFrame: segment.startFrame,
      frameCount: frameCount,
      finalized: true,
    );
    repairedSegments.add(repaired);
    final int endFrame = repaired.startFrame + repaired.frameCount;
    if (endFrame > totalFrames) {
      totalFrames = endFrame;
    }
    truncatedBytes += repair.truncatedByteCount;
    if (!segment.finalized ||
        segment.frameCount != frameCount ||
        repair.headerChanged ||
        repair.truncatedByteCount > 0) {
      repairedIds.add(segment.segmentId);
    }
  }

  final SegmentedWavRecordingManifest recovered = SegmentedWavRecordingManifest(
    recordingId: original.recordingId,
    sourceId: original.sourceId,
    trackId: original.trackId,
    clockId: original.clockId,
    format: original.format,
    encoding: original.encoding,
    segmentFrameCount: original.segmentFrameCount,
    queueCapacityFrames: original.queueCapacityFrames,
    queuePolicy: original.queuePolicy,
    gapPolicy: original.gapPolicy,
    state: SegmentedWavRecordingState.recovered,
    revision: original.revision + 1,
    totalFrameCount: totalFrames,
    droppedFrameCount: original.droppedFrameCount,
    segments: repairedSegments,
    markers: original.markers,
  );
  await storage.writeFileAtomically(
    manifestFileName,
    Uint8List.fromList(utf8.encode(jsonEncode(recovered.toJson()))),
  );
  return SegmentedWavRecoveryResult(
    manifest: recovered,
    repairedSegmentIds: repairedIds,
    truncatedByteCount: truncatedBytes,
  );
}

/// Repairs one canonical WAV held in [file] after a torn append or header
/// flush.
///
/// [format] and [encoding] are required because a torn header cannot safely
/// describe its own payload. Recovery keeps only complete interleaved sample
/// frames and performs all reads in a fixed 44-byte window. The caller owns
/// closing [file].
Future<WavHeaderRepairResult> repairWavStorageFile(
  SegmentedWavStorageFile file, {
  required AudioFormat format,
  required WavSampleEncoding encoding,
}) async {
  final int originalLength = await file.length();
  final int availableHeaderBytes = originalLength < canonicalWavHeaderLength
      ? originalLength
      : canonicalWavHeaderLength;
  final Uint8List oldHeader = availableHeaderBytes == 0
      ? Uint8List(0)
      : await file.readAt(0, availableHeaderBytes);
  var headerWasValid = false;
  int? declaredDataLength;
  if (oldHeader.length == canonicalWavHeaderLength) {
    try {
      validateCanonicalWavHeader(
        oldHeader,
        expectedFormat: format,
        expectedEncoding: encoding,
      );
      headerWasValid = true;
      declaredDataLength = canonicalWavDeclaredDataLength(oldHeader);
    } on FormatException {
      // Expected format is authoritative for a torn or corrupted header.
    }
  }
  final int rawDataLength = originalLength <= canonicalWavHeaderLength
      ? 0
      : originalLength - canonicalWavHeaderLength;
  final int bytesPerFrame = format.channels * encoding.bytesPerSample;
  final int repairedDataLength =
      rawDataLength - (rawDataLength % bytesPerFrame);
  final int truncatedBytes = rawDataLength - repairedDataLength;
  final bool headerChanged =
      !headerWasValid || declaredDataLength != repairedDataLength;
  await file.truncate(canonicalWavHeaderLength + repairedDataLength);
  await file.writeAt(
    0,
    buildCanonicalWavHeader(
      format: format,
      encoding: encoding,
      dataLength: repairedDataLength,
    ),
  );
  await file.flush();
  return WavHeaderRepairResult(
    dataLength: repairedDataLength,
    truncatedByteCount: truncatedBytes,
    headerWasValid: headerWasValid,
    headerChanged: headerChanged,
  );
}
