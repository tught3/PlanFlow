import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'korean_holidays.dart';

/// Returns true when [event] is the provider copy of a holiday that PlanFlow
/// already renders from its canonical holiday table.
///
/// Manual events are deliberately retained: at least one external provider
/// identifier must be present, and the title must match either the canonical
/// holiday name or a generic public-holiday label for the event's local start
/// date. The latter is emitted by some provider holiday calendars (for
/// example, a Chuseok row titled only "공휴일").
bool isSyncedPublicHolidayDuplicate(EventModel event) {
  final externalId = event.externalId?.trim() ?? '';
  final externalCalendarId = event.externalCalendarId?.trim() ?? '';
  if ((externalId.isEmpty && externalCalendarId.isEmpty) ||
      event.startAt == null) {
    return false;
  }
  final day = planflowLocalDay(event.startAt!);
  final canonicalName = KoreanHolidays.holidayName(day);
  if (canonicalName == null || canonicalName.trim().isEmpty) {
    return false;
  }
  final title = _normalize(event.title);
  final canonical = _normalize(canonicalName);
  return title == canonical || _genericHolidayTitles.contains(title);
}

String _normalize(String value) => value.replaceAll(RegExp(r'\s+'), '').trim();

const Set<String> _genericHolidayTitles = <String>{
  '공휴일',
  '휴일',
  '법정공휴일',
};

List<EventModel> omitSyncedPublicHolidayDuplicates(
    Iterable<EventModel> events) {
  return events
      .where((event) => !isSyncedPublicHolidayDuplicate(event))
      .toList(growable: false);
}
