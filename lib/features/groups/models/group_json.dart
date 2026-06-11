String stringValue(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) {
    return '';
  }
  return text;
}

String requiredStringValue(Object? value, String fieldName) {
  final text = stringValue(value);
  if (text.isEmpty) {
    throw StateError('Missing required field: $fieldName');
  }
  return text;
}

String? optionalStringValue(Object? value) {
  final text = stringValue(value);
  return text.isEmpty ? null : text;
}

DateTime? dateTimeValue(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value;
  }
  return DateTime.tryParse(value.toString());
}

DateTime requiredDateTimeValue(Object? value, String fieldName) {
  final parsedValue = dateTimeValue(value);
  if (parsedValue == null) {
    throw StateError('Missing required date field: $fieldName');
  }
  return parsedValue;
}

String? utcIsoValue(DateTime? value) {
  return value?.toUtc().toIso8601String();
}
