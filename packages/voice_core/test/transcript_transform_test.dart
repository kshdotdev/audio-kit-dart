import 'package:test/test.dart';
import 'package:voice_core/voice_core.dart';

void main() {
  test('filler transform escapes phrases and normalizes whitespace', () {
    final transform = FillerWordTranscriptTransform(
      fillerWords: const ['um', 'you know', 'c++'],
    );

    expect(
      transform.transform('Um, you know   use c++ please'),
      ', use please',
    );
  });

  test('composite transform preserves declaration order', () async {
    final transform = CompositeTranscriptTransform([
      const _AppendTransform(' one'),
      const _AppendTransform(' two'),
    ]);

    expect(await transform.transform('zero'), 'zero one two');
  });
}

final class _AppendTransform implements VoiceTranscriptTransform {
  const _AppendTransform(this.suffix);

  final String suffix;

  @override
  String transform(String transcript) => '$transcript$suffix';
}
