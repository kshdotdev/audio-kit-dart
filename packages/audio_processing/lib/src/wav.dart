import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';

/// PCM representation stored in a WAV data chunk.
enum WavSampleEncoding {
  /// Signed little-endian 16-bit integer PCM.
  pcm16(bitsPerSample: 16, formatCode: 1),

  /// Little-endian IEEE 754 32-bit float PCM.
  float32(bitsPerSample: 32, formatCode: 3);

  const WavSampleEncoding({
    required this.bitsPerSample,
    required this.formatCode,
  });

  /// Stored bits per channel sample.
  final int bitsPerSample;

  /// Microsoft WAVE format code.
  final int formatCode;

  /// Stored bytes per channel sample.
  int get bytesPerSample => bitsPerSample ~/ 8;
}

/// How an encoder handles explicit or inferred timeline gaps.
enum WavGapPolicy {
  /// Reject the frame so a supposedly lossless recording cannot hide a gap.
  reject,

  /// Insert zero-valued sample frames to preserve the source timeline.
  insertSilence,
}

/// In-memory streaming WAV encoder for one fixed-format audio track.
final class WavEncoder {
  /// Creates an encoder.
  WavEncoder({
    required this.format,
    this.encoding = WavSampleEncoding.pcm16,
    this.gapPolicy = WavGapPolicy.reject,
  });

  /// Input PCM format.
  final AudioFormat format;

  /// Stored sample encoding.
  final WavSampleEncoding encoding;

  /// Timeline-gap behavior.
  final WavGapPolicy gapPolicy;

  final BytesBuilder _audioBytes = BytesBuilder(copy: false);
  AudioStreamKey? _stream;
  int? _expectedSampleOffset;
  Uint8List? _finishedBytes;
  int _encodedDataLength = 0;

  /// Number of encoded audio-data bytes, excluding the WAV header.
  int get dataLength => _encodedDataLength;

  /// Adds one contiguous frame.
  void addFrame(AudioFrame frame) {
    if (_finishedBytes != null) {
      throw StateError('Cannot add frames after WAV finalization.');
    }
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Frame format must match encoder format $format.',
      );
    }
    final key = AudioStreamKey.fromFrame(frame);
    final currentStream = _stream;
    if (currentStream != null && currentStream != key) {
      throw ArgumentError.value(
        key,
        'frame',
        'A WavEncoder accepts exactly one logical stream.',
      );
    }
    _stream ??= key;

    final expectedOffset = _expectedSampleOffset;
    final explicitGap = frame.discontinuity?.droppedSampleFrameCount ?? 0;
    if (expectedOffset == null) {
      if (frame.discontinuity != null) {
        _handleGap(explicitGap);
      }
    } else {
      final offsetGap = frame.sampleOffset - expectedOffset;
      if (offsetGap < 0) {
        throw StateError('Overlapping or out-of-order WAV frame offsets.');
      }
      final gapFrames = offsetGap > explicitGap ? offsetGap : explicitGap;
      if (gapFrames > 0) {
        _handleGap(gapFrames);
      } else if (frame.discontinuity != null) {
        _handleGap(0);
      }
    }

    _encodeSamples(frame.samples);
    _expectedSampleOffset = frame.endSampleOffset;
  }

  /// Finalizes a complete little-endian RIFF/WAVE file.
  ///
  /// Repeated calls return independent copies of the same bytes.
  Uint8List finish() {
    _finishedBytes ??= _buildFile(_audioBytes.takeBytes());
    return Uint8List.fromList(_finishedBytes!);
  }

  void _handleGap(int sampleFrames) {
    if (gapPolicy == WavGapPolicy.reject) {
      throw StateError('Cannot encode a discontinuous stream as lossless WAV.');
    }
    if (sampleFrames == 0) {
      return;
    }
    _encodeSamples(Float32List(sampleFrames * format.channels));
  }

  void _encodeSamples(Float32List samples) {
    final bytes = ByteData(samples.length * encoding.bytesPerSample);
    switch (encoding) {
      case WavSampleEncoding.pcm16:
        for (var index = 0; index < samples.length; index += 1) {
          final value = samples[index].clamp(-1.0, 1.0);
          final scaled = value < 0
              ? (value * 32768).round()
              : (value * 32767).round();
          bytes.setInt16(index * 2, scaled, Endian.little);
        }
      case WavSampleEncoding.float32:
        for (var index = 0; index < samples.length; index += 1) {
          bytes.setFloat32(index * 4, samples[index], Endian.little);
        }
    }
    _audioBytes.add(bytes.buffer.asUint8List());
    _encodedDataLength += bytes.lengthInBytes;
  }

  Uint8List _buildFile(Uint8List audioData) {
    if (audioData.length > 0xffffffff - 36) {
      throw StateError('WAV data exceeds the RIFF 32-bit size limit.');
    }
    final header = ByteData(44);
    _writeAscii(header, 0, 'RIFF');
    header.setUint32(4, 36 + audioData.length, Endian.little);
    _writeAscii(header, 8, 'WAVE');
    _writeAscii(header, 12, 'fmt ');
    header
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, encoding.formatCode, Endian.little)
      ..setUint16(22, format.channels, Endian.little)
      ..setUint32(24, format.sampleRate, Endian.little)
      ..setUint32(
        28,
        format.sampleRate * format.channels * encoding.bytesPerSample,
        Endian.little,
      )
      ..setUint16(32, format.channels * encoding.bytesPerSample, Endian.little)
      ..setUint16(34, encoding.bitsPerSample, Endian.little);
    _writeAscii(header, 36, 'data');
    header.setUint32(40, audioData.length, Endian.little);
    final file = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(audioData);
    return file.takeBytes();
  }
}

