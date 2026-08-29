/// Canonical deep-link contract shared by notification and widget entrypoints.
class NotificationRouteContract {
  const NotificationRouteContract._();

  static const scheme = 'planflow';

  static Uri schedule(String id) => Uri(
        scheme: scheme,
        host: 'schedule',
        path: '/$id',
      );

  static Uri day(DateTime date) => Uri(
        scheme: scheme,
        host: 'day',
        path: '/${_date(date)}',
      );

  static String? canonicalPath(Uri uri) {
    if (uri.scheme != scheme) return null;
    final path = uri.path;
    final scheduleMatch = uri.host == 'schedule'
        ? RegExp(r'^/([^/]+)$').firstMatch(path)
        : RegExp(r'^/schedule/([^/]+)$').firstMatch(path);
    if (scheduleMatch != null) {
      return '/event/detail/${Uri.decodeComponent(scheduleMatch.group(1)!)}';
    }
    final dayMatch = uri.host == 'day'
        ? RegExp(r'^/(\d{4}-\d{2}-\d{2})$').firstMatch(path)
        : RegExp(r'^/day/(\d{4}-\d{2}-\d{2})$').firstMatch(path);
    if (dayMatch != null && _isDate(dayMatch.group(1)!)) {
      return '/calendar?date=${dayMatch.group(1)}';
    }
    return null;
  }

  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static bool _isDate(String value) {
    final date = DateTime.tryParse(value);
    return date != null && _date(date) == value;
  }
}
