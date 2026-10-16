import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'korean_holidays.dart';
import 'calendar_platform.dart';

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
  final aliases = KoreanHolidays.holidayTitleAliases(day);
  if (aliases.isEmpty) {
    return false;
  }
  final rawTitle = _normalize(event.title);
  if (!isNativeIOS) {
    // Non-iOS (Android) keeps the f26 baseline: the raw normalized title is
    // compared unchanged, with no all-day gate and no "종일 " prefix removal.
    // A canonical title or generic holiday label with a "종일 " prefix does
    // not match on Android, so prefixed provider rows ("종일 신정",
    // "종일 공휴일") fall through and stay visible.
    return aliases.map(_normalize).contains(rawTitle) ||
        _genericHolidayTitles.contains(rawTitle);
  }
  if (!event.isAllDay) return false;
  final hasAllDayPrefix = rawTitle.startsWith('종일');
  final title = hasAllDayPrefix ? rawTitle.substring('종일'.length) : rawTitle;
  return aliases.map(_normalize).contains(title) ||
      (!hasAllDayPrefix && _genericHolidayTitles.contains(title));
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
