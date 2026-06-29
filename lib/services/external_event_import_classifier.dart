class ExternalEventImportClassifier {
  const ExternalEventImportClassifier._();

  static bool isCritical({
    String? title,
    String? description,
    String? location,
    String? calendarName,
    String? calendarPath,
    String? source,
    int? priority,
    Iterable<String> categories = const <String>[],
    String? status,
  }) {
    if (priority != null && priority > 0 && priority <= 3) {
      return true;
    }

    final normalizedCategories = categories
        .map(_normalize)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (normalizedCategories.any(_isCriticalBucket)) {
      return true;
    }

    final calendarText = _normalize(
      <String?>[calendarName, calendarPath, source]
          .whereType<String>()
          .join(' '),
    );
    if (_isCriticalBucket(calendarText)) {
      return true;
    }

    final eventText = _normalize(
      <String?>[title, description, location].whereType<String>().join(' '),
    );
    if (eventText.contains('네이버예약') || eventText.contains('naverbooking')) {
      return true;
    }

    final normalizedStatus = _normalize(status);
    if (normalizedStatus == 'confirmed' &&
        (calendarText.contains('예약') || calendarText.contains('booking'))) {
      return true;
    }

    return false;
  }

  static bool _isCriticalBucket(String value) {
    if (value.isEmpty) {
      return false;
    }
    return value.contains('중요') ||
        value.contains('긴급') ||
        value.contains('important') ||
        value.contains('critical') ||
        value.contains('urgent') ||
        value.contains('네이버예약') ||
        value.contains('naverbooking') ||
        value.contains('bookingcalendar');
  }

  static String _normalize(String? value) {
    return (value ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('_', '')
        .replaceAll('-', '')
        .trim();
  }
}
