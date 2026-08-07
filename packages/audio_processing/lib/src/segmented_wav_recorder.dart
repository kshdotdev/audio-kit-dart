import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'segmented_wav_manifest.dart';
import 'segmented_wav_storage.dart';
import 'wav.dart';
import 'wav_io_helpers.dart';

/// Result returned when a frame leaves the bounded input queue.
enum SegmentedWavWriteDisposition { written, droppedNewest, droppedOldest }

/// Durable disposition of one submitted frame.
final class SegmentedWavWriteResult {
  const SegmentedWavWriteResult({
    required this.disposition,
    required this.frameCount,
  });

  final SegmentedWavWriteDisposition disposition;
  final int frameCount;

  bool get wasWritten => disposition == SegmentedWavWriteDisposition.written;
}

/// Bounded, crash-recoverable WAV recorder that rotates fixed-size segments.
///
/// A frame is copied only after queue capacity is reserved. The write future
/// completes after its audio, current WAV header, and sidecar manifest have all
/// been flushed. Native capture callbacks should route through their existing
/// bounded mailbox rather than call this object synchronously.
final class SegmentedWavRecorder {
  SegmentedWavRecorder._({
    required this.recordingId,
    required this.manifestFileName,
    required this.format,
    required this.encoding,
    required this.segmentFrameCount,
    required this.queueCapacityFrames,
    required this.queuePolicy,
    required this.gapPolicy,
    required this.encodingBufferBytes,
    required this.trackId,
    required String sourceId,
    required String clockId,
    required this._storage,
  }) : _initialSourceId = sourceId,
       _initialClockId = clockId,
       _currentSourceId = sourceId,
       _currentClockId = clockId;

