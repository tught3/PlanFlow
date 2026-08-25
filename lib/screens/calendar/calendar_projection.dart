import '../../data/models/event_model.dart';
import '../../services/synced_public_holiday_visibility.dart';
import '../../core/local_time.dart';

/// Canonical ordering for every calendar projection, including the Android
/// widget payload. Same-time events use semantic priority before title so the
/// important/team/recurring ordering is deterministic across renderers.
int compareCalendarEventsForDisplay(EventModel a, EventModel b) {
  final aStart = a.startAt;
  final bStart = b.startAt;
  if (aStart == null && bStart == null) {
    return _compareEventSemanticsThenTitle(a, b);
  }
  if (aStart == null) return 1;
  if (bStart == null) return -1;
  final byTime = aStart.compareTo(bStart);
  return byTime == 0 ? _compareEventSemanticsThenTitle(a, b) : byTime;
}

int _compareEventSemanticsThenTitle(EventModel a, EventModel b) {
  int rank(EventModel event) {
    if (event.isCritical) return 0;
    if (event.groupEventId?.trim().isNotEmpty == true) return 1;
    if (event.recurrenceRule?.trim().isNotEmpty == true ||
        event.parentEventId != null) {
      return 2;
    }
    return 3;
  }

  final bySemanticRank = rank(a).compareTo(rank(b));
  if (bySemanticRank != 0) return bySemanticRank;
  final byTitle = a.title.compareTo(b.title);
  return byTitle == 0 ? a.id.compareTo(b.id) : byTitle;
}

/// Builds a day index once for a projected month.  Date taps must not scan the
/// complete event list (which is especially costly after recurrence expansion).
Map<int, List<EventModel>> buildCalendarDayEventIndex({
  required Iterable<EventModel> events,
  required DateTime focusedMonth,
}) {
  final monthStart = DateTime(focusedMonth.year, focusedMonth.month);
  final monthEnd = DateTime(focusedMonth.year, focusedMonth.month + 1);
  final index = <int, List<EventModel>>{};
  for (final event in events) {
    if (isSyncedPublicHolidayDuplicate(event) || event.startAt == null) {
      continue;
    }
    final start = planflowLocal(event.startAt!);
    var end = planflowLocal(event.endAt ?? event.startAt!);
    if (event.endAt != null &&
        event.endAt!.isAfter(event.startAt!) &&
        end.hour == 0 &&
        end.minute == 0 &&
        end.second == 0 &&
        end.millisecond == 0 &&
        end.microsecond == 0) {
      end = end.subtract(const Duration(microseconds: 1));
    }
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    if (last.isBefore(monthStart) || !first.isBefore(monthEnd)) continue;
    var day = first.isBefore(monthStart) ? monthStart : first;
    final finalDay = last.isAfter(monthEnd.subtract(const Duration(days: 1)))
        ? monthEnd.subtract(const Duration(days: 1))
        : last;
    while (!day.isAfter(finalDay)) {
      (index[day.day] ??= <EventModel>[]).add(event);
      day = day.add(const Duration(days: 1));
    }
  }
  for (final eventsForDay in index.values) {
    eventsForDay.sort(compareCalendarEventsForDisplay);
  }
  return index.map((key, value) => MapEntry(key, List.unmodifiable(value)));
}
