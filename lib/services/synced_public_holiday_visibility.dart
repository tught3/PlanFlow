import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'korean_holidays.dart';

/// Returns true when [event] is the provider copy of a holiday that PlanFlow
/// already renders from its canonical holiday table.
///
/// Manual events are deliberately retained: both external identifiers must
/// be present, and the title must exactly match the canonical holiday name for
/// the event's local start date.
bool isSyncedPublicHolidayDuplicate(EventModel event) {
  final externalId = event.externalId?.trim() ?? '';
  final externalCalendarId = event.externalCalendarId?.trim() ?? '';
  if (externalId.isEmpty ||
      externalCalendarId.isEmpty ||
      event.startAt == null) {
    return false;
  }
  final day = planflowLocalDay(event.startAt!);
  final canonicalName = KoreanHolidays.holidayName(day);
  if (canonicalName == null || canonicalName.trim().isEmpty) {
    return false;
  }
  return _normalize(event.title) == _normalize(canonicalName);
}

String _normalize(String value) => value.replaceAll(RegExp(r'\s+'), '').trim();

List<EventModel> omitSyncedPublicHolidayDuplicates(
    Iterable<EventModel> events) {
  return events
      .where((event) => !isSyncedPublicHolidayDuplicate(event))
      .toList(growable: false);
}