/// Independent per-track collection of [WavEncoder] instances.
final class MultiTrackWavEncoder {
  /// Creates a multi-track encoder factory.
  MultiTrackWavEncoder({
    this.encoding = WavSampleEncoding.pcm16,
    this.gapPolicy = WavGapPolicy.reject,
  });

  /// Stored sample encoding for every track.
  final WavSampleEncoding encoding;

  /// Gap policy for every track.
  final WavGapPolicy gapPolicy;

  final Map<AudioStreamKey, WavEncoder> _encoders =
      <AudioStreamKey, WavEncoder>{};

  /// Active stream keys.
  Iterable<AudioStreamKey> get streams =>
      List<AudioStreamKey>.unmodifiable(_encoders.keys);

  /// Routes [frame] to its independent track encoder.
  void addFrame(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    final encoder = _encoders.putIfAbsent(
      key,
      () => WavEncoder(
        format: frame.format,
        encoding: encoding,
        gapPolicy: gapPolicy,
      ),
    );
    encoder.addFrame(frame);
  }

  /// Finalizes and removes [stream].
  Uint8List finishTrack(AudioStreamKey stream) {
    final encoder = _encoders.remove(stream);
    if (encoder == null) {
      throw StateError('No WAV encoder exists for $stream.');
    }
    return encoder.finish();
  }

  /// Finalizes and removes every track.
  Map<AudioStreamKey, Uint8List> finishAll() {
    final files = <AudioStreamKey, Uint8List>{
      for (final entry in _encoders.entries) entry.key: entry.value.finish(),
    };
    _encoders.clear();
    return Map<AudioStreamKey, Uint8List>.unmodifiable(files);
  }
}

/// Parsed metadata from a canonical PCM WAV header.
final class WavFileInfo {
  /// Creates parsed WAV metadata.
  const WavFileInfo({
    required this.formatCode,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.dataLength,
  });

  /// WAVE format code.
  final int formatCode;

  /// Stored channel count.
  final int channels;

  /// Stored sample frames per second.
  final int sampleRate;

  /// Stored bits per channel sample.
  final int bitsPerSample;

  /// Audio data length in bytes.
  final int dataLength;

  /// Number of stored interleaved sample frames.
  int get sampleFrameCount => dataLength ~/ (channels * (bitsPerSample ~/ 8));
}

/// Parses metadata from a canonical 44-byte PCM WAV header.
WavFileInfo inspectWav(Uint8List bytes) {
  if (bytes.length < 44) {
    throw const FormatException('WAV file is shorter than its header.');
  }
  final data = ByteData.sublistView(bytes);
  if (_readAscii(data, 0, 4) != 'RIFF' ||
      _readAscii(data, 8, 4) != 'WAVE' ||
      _readAscii(data, 12, 4) != 'fmt ' ||
      _readAscii(data, 36, 4) != 'data') {
    throw const FormatException('Unsupported or invalid canonical WAV header.');
  }
  final dataLength = data.getUint32(40, Endian.little);
  if (44 + dataLength > bytes.length) {
    throw const FormatException('WAV data chunk is truncated.');
  }
  return WavFileInfo(
    formatCode: data.getUint16(20, Endian.little),
    channels: data.getUint16(22, Endian.little),
    sampleRate: data.getUint32(24, Endian.little),
    bitsPerSample: data.getUint16(34, Endian.little),
    dataLength: dataLength,
  );
}

void _writeAscii(ByteData data, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    data.setUint8(offset + index, value.codeUnitAt(index));
  }
}

String _readAscii(ByteData data, int offset, int length) =>
    String.fromCharCodes(
      List<int>.generate(length, (index) => data.getUint8(offset + index)),
    );