  /// Prepares a new segmented recording and durably writes its empty manifest.
  static Future<SegmentedWavRecorder> create({
    required String recordingId,
    required AudioFormat format,
    required String sourceId,
    required String trackId,
    required String clockId,
    WavSampleEncoding encoding = WavSampleEncoding.pcm16,
    WavGapPolicy gapPolicy = WavGapPolicy.insertSilence,
    int segmentFrameCount = 48000 * 60,
    int queueCapacityFrames = 48000 * 2,
    SegmentedWavQueuePolicy queuePolicy = SegmentedWavQueuePolicy.wait,
    int encodingBufferBytes = 64 * 1024,
    String? manifestFileName,
    required SegmentedWavStorage storage,
  }) async {
    _requireRecorderIdentifier(recordingId, 'recordingId');
    _requireRecorderIdentifier(sourceId, 'sourceId');
    _requireRecorderIdentifier(trackId, 'trackId');
    _requireRecorderIdentifier(clockId, 'clockId');
    if (segmentFrameCount <= 0 || queueCapacityFrames <= 0) {
      throw ArgumentError('Segment and queue frame counts must be positive.');
    }
    final int bytesPerFrame = format.channels * encoding.bytesPerSample;
    if (segmentFrameCount * bytesPerFrame > 0xffffffff - 36) {
      throw ArgumentError.value(
        segmentFrameCount,
        'segmentFrameCount',
        'One WAV segment would exceed RIFF size limits.',
      );
    }
    if (encodingBufferBytes < bytesPerFrame) {
      throw ArgumentError.value(
        encodingBufferBytes,
        'encodingBufferBytes',
        'Must hold at least one encoded sample frame.',
      );
    }
    final String resolvedManifestName =
        manifestFileName ?? '${_safeFileComponent(recordingId)}.segments.json';
    _requirePlainFileName(resolvedManifestName, 'manifestFileName');
    final SegmentedWavRecorder recorder = SegmentedWavRecorder._(
      recordingId: recordingId,
      manifestFileName: resolvedManifestName,
      format: format,
      encoding: encoding,
      segmentFrameCount: segmentFrameCount,
      queueCapacityFrames: queueCapacityFrames,
      queuePolicy: queuePolicy,
      gapPolicy: gapPolicy,
      encodingBufferBytes: encodingBufferBytes,
      sourceId: sourceId,
      trackId: trackId,
      clockId: clockId,
      storage: storage,
    );
    try {
      await storage.initialize();
      await recorder._persistManifest();
      return recorder;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _recorderFailure(
          error,
          code: 'segmented_wav_prepare_failed',
          message: 'The segmented WAV recording could not be prepared.',
        ),
        stackTrace,
      );
    }
  }

  final String recordingId;
  final String manifestFileName;
  final AudioFormat format;
  final WavSampleEncoding encoding;
  final int segmentFrameCount;
  final int queueCapacityFrames;
  final SegmentedWavQueuePolicy queuePolicy;
  final WavGapPolicy gapPolicy;
  final int encodingBufferBytes;
  final String trackId;

  final SegmentedWavStorage _storage;
  final String _initialSourceId;
  final String _initialClockId;
  String _currentSourceId;
  String _currentClockId;
  final List<_MutableSegment> _segments = <_MutableSegment>[];
  final List<SegmentedWavMarker> _markers = <SegmentedWavMarker>[];
  final ListQueue<_PendingFrame> _queue = ListQueue<_PendingFrame>();
  _MutableSegment? _currentSegment;
  Future<void>? _workerFuture;
  Completer<void>? _capacityChanged;
  SegmentedWavRecordingState _state = SegmentedWavRecordingState.prepared;
  AudioFailure? _failure;
  int _revision = 0;
  int _totalFrameCount = 0;
  int _droppedFrameCount = 0;
  int _queuedFrameCount = 0;
  int? _expectedSourceSampleOffset;
  bool _acceptingWrites = false;
  bool _closed = false;

  SegmentedWavRecordingState get state => _state;
  AudioFailure? get failure => _failure;
  int get queuedFrameCount => _queuedFrameCount;
  int get totalFrameCount => _totalFrameCount;
  int get droppedFrameCount => _droppedFrameCount;

  /// Latest in-memory view; each completed write has already persisted it.
  SegmentedWavRecordingManifest get manifest => _snapshot(_revision);

  /// Opens the recorder for frame submission.
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (_state != SegmentedWavRecordingState.prepared) {
      throw StateError('A segmented WAV recorder starts exactly once.');
    }
    _state = SegmentedWavRecordingState.recording;
    _acceptingWrites = true;
    await _persistOrFail();
  }

  /// Submits one frame according to the configured bounded queue policy.
  Future<SegmentedWavWriteResult> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    _requireWritableFrame(frame);
    final int frameCount = frame.frameCount;
    if (frameCount > queueCapacityFrames) {
      if (queuePolicy == SegmentedWavQueuePolicy.dropNewest ||
          queuePolicy == SegmentedWavQueuePolicy.dropOldest) {
        _droppedFrameCount += frameCount;
        return SegmentedWavWriteResult(
          disposition: SegmentedWavWriteDisposition.droppedNewest,
          frameCount: frameCount,
        );
      }
      if (queuePolicy == SegmentedWavQueuePolicy.failRecorder) {
        final AudioFailure failure = AudioFailure(
          code: 'segmented_wav_queue_overflow',
          stage: AudioFailureStage.encoding,
          message: 'An input frame exceeded the bounded WAV queue capacity.',
        );
        await _failForQueueOverflow(failure);
        throw failure;
      }
      throw ArgumentError.value(
        frameCount,
        'frame',
        'A single frame cannot exceed queueCapacityFrames.',
      );
    }

    while (_queuedFrameCount + frameCount > queueCapacityFrames) {
      cancellationToken?.throwIfCancelled();
      switch (queuePolicy) {
        case SegmentedWavQueuePolicy.wait:
          final Completer<void> capacity = _capacityChanged ??=
              Completer<void>();
          await capacity.future;
          _requireWritableFrame(frame);
        case SegmentedWavQueuePolicy.dropNewest:
          _droppedFrameCount += frameCount;
          return SegmentedWavWriteResult(
            disposition: SegmentedWavWriteDisposition.droppedNewest,
            frameCount: frameCount,
          );
        case SegmentedWavQueuePolicy.dropOldest:
          final _PendingFrame dropped = _queue.removeFirst();
          _queuedFrameCount -= dropped.frame.frameCount;
          _droppedFrameCount += dropped.frame.frameCount;
          dropped.complete(
            SegmentedWavWriteResult(
              disposition: SegmentedWavWriteDisposition.droppedOldest,
              frameCount: dropped.frame.frameCount,
            ),
          );
          _signalCapacity();
        case SegmentedWavQueuePolicy.failRecorder:
          final AudioFailure failure = AudioFailure(
            code: 'segmented_wav_queue_overflow',
            stage: AudioFailureStage.encoding,
            message: 'The bounded WAV input queue overflowed.',
          );
          await _failForQueueOverflow(failure);
          throw failure;
      }
    }

    final _PendingFrame pending = _PendingFrame(frame.copyWith());
    _queue.addLast(pending);
    _queuedFrameCount += frameCount;
    _ensureWorker();
    return pending.future;
  }

  /// Drains and durably checkpoints all frames accepted before this call.
  Future<void> flush({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (_state != SegmentedWavRecordingState.recording &&
        _state != SegmentedWavRecordingState.paused) {
      throw StateError('Only an active recording can be flushed.');
    }
    final bool resumeAcceptance = _acceptingWrites;
    _acceptingWrites = false;
    await _awaitDrain();
    cancellationToken?.throwIfCancelled();
    _throwIfFailed();
    await _runExternalStorageOperation(_checkpointActiveAndPersist);
    if (resumeAcceptance && _state == SegmentedWavRecordingState.recording) {
      _acceptingWrites = true;
    }
  }

  /// Drains accepted frames, checkpoints, and records a pause marker.
  Future<void> pause({
    String? reason,
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (_state != SegmentedWavRecordingState.recording) {
      throw StateError('Only a recording WAV writer can be paused.');
    }
    _acceptingWrites = false;
    await _awaitDrain();
    cancellationToken?.throwIfCancelled();
    _throwIfFailed();
    await _runExternalStorageOperation(_checkpointActiveAndPersist);
    _markers.add(
      SegmentedWavMarker(
        markerId: '$recordingId:marker:${_markers.length}',
        type: SegmentedWavMarkerType.pause,
        frameOffset: _totalFrameCount,
        reason: reason,
      ),
    );
    _state = SegmentedWavRecordingState.paused;
    await _persistOrFail();
  }

  /// Records a resume marker and accepts frames again.
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (_state != SegmentedWavRecordingState.paused) {
      throw StateError('Only a paused WAV writer can be resumed.');
    }
    _markers.add(
      SegmentedWavMarker(
        markerId: '$recordingId:marker:${_markers.length}',
        type: SegmentedWavMarkerType.resume,
        frameOffset: _totalFrameCount,
      ),
    );
    _state = SegmentedWavRecordingState.recording;
    await _persistOrFail();
    _acceptingWrites = true;
  }

  /// Drains the old source and durably marks the new source/clock mapping.
  Future<void> markSourceChanged({
    required String sourceId,
    required String clockId,
    String? reason,
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    _requireRecorderIdentifier(sourceId, 'sourceId');
    _requireRecorderIdentifier(clockId, 'clockId');
    _requireOpen();
    if (_state != SegmentedWavRecordingState.recording &&
        _state != SegmentedWavRecordingState.paused) {
      throw StateError('Source changes require an active recording.');
    }
    if (sourceId == _currentSourceId && clockId == _currentClockId) {
      throw ArgumentError('The capture source and clock did not change.');
    }
    final bool resumeAcceptance = _acceptingWrites;
    _acceptingWrites = false;
    await _awaitDrain();
    cancellationToken?.throwIfCancelled();
    _throwIfFailed();
    await _runExternalStorageOperation(_checkpointActiveAndPersist);
    _markers.add(
      SegmentedWavMarker(
        markerId: '$recordingId:marker:${_markers.length}',
        type: SegmentedWavMarkerType.sourceChange,
        frameOffset: _totalFrameCount,
        fromSourceId: _currentSourceId,
        toSourceId: sourceId,
        fromClockId: _currentClockId,
        toClockId: clockId,
        reason: reason,
      ),
    );
    _currentSourceId = sourceId;
    _currentClockId = clockId;
    _expectedSourceSampleOffset = null;
    await _persistOrFail();
    if (resumeAcceptance && _state == SegmentedWavRecordingState.recording) {
      _acceptingWrites = true;
    }
  }

  /// Finalizes every segment and the sidecar manifest.
  Future<void> finish({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (_state == SegmentedWavRecordingState.finished ||
        _state == SegmentedWavRecordingState.recovered) {
      return;
    }
    _throwIfFailed();
    if (_state != SegmentedWavRecordingState.prepared &&
        _state != SegmentedWavRecordingState.recording &&
        _state != SegmentedWavRecordingState.paused) {
      throw StateError('The segmented WAV recording cannot be finalized.');
    }
    _acceptingWrites = false;
    await _awaitDrain();
    cancellationToken?.throwIfCancelled();
    _throwIfFailed();
    await _runExternalStorageOperation(_finalizeCurrentSegment);
    _state = SegmentedWavRecordingState.finished;
    await _persistOrFail();
  }

  /// Gracefully finalizes open recording data and releases file handles.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    if (_state != SegmentedWavRecordingState.failed &&
        _state != SegmentedWavRecordingState.finished &&
        _state != SegmentedWavRecordingState.recovered) {
      await finish();
    }
    _closed = true;
    final _MutableSegment? segment = _currentSegment;
    _currentSegment = null;
    if (segment != null) {
      await segment.file.close();
    }
  }

  void _requireWritableFrame(AudioFrame frame) {
    _requireOpen();
    _throwIfFailed();
    if (_state != SegmentedWavRecordingState.recording || !_acceptingWrites) {
      throw StateError('The segmented WAV recorder is not accepting frames.');
    }
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Frame format must match the recorder format.',
      );
    }
    if (frame.trackId != trackId ||
        frame.sourceId != _currentSourceId ||
        frame.clockId != _currentClockId) {
      throw ArgumentError.value(
        '${frame.sourceId}/${frame.trackId}/${frame.clockId}',
        'frame',
        'Frame stream identity does not match the active source marker.',
      );
    }
  }

  void _ensureWorker() {
    if (_workerFuture != null || _queue.isEmpty) {
      return;
    }
    _workerFuture = _drainQueue();
  }

  Future<void> _drainQueue() async {
    try {
      while (_queue.isNotEmpty && _state != SegmentedWavRecordingState.failed) {
        final _PendingFrame pending = _queue.removeFirst();
        _queuedFrameCount -= pending.frame.frameCount;
        _signalCapacity();
        try {
          await _writeFrame(pending.frame);
          await _checkpointActiveAndPersist();
          pending.complete(
            SegmentedWavWriteResult(
              disposition: SegmentedWavWriteDisposition.written,
              frameCount: pending.frame.frameCount,
            ),
          );
        } catch (error, stackTrace) {
          final AudioFailure failure = _recorderFailure(
            error,
            code: 'segmented_wav_io_failed',
            message: 'The segmented WAV writer could not persist audio.',
          );
          await _enterFailed(failure, stackTrace: stackTrace);
          pending.completeError(failure, stackTrace);
        }
      }
    } finally {
      _workerFuture = null;
      if (_queue.isNotEmpty && _state != SegmentedWavRecordingState.failed) {
        _ensureWorker();
      }
    }
  }

  Future<void> _writeFrame(AudioFrame frame) async {
    final int explicitGap = frame.discontinuity?.droppedSampleFrameCount ?? 0;
    final int? expected = _expectedSourceSampleOffset;
    var gapFrameCount = explicitGap;
    if (expected != null) {
      final int offsetGap = frame.sampleOffset - expected;
      if (offsetGap < 0) {
        throw AudioFailure(
          code: 'segmented_wav_offset_regression',
          stage: AudioFailureStage.encoding,
          message: 'A captured frame overlaps previously recorded audio.',
        );
      }
      if (offsetGap > gapFrameCount) {
        gapFrameCount = offsetGap;
      }
    }
    if (gapFrameCount > 0) {
      if (gapPolicy == WavGapPolicy.reject) {
        throw AudioFailure(
          code: 'segmented_wav_source_gap',
          stage: AudioFailureStage.encoding,
          message: 'A discontinuous frame cannot enter a lossless recording.',
        );
      }
      await _appendSilence(gapFrameCount);
    }
    await _appendSamples(frame.samples);
    _expectedSourceSampleOffset = frame.endSampleOffset;
  }

  Future<void> _appendSilence(int frameCount) async {
    final int maxFrames =
        encodingBufferBytes ~/ (format.channels * encoding.bytesPerSample);
    var remaining = frameCount;
    while (remaining > 0) {
      final int count = _minimum(remaining, maxFrames);
      await _appendSamples(Float32List(count * format.channels));
      remaining -= count;
    }
  }

  Future<void> _appendSamples(Float32List samples) async {
    var sampleIndex = 0;
    while (sampleIndex < samples.length) {
      final _MutableSegment segment = _currentSegment ??=
          await _createNextSegment();
      final int availableFrames = segmentFrameCount - segment.frameCount;
      final int remainingFrames =
          (samples.length - sampleIndex) ~/ format.channels;
      final int frames = _minimum(availableFrames, remainingFrames);
      final int sampleEnd = sampleIndex + frames * format.channels;
      await _encodeRange(segment.file, samples, sampleIndex, sampleEnd);
      segment.frameCount += frames;
      _totalFrameCount += frames;
      sampleIndex = sampleEnd;
      if (segment.frameCount == segmentFrameCount) {
        await _finalizeCurrentSegment();
      }
    }
  }

  Future<void> _encodeRange(
    SegmentedWavStorageFile file,
    Float32List samples,
    int start,
    int end,
  ) async {
    final int bytesPerSample = encoding.bytesPerSample;
    final int samplesPerChunk =
        (encodingBufferBytes ~/ (format.channels * bytesPerSample)) *
        format.channels;
    var index = start;
    while (index < end) {
      final int count = _minimum(samplesPerChunk, end - index);
      final ByteData bytes = ByteData(count * bytesPerSample);
      switch (encoding) {
        case WavSampleEncoding.pcm16:
          for (var local = 0; local < count; local += 1) {
            final double value = samples[index + local].clamp(-1.0, 1.0);
            final int scaled = value < 0
                ? (value * 32768).round()
                : (value * 32767).round();
            bytes.setInt16(local * 2, scaled, Endian.little);
          }
        case WavSampleEncoding.float32:
          for (var local = 0; local < count; local += 1) {
            bytes.setFloat32(local * 4, samples[index + local], Endian.little);
          }
      }
      await file.append(bytes.buffer.asUint8List());
      index += count;
    }
  }

  Future<_MutableSegment> _createNextSegment() async {
    final int index = _segments.length;
    final String fileName =
        '${_safeFileComponent(recordingId)}.${index.toString().padLeft(6, '0')}.wav';
    final SegmentedWavStorageFile file = await _storage.createFile(
      fileName,
      buildCanonicalWavHeader(
        format: format,
        encoding: encoding,
        dataLength: 0,
      ),
    );
    await file.flush();
    final _MutableSegment segment = _MutableSegment(
      segmentId: '$recordingId:segment:$index',
      fileName: fileName,
      startFrame: _totalFrameCount,
      file: file,
    );
    _segments.add(segment);
    _currentSegment = segment;
    await _persistManifest();
    return segment;
  }

  Future<void> _checkpointActiveAndPersist() async {
    final _MutableSegment? segment = _currentSegment;
    if (segment != null) {
      await segment.file.writeAt(
        0,
        buildCanonicalWavHeader(
          format: format,
          encoding: encoding,
          dataLength:
              segment.frameCount * format.channels * encoding.bytesPerSample,
        ),
      );
      await segment.file.flush();
    }
    await _persistManifest();
  }

  Future<void> _finalizeCurrentSegment() async {
    final _MutableSegment? segment = _currentSegment;
    if (segment == null) {
      return;
    }
    await segment.file.writeAt(
      0,
      buildCanonicalWavHeader(
        format: format,
        encoding: encoding,
        dataLength:
            segment.frameCount * format.channels * encoding.bytesPerSample,
      ),
    );
    await segment.file.flush();
    await segment.file.close();
    segment.finalized = true;
    _currentSegment = null;
    await _persistManifest();
  }

  Future<void> _persistManifest() async {
    final int nextRevision = _revision + 1;
    final SegmentedWavRecordingManifest snapshot = _snapshot(nextRevision);
    await _storage.writeFileAtomically(
      manifestFileName,
      Uint8List.fromList(utf8.encode(jsonEncode(snapshot.toJson()))),
    );
    _revision = nextRevision;
  }

  Future<void> _persistOrFail() async {
    try {
      await _persistManifest();
    } catch (error, stackTrace) {
      final AudioFailure failure = _recorderFailure(
        error,
        code: 'segmented_wav_manifest_write_failed',
        message: 'The segmented WAV sidecar could not be persisted.',
      );
      await _enterFailed(failure, stackTrace: stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _runExternalStorageOperation(
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      final AudioFailure failure = _recorderFailure(
        error,
        code: 'segmented_wav_io_failed',
        message: 'The segmented WAV writer could not persist audio.',
      );
      await _enterFailed(failure, stackTrace: stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _failForQueueOverflow(AudioFailure failure) async {
    _acceptingWrites = false;
    while (_queue.isNotEmpty) {
      final _PendingFrame pending = _queue.removeFirst();
      _queuedFrameCount -= pending.frame.frameCount;
      pending.completeError(failure, StackTrace.current);
    }
    _signalCapacity();
    final Future<void>? worker = _workerFuture;
    if (worker != null) {
      await worker;
    }
    if (_state != SegmentedWavRecordingState.failed) {
      await _enterFailed(failure);
    }
  }

  Future<void> _enterFailed(
    AudioFailure failure, {
    StackTrace? stackTrace,
  }) async {
    if (_state == SegmentedWavRecordingState.failed) {
      return;
    }
    _state = SegmentedWavRecordingState.failed;
    _failure = failure;
    _acceptingWrites = false;
    while (_queue.isNotEmpty) {
      final _PendingFrame pending = _queue.removeFirst();
      _queuedFrameCount -= pending.frame.frameCount;
      pending.completeError(failure, stackTrace ?? StackTrace.current);
    }
    _signalCapacity();
    final _MutableSegment? segment = _currentSegment;
    if (segment != null) {
      try {
        await segment.file.writeAt(
          0,
          buildCanonicalWavHeader(
            format: format,
            encoding: encoding,
            dataLength:
                segment.frameCount * format.channels * encoding.bytesPerSample,
          ),
        );
        await segment.file.flush();
      } catch (_) {
        // Recovery repairs the file if the failing storage cannot checkpoint.
      }
      try {
        await segment.file.close();
      } catch (_) {
        // Preserve the first stable recording failure.
      }
      _currentSegment = null;
    }
    try {
      await _persistManifest();
    } catch (_) {
      // A disk-wide failure can prevent the sidecar from reflecting the
      // in-memory failed state; recovery still uses the last durable revision.
    }
  }

  Future<void> _awaitDrain() async {
    while (_queue.isNotEmpty || _workerFuture != null) {
      _ensureWorker();
      final Future<void>? worker = _workerFuture;
      if (worker != null) {
        await worker;
      }
    }
  }

  void _signalCapacity() {
    final Completer<void>? capacity = _capacityChanged;
    _capacityChanged = null;
    if (capacity != null && !capacity.isCompleted) {
      capacity.complete();
    }
  }

  SegmentedWavRecordingManifest _snapshot(int revision) {
    return SegmentedWavRecordingManifest(
      recordingId: recordingId,
      sourceId: _initialSourceId,
      trackId: trackId,
      clockId: _initialClockId,
      format: format,
      encoding: encoding,
      segmentFrameCount: segmentFrameCount,
      queueCapacityFrames: queueCapacityFrames,
      queuePolicy: queuePolicy,
      gapPolicy: gapPolicy,
      state: _state,
      revision: revision,
      totalFrameCount: _totalFrameCount,
      droppedFrameCount: _droppedFrameCount,
      segments: <SegmentedWavSegmentManifest>[
        for (final _MutableSegment segment in _segments)
          SegmentedWavSegmentManifest(
            segmentId: segment.segmentId,
            fileName: segment.fileName,
            startFrame: segment.startFrame,
            frameCount: segment.frameCount,
            finalized: segment.finalized,
          ),
      ],
      markers: _markers,
      failureCode: _failure?.code,
      failureMessage: _failure?.message,
    );
  }

  void _throwIfFailed() {
    final AudioFailure? failure = _failure;
    if (failure != null) {
      throw failure;
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('The segmented WAV recorder is closed.');
    }
  }
}

final class _MutableSegment {
  _MutableSegment({
    required this.segmentId,
    required this.fileName,
    required this.startFrame,
    required this.file,
  });

  final String segmentId;
  final String fileName;
  final int startFrame;
  final SegmentedWavStorageFile file;
  int frameCount = 0;
  bool finalized = false;
}

final class _PendingFrame {
  _PendingFrame(this.frame);

  final AudioFrame frame;
  final Completer<SegmentedWavWriteResult> _completer =
      Completer<SegmentedWavWriteResult>();

  Future<SegmentedWavWriteResult> get future => _completer.future;

  void complete(SegmentedWavWriteResult result) {
    if (!_completer.isCompleted) {
      _completer.complete(result);
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

AudioFailure _recorderFailure(
  Object error, {
  required String code,
  required String message,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.encoding,
        message: message,
        safeCause: error.runtimeType.toString(),
      );

String _safeFileComponent(String value) {
  final String safe = value.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
  return safe.isEmpty ? 'recording' : safe;
}

void _requireRecorderIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

void _requirePlainFileName(String value, String name) {
  if (value.trim().isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\')) {
    throw ArgumentError.value(value, name, 'Must be a plain file name.');
  }
}

int _minimum(int left, int right) => left < right ? left : right;
