void requireProbability(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, name, 'Must be between 0 and 1.');
  }
}

void requireNonNegativeDuration(Duration value, String name) {
  if (value.isNegative) {
    throw ArgumentError.value(value, name, 'Must not be negative.');
  }
}

void requirePositiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'Must be positive.');
  }
}

void requireNonEmpty(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

void requireOptionalNonEmpty(String? value, String name) {
  if (value != null) {
    requireNonEmpty(value, name);
  }
}

void requireStableIdentifier(String value, String name) {
  requireNonEmpty(value, name);
  if (!RegExp(r'^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      name,
      'Must be a stable identifier containing letters, digits, ".", "_", '
      'or "-".',
    );
  }
}

void validateSpeakerBounds({
  required int? minimumSpeakers,
  required int? maximumSpeakers,
}) {
  if (minimumSpeakers != null && minimumSpeakers <= 0) {
    throw ArgumentError.value(
      minimumSpeakers,
      'minimumSpeakers',
      'Must be positive.',
    );
  }
  if (maximumSpeakers != null && maximumSpeakers <= 0) {
    throw ArgumentError.value(
      maximumSpeakers,
      'maximumSpeakers',
      'Must be positive.',
    );
  }
  if (minimumSpeakers != null &&
      maximumSpeakers != null &&
      minimumSpeakers > maximumSpeakers) {
    throw ArgumentError('minimumSpeakers must not exceed maximumSpeakers.');
  }
}
