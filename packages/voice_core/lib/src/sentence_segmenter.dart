/// Stateful sentence splitter for arbitrarily chunked streaming text.
final class IncrementalSentenceSegmenter {
  /// Creates a segmenter with a bounded fallback sentence size.
  IncrementalSentenceSegmenter({
    this.maximumCharacters = 240,
    Set<String>? abbreviations,
  }) : abbreviations = Set<String>.unmodifiable(
         abbreviations ?? _defaultAbbreviations,
       ) {
    if (maximumCharacters < 16) {
      throw ArgumentError.value(
        maximumCharacters,
        'maximumCharacters',
        'Must be at least 16.',
      );
    }
  }

  static const Set<String> _defaultAbbreviations = <String>{
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'st',
    'vs',
    'etc',
    'e.g',
    'i.e',
  };

  /// Maximum buffered length before splitting at a word boundary.
  final int maximumCharacters;

  /// Lowercase abbreviations that do not end a sentence.
  final Set<String> abbreviations;

  String _pending = '';

  /// Text not yet emitted as a sentence.
  String get pending => _pending;

  /// Adds a fragment and returns every newly completed sentence.
  List<String> add(String fragment) {
    if (fragment.isEmpty) {
      return const <String>[];
    }
    _pending += fragment;
    return _extract(flush: false);
  }

  /// Emits any remaining text and clears the segmenter.
  List<String> flush() => _extract(flush: true);

  /// Discards buffered text.
  void reset() {
    _pending = '';
  }

  List<String> _extract({required bool flush}) {
    final sentences = <String>[];
    while (_pending.isNotEmpty) {
      final boundary = _sentenceBoundary();
      if (boundary != null) {
        _emit(boundary, sentences);
        continue;
      }

      final forcedBoundary = _forcedBoundary();
      if (forcedBoundary != null) {
        _emit(forcedBoundary, sentences);
        continue;
      }
      break;
    }

    if (flush) {
      final remaining = _pending.trim();
      _pending = '';
      if (remaining.isNotEmpty) {
        sentences.add(remaining);
      }
    }
    return List<String>.unmodifiable(sentences);
  }

  int? _sentenceBoundary() {
    for (var index = 0; index < _pending.length; index++) {
      final character = _pending[index];
      if (character == '\n') {
        return index + 1;
      }
      if (character != '.' && character != '?' && character != '!') {
        continue;
      }
      if (character == '.' && _periodContinuesToken(index)) {
        continue;
      }

      var end = index + 1;
      while (end < _pending.length &&
          (_pending[end] == '.' ||
              _pending[end] == '?' ||
              _pending[end] == '!')) {
        end++;
      }
      while (end < _pending.length && _isClosingCharacter(_pending[end])) {
        end++;
      }
      if (end == _pending.length || _isWhitespace(_pending[end])) {
        return end;
      }
    }
    return null;
  }

  bool _periodContinuesToken(int index) {
    if (index > 0 &&
        index + 1 < _pending.length &&
        _isDigit(_pending[index - 1]) &&
        _isDigit(_pending[index + 1])) {
      return true;
    }
    if (index + 1 < _pending.length && _pending[index + 1] == '.') {
      return true;
    }

    var start = index - 1;
    while (start >= 0 && _isTokenCharacter(_pending[start])) {
      start--;
    }
    final token = _pending.substring(start + 1, index).toLowerCase();
    if (abbreviations.contains(token)) {
      return true;
    }
    return token.length == 1 &&
        token.codeUnitAt(0) >= 97 &&
        token.codeUnitAt(0) <= 122;
  }

  int? _forcedBoundary() {
    if (_pending.length <= maximumCharacters) {
      return null;
    }
    final whitespace = _pending.lastIndexOf(' ', maximumCharacters);
    if (whitespace > 0) {
      return whitespace + 1;
    }
    return maximumCharacters;
  }

  void _emit(int boundary, List<String> output) {
    final sentence = _pending.substring(0, boundary).trim();
    _pending = _pending.substring(boundary);
    _pending = _pending.replaceFirst(RegExp(r'^\s+'), '');
    if (sentence.isNotEmpty) {
      output.add(sentence);
    }
  }

  static bool _isClosingCharacter(String character) =>
      character == '"' ||
      character == "'" ||
      character == ')' ||
      character == ']' ||
      character == '}';

  static bool _isWhitespace(String character) =>
      character == ' ' ||
      character == '\n' ||
      character == '\r' ||
      character == '\t';

  static bool _isDigit(String character) {
    final unit = character.codeUnitAt(0);
    return unit >= 48 && unit <= 57;
  }

  static bool _isTokenCharacter(String character) {
    final unit = character.codeUnitAt(0);
    return (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        character == '.';
  }
}
