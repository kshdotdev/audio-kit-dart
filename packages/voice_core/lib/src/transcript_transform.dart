import 'dart:async';

/// Optional asynchronous transformation applied to committed transcripts.
abstract interface class VoiceTranscriptTransform {
  /// Returns text sent to the backend. Empty output suppresses the turn.
  FutureOr<String> transform(String transcript);
}

/// Leaves committed transcripts unchanged.
final class IdentityTranscriptTransform implements VoiceTranscriptTransform {
  const IdentityTranscriptTransform();

  @override
  String transform(String transcript) => transcript;
}

/// Runs transcript transforms in declaration order.
final class CompositeTranscriptTransform implements VoiceTranscriptTransform {
  CompositeTranscriptTransform(Iterable<VoiceTranscriptTransform> transforms)
    : transforms = List<VoiceTranscriptTransform>.unmodifiable(transforms);

  /// Ordered transforms.
  final List<VoiceTranscriptTransform> transforms;

  @override
  Future<String> transform(String transcript) async {
    var result = transcript;
    for (final transform in transforms) {
      result = await transform.transform(result);
    }
    return result;
  }
}

/// Removes configured filler phrases and normalizes whitespace.
final class FillerWordTranscriptTransform implements VoiceTranscriptTransform {
  FillerWordTranscriptTransform({
    Iterable<String> fillerWords = const <String>['um', 'uh', 'you know'],
  }) : _pattern = _buildPattern(fillerWords);

  final RegExp? _pattern;

  @override
  String transform(String transcript) {
    final pattern = _pattern;
    final withoutFillers = pattern == null
        ? transcript
        : transcript.replaceAll(pattern, '');
    return withoutFillers.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static RegExp? _buildPattern(Iterable<String> fillers) {
    final escaped = fillers
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty)
        .map(RegExp.escape)
        .toList(growable: false);
    if (escaped.isEmpty) {
      return null;
    }
    return RegExp(
      '(?<![\\p{L}\\p{N}_])(?:${escaped.join('|')})(?![\\p{L}\\p{N}_])',
      caseSensitive: false,
      unicode: true,
    );
  }
}
