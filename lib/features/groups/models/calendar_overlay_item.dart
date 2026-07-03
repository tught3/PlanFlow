import '../../../core/local_time.dart';
import '../../../data/models/event_model.dart';
import '../models/group_event_model.dart';

enum CalendarOverlayItemType {
  personal,
  group,
}

class CalendarOverlayItem {
  const CalendarOverlayItem({
    required this.id,
    required this.type,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.source,
    this.groupId,
    this.groupName,
    this.location,
    this.allDay = false,
    this.status = 'active',
  });

  factory CalendarOverlayItem.fromPersonalEvent(EventModel event) {
    return CalendarOverlayItem(
      id: event.id,
      type: CalendarOverlayItemType.personal,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      source: event.source,
      location: event.location,
      allDay: event.isAllDay,
      status: event.isCritical ? 'critical' : 'active',
    );
  }

  factory CalendarOverlayItem.fromGroupEvent(
    GroupEventModel event, {
    String? groupName,
  }) {
    return CalendarOverlayItem(
      id: event.id,
      type: CalendarOverlayItemType.group,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      source: 'group',
      groupId: event.groupId,
      groupName: groupName,
      location: event.location,
      allDay: event.allDay,
      status: event.status,
    );
  }

  final String id;
  final CalendarOverlayItemType type;
  final String title;
  final DateTime? startAt;
  final DateTime? endAt;
  final String source;
  final String? groupId;
  final String? groupName;
  final String? location;
  final bool allDay;
  final String status;

  bool get isGroup => type == CalendarOverlayItemType.group;

  bool get isPersonal => type == CalendarOverlayItemType.personal;

  bool get isActive => status == 'active';

  bool get isMultiDay {
    final start = startAt;
    final end = endAt;
    if (start == null || end == null) {
      return false;
    }
    return planflowLocalDay(start) != planflowLocalDay(end);
  }

  DateTime get localStart =>
      startAt == null ? DateTime(0) : planflowLocalDay(startAt!);

  DateTime get localEnd =>
      endAt == null ? localStart : planflowLocalDay(endAt!);

  bool spansLocalDay(DateTime day) {
    final start = startAt;
    if (start == null) {
      return false;
    }
    return planflowEventIntersectsLocalDay(
      startAt: start,
      endAt: endAt,
      day: day,
    );
  }

  bool startsOnDay(DateTime day) {
    final start = startAt;
    if (start == null) {
      return false;
    }
    final current = DateTime(day.year, day.month, day.day);
    return current == localStart;
  }

  bool endsOnDay(DateTime day) {
    final end = endAt;
    if (end == null) {
      return false;
    }
    final current = DateTime(day.year, day.month, day.day);
    return current == _displayEndDay(startAt ?? end, end);
  }

  static DateTime _displayEndDay(DateTime startAt, DateTime endAt) {
    var localEnd = planflowLocal(endAt);
    if (endAt.isAfter(startAt) &&
        localEnd.hour == 0 &&
        localEnd.minute == 0 &&
        localEnd.second == 0 &&
        localEnd.millisecond == 0 &&
        localEnd.microsecond == 0) {
      localEnd = localEnd.subtract(const Duration(microseconds: 1));
    }
    return DateTime(localEnd.year, localEnd.month, localEnd.day);
  }
}
