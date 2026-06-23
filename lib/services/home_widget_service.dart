import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'home_widget_platform.dart';
import 'travel_time_buffer_service.dart';

class HomeWidgetNextEventData {
  const HomeWidgetNextEventData({
    required this.title,
    this.eventId,
    this.startAt,
    this.location,
    this.travelBufferMinutes,
    this.isCritical = false,
  });

  final String title;
  final String? eventId;
  final DateTime? startAt;
  final String? location;
  final int? travelBufferMinutes;
  final bool isCritical;
}

class HomeWidgetListEventData {
  const HomeWidgetListEventData({
    required this.title,
    this.eventId,
    this.startAt,
    this.location,
    this.isCritical = false,
    this.monthSegment,
    this.showTitleInMonth = true,
  });

  final String title;
  final String? eventId;
  final DateTime? startAt;
  final String? location;
  final bool isCritical;

  /// 월간 달력 셀 segment 타입: 'single' | 'start' | 'middle' | 'end'
  final String? monthSegment;

  /// 월간 달력에서 제목 표시 여부 (start/single=true, middle/end=false)
  final bool showTitleInMonth;
}

class HomeWidgetMonthDayData {
  const HomeWidgetMonthDayData({
    required this.day,
    required this.summary,
    this.eventCount,
    this.hasCritical = false,
  });

  final int day;
  final String summary;
  final int? eventCount;
  final bool hasCritical;
}

class HomeWidgetWeekDayData {
  const HomeWidgetWeekDayData({
    required this.date,
    this.summary,
    this.events = const <HomeWidgetListEventData>[],
    this.eventCount,
    this.overflowPreviewTitle,
    this.hasCritical = false,
  });

  final DateTime date;
  final String? summary;
  final List<HomeWidgetListEventData> events;
  final int? eventCount;
  final String? overflowPreviewTitle;
  final bool hasCritical;
}

class HomeWidgetMonthCellData {
  const HomeWidgetMonthCellData({
    required this.cellIndex,
    this.date,
    this.day,
    this.inMonth = false,
    this.events = const <HomeWidgetListEventData>[],
    this.overflowCount = 0,
    this.overflowPreviewTitle,
  });

  final int cellIndex;
  final DateTime? date;
  final int? day;
  final bool inMonth;
  final List<HomeWidgetListEventData> events;
  final int overflowCount;
  final String? overflowPreviewTitle;
}

class HomeWidgetSchedulePayload {
  const HomeWidgetSchedulePayload({
    required this.nextEvent,
    required this.month,
    this.rawEvents = const <Map<String, Object?>>[],
    this.lastPastEvent,
    this.todayUpcomingEvents = const <HomeWidgetListEventData>[],
    this.tomorrowEvents = const <HomeWidgetListEventData>[],
    this.yesterdayEvents = const <HomeWidgetListEventData>[],
    this.monthDays = const <HomeWidgetMonthDayData>[],
    this.monthCells = const <HomeWidgetMonthCellData>[],
    this.previousMonthCells = const <HomeWidgetMonthCellData>[],
    this.nextMonthCells = const <HomeWidgetMonthCellData>[],
    this.weekDays = const <HomeWidgetWeekDayData>[],
    this.previousWeekDays = const <HomeWidgetWeekDayData>[],
    this.nextWeekDays = const <HomeWidgetWeekDayData>[],
  });

  final HomeWidgetNextEventData nextEvent;
  final DateTime month;
  final List<Map<String, Object?>> rawEvents;
  final HomeWidgetListEventData? lastPastEvent;
  final List<HomeWidgetListEventData> todayUpcomingEvents;
  final List<HomeWidgetListEventData> tomorrowEvents;

  /// 어제 일정 (day_offset_-1)
  final List<HomeWidgetListEventData> yesterdayEvents;
  final List<HomeWidgetMonthDayData> monthDays;
  final List<HomeWidgetMonthCellData> monthCells;
  final List<HomeWidgetMonthCellData> previousMonthCells;
  final List<HomeWidgetMonthCellData> nextMonthCells;

  /// 이번 주 일정
  final List<HomeWidgetWeekDayData> weekDays;

  /// 지난 주 일정 (week_offset_-1)
  final List<HomeWidgetWeekDayData> previousWeekDays;

  /// 다음 주 일정 (week_offset_1)
  final List<HomeWidgetWeekDayData> nextWeekDays;
}

class HomeWidgetSchedulePayloadBuilder {
  const HomeWidgetSchedulePayloadBuilder._();

  static const int todayWidgetRowCapacity = 6;
  static const int tomorrowWidgetMaxRows = 2;
  static const int weeklyWidgetEventRows = 4;
  static const int monthlyWidgetEventRows = 4;

  static HomeWidgetSchedulePayload fromEvents({
    required List<EventModel> events,
    required DateTime now,
    String emptyTitle = '예정된 일정이 없어요',
    int? nextTravelBufferMinutes,
    bool includeWeekends = true,
  }) {
    final localNow = planflowLocal(now);
    final month = DateTime(localNow.year, localNow.month);
    final expandedEvents = _expandRecurringEventsForWidget(events, month);
    final sortedEvents =
        expandedEvents
            .where((event) => event.startAt != null)
            .where((event) => includeWeekends || !_startsOnWeekend(event))
            .toList(growable: false)
          ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    final futureEvents = sortedEvents
        .where((event) => !event.startAt!.isBefore(now))
        .toList(growable: false);
    final nextEvent = futureEvents.isEmpty ? null : futureEvents.first;
    final todayEvents = _eventsForDay(
      sortedEvents,
      DateTime(localNow.year, localNow.month, localNow.day),
    );
    final todayPast = todayEvents
        .where((event) => _effectiveEndAt(event).isBefore(now))
        .toList(growable: false);
    final allTodayUpcoming = todayEvents
        .where((event) => !_effectiveEndAt(event).isBefore(now))
        .map(_listEvent)
        .toList(growable: false);
    final tomorrow = DateTime(localNow.year, localNow.month, localNow.day + 1);
    final allTomorrowEvents = futureEvents
        .where((event) => planflowIsSameLocalDay(event.startAt!, tomorrow))
        .map(_listEvent)
        .toList(growable: false);
    final todayUpcoming = _displayTodayRows(allTodayUpcoming);
    final tomorrowEvents = _displayTomorrowRows(
      todayRows: todayUpcoming,
      sourceTodayCount: allTodayUpcoming.length,
      sourceTomorrowEvents: allTomorrowEvents,
    );
    final yesterday = DateTime(localNow.year, localNow.month, localNow.day - 1);
    final yesterdayEvents = _eventsForDay(
      sortedEvents,
      yesterday,
    ).map(_listEvent).take(6).toList(growable: false);
    final previousMonth = DateTime(month.year, month.month - 1);
    final nextMonth = DateTime(month.year, month.month + 1);
    final previousWeekNow = DateTime(
      localNow.year,
      localNow.month,
      localNow.day - 7,
    );
    final nextWeekNow = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 7,
    );

    return HomeWidgetSchedulePayload(
      nextEvent: nextEvent == null
          ? HomeWidgetNextEventData(title: emptyTitle)
          : HomeWidgetNextEventData(
              title: nextEvent.title,
              eventId: nextEvent.id,
              startAt: nextEvent.startAt,
              location: nextEvent.location,
              travelBufferMinutes: nextTravelBufferMinutes,
              isCritical: nextEvent.isCritical,
            ),
      month: month,
      lastPastEvent: todayPast.isEmpty ? null : _listEvent(todayPast.last),
      todayUpcomingEvents: todayUpcoming,
      tomorrowEvents: tomorrowEvents,
      yesterdayEvents: yesterdayEvents,
      monthDays: _monthDays(sortedEvents, month),
      monthCells: _monthCells(sortedEvents, month),
      previousMonthCells: _monthCells(sortedEvents, previousMonth),
      nextMonthCells: _monthCells(sortedEvents, nextMonth),
      weekDays: _weekDays(sortedEvents, now),
      previousWeekDays: _weekDays(sortedEvents, previousWeekNow),
      nextWeekDays: _weekDays(sortedEvents, nextWeekNow),
      rawEvents: _rawEvents(expandedEvents),
    );
  }

  static List<Map<String, Object?>> _rawEvents(List<EventModel> events) {
    return events
        .map(
          (event) => <String, Object?>{
            'id': event.id,
            'user_id': event.userId,
            'title': event.title,
            'start_at': event.startAt?.toUtc().toIso8601String(),
            'end_at': event.endAt?.toUtc().toIso8601String(),
            'location': event.location,
            'is_critical': event.isCritical,
            'is_all_day': event.isAllDay,
            'is_multi_day': event.isMultiDay,
            'parent_event_id': event.parentEventId,
          },
        )
        .toList(growable: false);
  }

  static List<EventModel> _expandRecurringEventsForWidget(
    List<EventModel> events,
    DateTime month,
  ) {
    final previousFirstCell = _firstMonthGridCell(
      DateTime(month.year, month.month - 1),
    );
    final nextFirstCell = _firstMonthGridCell(
      DateTime(month.year, month.month + 1),
    );
    final rangeStart = previousFirstCell;
    final rangeEnd = nextFirstCell.add(const Duration(days: 42));
    final expanded = <EventModel>[];
    for (final event in events) {
      expanded.addAll(
        _expandSingleWidgetEvent(
          event,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
        ),
      );
    }
    return _hideOverriddenWidgetOccurrences(expanded);
  }

  static DateTime _firstMonthGridCell(DateTime month) {
    final monthStart = DateTime(month.year, month.month);
    final startWeekday = monthStart.weekday % 7;
    return monthStart.subtract(Duration(days: startWeekday));
  }

  static List<EventModel> _expandSingleWidgetEvent(
    EventModel event, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) {
    final rule = event.recurrenceRule?.toUpperCase();
    final startAt = event.startAt;
    if (rule == null || rule.isEmpty || startAt == null) {
      return <EventModel>[event];
    }

    final freq = RegExp(r'FREQ=([A-Z]+)').firstMatch(rule)?.group(1);
    if (freq == null) {
      return <EventModel>[event];
    }

    final intervalText = RegExp(r'INTERVAL=(\d+)').firstMatch(rule)?.group(1);
    final interval = int.tryParse(intervalText ?? '1')?.clamp(1, 365) ?? 1;
    final until = _parseWidgetRRuleUntil(
      RegExp(r'UNTIL=([0-9TzZ]+)').firstMatch(rule)?.group(1),
    );
    final hardEnd = until?.isBefore(rangeEnd) == true ? until! : rangeEnd;
    final localStartAt = planflowLocal(startAt);
    final duration = event.endAt?.difference(startAt);
    final occurrences = <EventModel>[];

    if (freq == 'WEEKLY') {
      final byDays = _parseWidgetRRuleByDays(rule);
      if (byDays.isNotEmpty) {
        var weekStart = DateTime(
          localStartAt.year,
          localStartAt.month,
          localStartAt.day,
          localStartAt.hour,
          localStartAt.minute,
          localStartAt.second,
        ).subtract(Duration(days: localStartAt.weekday - DateTime.monday));
        var safety = 0;
        while (weekStart.isBefore(hardEnd) && safety < 120) {
          safety += 1;
          for (final weekday in byDays) {
            final day = weekStart.add(
              Duration(days: weekday - DateTime.monday),
            );
            final current = DateTime(
              day.year,
              day.month,
              day.day,
              localStartAt.hour,
              localStartAt.minute,
              localStartAt.second,
            );
            if (current.isBefore(localStartAt) || !current.isBefore(hardEnd)) {
              continue;
            }
            final occurrenceEnd = duration == null
                ? null
                : current.add(duration);
            final candidate = _copyWidgetEventWithTime(
              event,
              startAt: current,
              endAt: occurrenceEnd,
            );
            if (_widgetEventIntersectsRange(candidate, rangeStart, rangeEnd)) {
              occurrences.add(candidate);
            }
          }
          weekStart = weekStart.add(Duration(days: 7 * interval));
        }
        return occurrences.isEmpty ? <EventModel>[event] : occurrences;
      }
    }

    var current = localStartAt;
    var safety = 0;
    while (current.isBefore(hardEnd) && safety < 420) {
      safety += 1;
      final occurrenceEnd = duration == null ? null : current.add(duration);
      final candidate = _copyWidgetEventWithTime(
        event,
        startAt: current,
        endAt: occurrenceEnd,
      );
      if (_widgetEventIntersectsRange(candidate, rangeStart, rangeEnd)) {
        occurrences.add(candidate);
      }
      current = switch (freq) {
        'DAILY' => current.add(Duration(days: interval)),
        'WEEKLY' => current.add(Duration(days: 7 * interval)),
        'MONTHLY' => DateTime(
          current.year,
          current.month + interval,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
        'YEARLY' => DateTime(
          current.year + interval,
          current.month,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
        _ => hardEnd,
      };
    }
    return occurrences.isEmpty ? <EventModel>[event] : occurrences;
  }

  static DateTime? _parseWidgetRRuleUntil(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    final normalized = value.replaceAll('Z', '');
    if (normalized.length < 8) {
      return null;
    }
    final year = int.tryParse(normalized.substring(0, 4));
    final month = int.tryParse(normalized.substring(4, 6));
    final day = int.tryParse(normalized.substring(6, 8));
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day).add(const Duration(days: 1));
  }

  static List<int> _parseWidgetRRuleByDays(String rule) {
    final raw = RegExp(r'BYDAY=([A-Z0-9,\-]+)').firstMatch(rule)?.group(1);
    if (raw == null || raw.isEmpty) {
      return const <int>[];
    }
    return raw
        .split(',')
        .map((item) => item.replaceAll(RegExp(r'[-0-9]'), ''))
        .map(
          (item) => switch (item) {
            'MO' => DateTime.monday,
            'TU' => DateTime.tuesday,
            'WE' => DateTime.wednesday,
            'TH' => DateTime.thursday,
            'FR' => DateTime.friday,
            'SA' => DateTime.saturday,
            'SU' => DateTime.sunday,
            _ => null,
          },
        )
        .whereType<int>()
        .toList(growable: false);
  }

  static EventModel _copyWidgetEventWithTime(
    EventModel event, {
    required DateTime startAt,
    DateTime? endAt,
  }) {
    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: startAt,
      endAt: endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: null,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.id,
      category: event.category,
      source: event.source,
      externalId: event.externalId,
      externalCalendarId: event.externalCalendarId,
      externalEtag: event.externalEtag,
      externalUpdatedAt: event.externalUpdatedAt,
      lastSyncedAt: event.lastSyncedAt,
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
  }

  static bool _widgetEventIntersectsRange(
    EventModel event,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final localStart = planflowLocal(startAt);
    final localDisplayEndDay = _displayEndDay(event);
    final endExclusive = localDisplayEndDay.add(const Duration(days: 1));
    return localStart.isBefore(rangeEnd) && endExclusive.isAfter(rangeStart);
  }

  static List<EventModel> _hideOverriddenWidgetOccurrences(
    List<EventModel> events,
  ) {
    final overrides = events
        .where(
          (event) =>
              event.parentEventId != null &&
              event.parentEventId!.trim().isNotEmpty &&
              event.parentEventId != event.id &&
              event.startAt != null,
        )
        .toList(growable: false);
    if (overrides.isEmpty) {
      return events;
    }
    return events
        .where((event) {
          final startAt = event.startAt;
          if (startAt == null) {
            return true;
          }
          final isOverridden = overrides.any((override) {
            if (override.parentEventId != event.id) {
              return false;
            }
            final overrideStart = override.startAt;
            return overrideStart != null &&
                planflowIsSameLocalDay(overrideStart, startAt);
          });
          return !isOverridden;
        })
        .toList(growable: false);
  }

  static List<HomeWidgetMonthDayData> _monthDays(
    List<EventModel> events,
    DateTime month,
  ) {
    final counts = <int, int>{};
    final criticalDays = <int>{};
    for (final event in events) {
      final startAt = event.startAt;
      final localStart = startAt == null ? null : planflowLocal(startAt);
      if (localStart == null ||
          localStart.year != month.year ||
          localStart.month != month.month) {
        continue;
      }
      counts[localStart.day] = (counts[localStart.day] ?? 0) + 1;
      if (event.isCritical) {
        criticalDays.add(localStart.day);
      }
    }
    return counts.entries
        .map(
          (entry) => HomeWidgetMonthDayData(
            day: entry.key,
            summary: '일정 ${entry.value}',
            eventCount: entry.value,
            hasCritical: criticalDays.contains(entry.key),
          ),
        )
        .toList(growable: false);
  }

  static List<HomeWidgetMonthCellData> _monthCells(
    List<EventModel> events,
    DateTime month,
  ) {
    final firstDay = DateTime(month.year, month.month);
    final startOffset = firstDay.weekday % 7;
    final firstCellDay = firstDay.subtract(Duration(days: startOffset));
    final cellDays = List<DateTime>.generate(
      42,
      (i) => firstCellDay.add(Duration(days: i)),
    );

    // 셀별 슬롯: slotMap[cellIndex][slot] = EventModel?
    final slotMap = List.generate(
      42,
      (_) => List<EventModel?>.filled(
        monthlyWidgetEventRows,
        null,
        growable: false,
      ),
    );
    final overflowCounts = List<int>.filled(42, 0);

    // 1단계: 멀티데이 이벤트를 startAt 기준 정렬 후 slot 예약
    final multiDayEvents = events.where((e) {
      if (e.startAt == null) return false;
      final fd = planflowLocalDay(e.startAt!);
      final ld = _displayEndDay(e);
      return ld.isAfter(fd);
    }).toList()..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    for (final event in multiDayEvents) {
      final fd = planflowLocalDay(event.startAt!);
      final ld = _displayEndDay(event);
      // 이 이벤트가 걸치는 셀 인덱스
      final cellIndices = [
        for (var i = 0; i < 42; i++)
          if (!cellDays[i].isBefore(fd) && !cellDays[i].isAfter(ld)) i,
      ];
      if (cellIndices.isEmpty) continue;
      // 이 기간 전체에서 비어있는 첫 번째 slot 예약
      var reserved = false;
      for (var slot = 0; slot < monthlyWidgetEventRows; slot++) {
        if (cellIndices.every((i) => slotMap[i][slot] == null)) {
          for (final i in cellIndices) {
            slotMap[i][slot] = event;
          }
          reserved = true;
          break;
        }
      }
      if (!reserved) {
        // slot 없으면 overflow에 기여 (모든 해당 날짜)
        for (final i in cellIndices) {
          overflowCounts[i]++;
        }
      }
    }

    // 2단계: 단일 이벤트(같은 날 시작·종료)를 남은 slot에 채움
    for (var i = 0; i < 42; i++) {
      final day = cellDays[i];
      final singleEvents =
          events.where((e) {
            if (e.startAt == null) return false;
            final fd = planflowLocalDay(e.startAt!);
            final ld = _displayEndDay(e);
            return !ld.isAfter(fd) && fd == day;
          }).toList()..sort((a, b) {
            final aStart = a.startAt;
            final bStart = b.startAt;
            if (aStart == null && bStart == null) {
              return a.title.compareTo(b.title);
            }
            if (aStart == null) return 1;
            if (bStart == null) return -1;
            return aStart.compareTo(bStart);
          });
      for (final event in singleEvents) {
        var placed = false;
        for (var slot = 0; slot < monthlyWidgetEventRows; slot++) {
          if (slotMap[i][slot] == null) {
            slotMap[i][slot] = event;
            placed = true;
            break;
          }
        }
        if (!placed) overflowCounts[i]++;
      }
    }

    // 2.5단계: 월간 위젯은 3개까지 실제 일정을 보이고, 그 이상은 +n개로 대체합니다.
    // XML 레이아웃(event_1~4 + overflow_count)에서 overflow_count와 event_4가
    // 동시에 표시되면 5행이 돼 레이아웃이 깨지므로 마지막 슬롯을 overflow 자리로 씁니다.
    final maxVisibleMonthlyEvents = monthlyWidgetEventRows - 1;
    for (var i = 0; i < 42; i++) {
      final totalDayEvents = _eventsForDay(events, cellDays[i]).length;
      final requiresOverflowLabel =
          overflowCounts[i] > 0 || totalDayEvents > maxVisibleMonthlyEvents;
      if (requiresOverflowLabel &&
          slotMap[i][maxVisibleMonthlyEvents] != null) {
        slotMap[i][maxVisibleMonthlyEvents] = null;
      }
    }

    // 3단계: HomeWidgetMonthCellData 생성
    return List<HomeWidgetMonthCellData>.generate(42, (i) {
      final day = cellDays[i];
      final inMonth = day.year == month.year && day.month == month.month;
      final dayEvents = _eventsForDay(events, day);
      final visibleIds = slotMap[i]
          .whereType<EventModel>()
          .map((event) => event.id)
          .toSet();
      final hiddenEvents = dayEvents
          .where((event) => !visibleIds.contains(event.id))
          .toList(growable: false);
      final overflowCount = hiddenEvents.length;
      final cellEvents = slotMap[i]
          .where((e) => e != null)
          .map((e) => _listEventForMonthCell(e!, day))
          .toList(growable: false);
      return HomeWidgetMonthCellData(
        cellIndex: i + 1,
        date: day,
        day: day.day,
        inMonth: inMonth,
        events: cellEvents,
        overflowCount: overflowCount,
        overflowPreviewTitle: hiddenEvents.isEmpty
            ? null
            : hiddenEvents.first.title.trim().isEmpty
            ? null
            : hiddenEvents.first.title.trim(),
      );
    });
  }

  /// 월간 달력 셀용 이벤트 변환 — segment 타입 계산 포함
  static HomeWidgetListEventData _listEventForMonthCell(
    EventModel event,
    DateTime cellDay,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      return _listEvent(event);
    }
    final firstEventDay = planflowLocalDay(startAt);
    final lastEventDay = _displayEndDay(event);
    final isMultiDay = lastEventDay.isAfter(firstEventDay);

    if (!isMultiDay) {
      return HomeWidgetListEventData(
        title: event.title,
        eventId: event.id,
        startAt: event.startAt,
        location: event.location,
        isCritical: event.isCritical,
        monthSegment: 'single',
        showTitleInMonth: true,
      );
    }

    // 주 경계: 일요일(0)=행 시작 시각적으로 start처럼 처리
    final isRowStart = cellDay.weekday == DateTime.sunday || cellDay.day == 1;
    final isRowEnd =
        cellDay.weekday == DateTime.saturday ||
        cellDay.day == DateTime(cellDay.year, cellDay.month + 1, 0).day;

    final isCellFirstDay = cellDay == firstEventDay;
    final isCellLastDay = cellDay == lastEventDay;

    final String segment;
    if ((isCellFirstDay || isRowStart) && (isCellLastDay || isRowEnd)) {
      segment = 'single';
    } else if (isCellFirstDay || isRowStart) {
      segment = 'start';
    } else if (isCellLastDay || isRowEnd) {
      segment = 'end';
    } else {
      segment = 'middle';
    }

    return HomeWidgetListEventData(
      title: event.title,
      eventId: event.id,
      startAt: event.startAt,
      location: event.location,
      isCritical: event.isCritical,
      monthSegment: segment,
      showTitleInMonth: segment == 'single' || segment == 'start',
    );
  }

  static List<HomeWidgetWeekDayData> _weekDays(
    List<EventModel> events,
    DateTime now,
  ) {
    final localNow = planflowLocal(now);
    final weekStart = DateTime(
      localNow.year,
      localNow.month,
      localNow.day,
    ).subtract(Duration(days: localNow.weekday - 1));
    return List<HomeWidgetWeekDayData>.generate(7, (index) {
      final day = weekStart.add(Duration(days: index));
      final dayEvents = _eventsForDay(events, day);
      final hiddenEvents = dayEvents
          .skip(weeklyWidgetEventRows)
          .toList(growable: false);
      return HomeWidgetWeekDayData(
        date: day,
        summary: dayEvents.isEmpty ? '일정 없음' : '${dayEvents.length}건',
        eventCount: dayEvents.length,
        overflowPreviewTitle: hiddenEvents.isEmpty
            ? null
            : hiddenEvents.first.title.trim().isEmpty
            ? null
            : hiddenEvents.first.title.trim(),
        hasCritical: dayEvents.any((event) => event.isCritical),
        events: dayEvents
            .map(_listEvent)
            .take(weeklyWidgetEventRows)
            .toList(growable: false),
      );
    });
  }

  static List<EventModel> _eventsForDay(List<EventModel> events, DateTime day) {
    final dayEvents =
        events
            .where((event) => _eventIntersectsDisplayDay(event, day))
            .toList(growable: false)
          ..sort((a, b) {
            final aStart = a.startAt;
            final bStart = b.startAt;
            if (aStart == null && bStart == null) {
              return a.title.compareTo(b.title);
            }
            if (aStart == null) {
              return 1;
            }
            if (bStart == null) {
              return -1;
            }
            return aStart.compareTo(bStart);
          });
    return dayEvents;
  }

  static DateTime _displayEndDay(EventModel event) {
    final startAt = event.startAt;
    final endAt = event.endAt ?? startAt;
    if (startAt == null || endAt == null) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    var localEnd = planflowLocal(endAt);
    if (endAt.isAfter(startAt) &&
        localEnd.hour == 0 &&
        localEnd.minute == 0 &&
        localEnd.second == 0 &&
        localEnd.millisecond == 0 &&
        localEnd.microsecond == 0) {
      localEnd = localEnd.subtract(const Duration(microseconds: 1));
    }
    return planflowLocalDay(localEnd);
  }

  static bool _eventIntersectsDisplayDay(EventModel event, DateTime day) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final firstDay = planflowLocalDay(startAt);
    final lastDay = _displayEndDay(event);
    final targetDay = DateTime(day.year, day.month, day.day);
    return !targetDay.isBefore(firstDay) && !targetDay.isAfter(lastDay);
  }

  static bool _startsOnWeekend(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final localStart = planflowLocal(startAt);
    return localStart.weekday == DateTime.saturday ||
        localStart.weekday == DateTime.sunday;
  }

  static DateTime _effectiveEndAt(EventModel event) {
    return event.endAt ??
        event.startAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  static HomeWidgetListEventData _listEvent(EventModel event) {
    return HomeWidgetListEventData(
      title: event.title,
      eventId: event.id,
      startAt: event.startAt,
      location: event.location,
      isCritical: event.isCritical,
    );
  }

  static List<HomeWidgetListEventData> _displayTodayRows(
    List<HomeWidgetListEventData> events,
  ) {
    if (events.length <= todayWidgetRowCapacity) {
      return events.take(todayWidgetRowCapacity).toList(growable: false);
    }

    final hiddenCount = events.length - (todayWidgetRowCapacity - 1);
    return <HomeWidgetListEventData>[
      ...events.take(todayWidgetRowCapacity - 1),
      HomeWidgetListEventData(title: '오늘 일정 $hiddenCount개 더'),
    ];
  }

  static List<HomeWidgetListEventData> _displayTomorrowRows({
    required List<HomeWidgetListEventData> todayRows,
    required int sourceTodayCount,
    required List<HomeWidgetListEventData> sourceTomorrowEvents,
  }) {
    if (sourceTodayCount > todayWidgetRowCapacity) {
      return const <HomeWidgetListEventData>[];
    }
    final remainingCapacity = todayWidgetRowCapacity - todayRows.length;
    if (remainingCapacity <= 0) {
      return const <HomeWidgetListEventData>[];
    }
    final limit = remainingCapacity < tomorrowWidgetMaxRows
        ? remainingCapacity
        : tomorrowWidgetMaxRows;
    return sourceTomorrowEvents.take(limit).toList(growable: false);
  }
}

class HomeWidgetService {
  HomeWidgetService({
    HomeWidgetPlatform? platform,
    TravelTimeBufferService? travelTimeBufferService,
    this.iOSAppGroupId,
  }) : _platform = platform ?? createHomeWidgetPlatform(),
       _travelTimeBufferService =
           travelTimeBufferService ?? TravelTimeBufferService();

  static const String defaultWidgetName = 'PlanFlowHomeWidgetProvider';
  static const String hideWeekendsKey = 'widget_hide_weekends';
  static const String _localHideWeekendsKey =
      'planflow.home_widget.hide_weekends';
  static const List<String> defaultAndroidWidgetNames = <String>[
    'PlanFlowHomeWidgetProvider',
    'PlanFlowMonthlyWidgetProvider',
    'PlanFlowVerticalScheduleWidgetProvider',
    'PlanFlowWeeklyWidgetProvider',
    'PlanFlowWeeklyListWidgetProvider',
    'PlanFlowMicWidgetProvider',
  ];

  final HomeWidgetPlatform _platform;
  final TravelTimeBufferService _travelTimeBufferService;
  final String? iOSAppGroupId;

  bool get isSupported => _platform.isSupported;

  Future<bool> areWeekendsHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_localHideWeekendsKey) ?? false;
  }

  Future<bool> setHideWeekends(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_localHideWeekendsKey, value);
    final saved = await _saveValue(hideWeekendsKey, value);
    await _refreshWidgets(widgetName: defaultWidgetName);
    return saved;
  }

  Future<bool> refreshScheduleFromEvents(
    List<EventModel> events, {
    DateTime? now,
    String emptyTitle = '예정된 일정이 없어요',
    int? nextTravelBufferMinutes,
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    final hideWeekends = await areWeekendsHidden();
    return updateSchedulePayload(
      HomeWidgetSchedulePayloadBuilder.fromEvents(
        events: events,
        now: now ?? DateTime.now(),
        emptyTitle: emptyTitle,
        nextTravelBufferMinutes: nextTravelBufferMinutes,
        includeWeekends: !hideWeekends,
      ),
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );
  }

  Future<bool> updateNextEvent({
    required String title,
    String? eventId,
    DateTime? startAt,
    String? location,
    String? travelOrigin,
    double? latitude,
    double? longitude,
    int? travelBufferMinutes,
    bool isCritical = false,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    final resolvedBufferMinutes =
        travelBufferMinutes ??
        await _resolveTravelBufferMinutes(
          travelOrigin: travelOrigin,
          destination: location,
          latitude: latitude,
          longitude: longitude,
        );

    return updateNextEventData(
      HomeWidgetNextEventData(
        title: title,
        eventId: eventId,
        startAt: startAt,
        location: location,
        travelBufferMinutes: resolvedBufferMinutes,
        isCritical: isCritical,
      ),
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
      upcomingEvents: upcomingEvents,
    );
  }

  Future<bool> updateNextEventData(
    HomeWidgetNextEventData data, {
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
  }) async {
    if (!isSupported) {
      return false;
    }

    if (!await _ensureConfigured()) {
      return false;
    }

    var success = true;
    success =
        await _saveValue('next_event_title', data.title.trim()) && success;
    success =
        await _saveOptionalValue('next_event_id', data.eventId) && success;
    success =
        await _saveOptionalValue(
          'next_event_start_at',
          data.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success =
        await _saveOptionalValue('next_event_location', data.location) &&
        success;
    success =
        await _saveOptionalValue(
          'next_event_travel_buffer_minutes',
          data.travelBufferMinutes,
        ) &&
        success;
    success =
        await _saveValue('next_event_is_critical', data.isCritical) && success;
    success = await _saveTodayEvents(upcomingEvents) && success;

    final refreshed = await _refreshWidgets(
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );

    return success && refreshed;
  }

  Future<bool> updateScheduleData({
    required HomeWidgetNextEventData nextEvent,
    List<Map<String, Object?>> rawEvents = const <Map<String, Object?>>[],
    List<HomeWidgetListEventData> todayEvents =
        const <HomeWidgetListEventData>[],
    HomeWidgetListEventData? lastPastEvent,
    List<HomeWidgetListEventData> todayUpcomingEvents =
        const <HomeWidgetListEventData>[],
    List<HomeWidgetListEventData> tomorrowEvents =
        const <HomeWidgetListEventData>[],
    DateTime? month,
    List<HomeWidgetMonthDayData> monthDays = const <HomeWidgetMonthDayData>[],
    List<HomeWidgetMonthCellData> monthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> previousMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> nextMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> previousWeekDays =
        const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> nextWeekDays = const <HomeWidgetWeekDayData>[],
    List<HomeWidgetListEventData> yesterdayEvents =
        const <HomeWidgetListEventData>[],
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (!isSupported) {
      return false;
    }

    if (!await _ensureConfigured()) {
      return false;
    }

    var success = true;
    success =
        await _saveValue('next_event_title', nextEvent.title.trim()) && success;
    success =
        await _saveOptionalValue('next_event_id', nextEvent.eventId) && success;
    success =
        await _saveOptionalValue(
          'next_event_start_at',
          nextEvent.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success =
        await _saveOptionalValue('next_event_location', nextEvent.location) &&
        success;
    success =
        await _saveOptionalValue(
          'next_event_travel_buffer_minutes',
          nextEvent.travelBufferMinutes,
        ) &&
        success;
    success =
        await _saveValue('next_event_is_critical', nextEvent.isCritical) &&
        success;
    success = await _saveTodayEvents(todayEvents) && success;
    success =
        await _saveTodayScheduleData(
          lastPastEvent: lastPastEvent,
          todayUpcomingEvents: todayUpcomingEvents.isEmpty
              ? todayEvents
              : todayUpcomingEvents,
          tomorrowEvents: tomorrowEvents,
        ) &&
        success;
    success =
        await _saveValue('schedule_events_json', jsonEncode(rawEvents)) &&
        success;
    success = await _saveMonthData(month: month, days: monthDays) && success;
    success = await _saveMonthCalendarData(monthCells) && success;
    success =
        await _saveMonthCalendarData(
          previousMonthCells,
          keyPrefix: 'month_offset_-1_cell',
        ) &&
        success;
    success =
        await _saveMonthCalendarData(
          nextMonthCells,
          keyPrefix: 'month_offset_1_cell',
        ) &&
        success;
    if (month != null) {
      success =
          await _saveOptionalValue(
            'month_title_offset_-1',
            '${DateTime(month.year, month.month - 1).year}.'
                '${DateTime(month.year, month.month - 1).month.toString().padLeft(2, '0')}',
          ) &&
          success;
      success =
          await _saveOptionalValue(
            'month_title_offset_1',
            '${DateTime(month.year, month.month + 1).year}.'
                '${DateTime(month.year, month.month + 1).month.toString().padLeft(2, '0')}',
          ) &&
          success;
    }
    success = await _saveWeekData(weekDays) && success;
    success =
        await _saveWeekData(
          previousWeekDays,
          keyPrefix: 'week_offset_-1_day',
          titleKey: 'week_title_offset_-1',
        ) &&
        success;
    success =
        await _saveWeekData(
          nextWeekDays,
          keyPrefix: 'week_offset_1_day',
          titleKey: 'week_title_offset_1',
        ) &&
        success;
    // 일별 offset: -1(어제), 0(오늘), 1(내일)
    success = await _saveDayOffsetEvents(-1, yesterdayEvents) && success;
    success =
        await _saveDayOffsetEvents(
          0,
          todayUpcomingEvents.isEmpty ? todayEvents : todayUpcomingEvents,
        ) &&
        success;
    success = await _saveDayOffsetEvents(1, tomorrowEvents) && success;

    final refreshed = await _refreshWidgets(
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );

    return success && refreshed;
  }

  Future<bool> updateSchedulePayload(
    HomeWidgetSchedulePayload payload, {
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) {
    return updateScheduleData(
      nextEvent: payload.nextEvent,
      rawEvents: payload.rawEvents,
      todayEvents: payload.todayUpcomingEvents,
      lastPastEvent: payload.lastPastEvent,
      todayUpcomingEvents: payload.todayUpcomingEvents,
      tomorrowEvents: payload.tomorrowEvents,
      yesterdayEvents: payload.yesterdayEvents,
      month: payload.month,
      monthDays: payload.monthDays,
      monthCells: payload.monthCells,
      previousMonthCells: payload.previousMonthCells,
      nextMonthCells: payload.nextMonthCells,
      weekDays: payload.weekDays,
      previousWeekDays: payload.previousWeekDays,
      nextWeekDays: payload.nextWeekDays,
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );
  }

  Future<int> _resolveTravelBufferMinutes({
    required String? travelOrigin,
    required String? destination,
    double? latitude,
    double? longitude,
  }) async {
    final normalizedOrigin = travelOrigin?.trim() ?? '';
    final normalizedDestination = destination?.trim() ?? '';
    if (normalizedOrigin.isNotEmpty && normalizedDestination.isNotEmpty) {
      return _travelTimeBufferService.estimateMinutesWithGoogleMaps(
        origin: normalizedOrigin,
        destination: normalizedDestination,
        latitude: latitude,
        longitude: longitude,
        locationText: destination,
      );
    }

    return _travelTimeBufferService.estimateMinutes(
      latitude: latitude,
      longitude: longitude,
      locationText: destination,
    );
  }

  Future<bool> _saveTodayEvents(List<HomeWidgetListEventData> events) async {
    var success = true;
    final slots = events.take(6).toList(growable: false);

    success = await _saveValue('today_event_count', slots.length) && success;

    for (var index = 0; index < 6; index += 1) {
      final event = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success =
          await _saveOptionalValue('event_list_${slot}_id', event?.eventId) &&
          success;
      success =
          await _saveOptionalValue('event_list_${slot}_title', event?.title) &&
          success;
      success =
          await _saveOptionalValue(
            'event_list_${slot}_time',
            event?.startAt?.toUtc().toIso8601String(),
          ) &&
          success;
      success =
          await _saveOptionalValue(
            'event_list_${slot}_location',
            event?.location,
          ) &&
          success;
      success =
          await _saveValue(
            'event_list_${slot}_is_critical',
            event?.isCritical ?? false,
          ) &&
          success;
    }

    return success;
  }

  Future<bool> _saveTodayScheduleData({
    required HomeWidgetListEventData? lastPastEvent,
    required List<HomeWidgetListEventData> todayUpcomingEvents,
    required List<HomeWidgetListEventData> tomorrowEvents,
  }) async {
    var success = true;
    success = await _saveListEvent('last_past_event', lastPastEvent) && success;
    final todaySlots = todayUpcomingEvents
        .take(HomeWidgetSchedulePayloadBuilder.todayWidgetRowCapacity)
        .toList(growable: false);
    final remainingCapacity =
        HomeWidgetSchedulePayloadBuilder.todayWidgetRowCapacity -
        todaySlots.length;
    final tomorrowLimit =
        remainingCapacity <
            HomeWidgetSchedulePayloadBuilder.tomorrowWidgetMaxRows
        ? remainingCapacity
        : HomeWidgetSchedulePayloadBuilder.tomorrowWidgetMaxRows;
    final tomorrowSlots = tomorrowLimit <= 0
        ? const <HomeWidgetListEventData>[]
        : tomorrowEvents.take(tomorrowLimit).toList(growable: false);
    success =
        await _saveValue('today_upcoming_count', todaySlots.length) && success;
    success =
        await _saveValue('tomorrow_event_count', tomorrowSlots.length) &&
        success;
    for (
      var index = 0;
      index < HomeWidgetSchedulePayloadBuilder.todayWidgetRowCapacity;
      index += 1
    ) {
      success =
          await _saveListEvent(
            'today_upcoming_${index + 1}',
            index < todaySlots.length ? todaySlots[index] : null,
          ) &&
          success;
    }
    for (var index = 0; index < 2; index += 1) {
      success =
          await _saveListEvent(
            'tomorrow_event_${index + 1}',
            index < tomorrowSlots.length ? tomorrowSlots[index] : null,
          ) &&
          success;
    }
    return success;
  }

  Future<bool> _saveMonthData({
    required DateTime? month,
    required List<HomeWidgetMonthDayData> days,
  }) async {
    var success = true;
    final resolvedMonth = month ?? DateTime.now();
    success =
        await _saveValue(
          'month_title',
          '${resolvedMonth.year}.${resolvedMonth.month.toString().padLeft(2, '0')}',
        ) &&
        success;

    final summaries = <int, String>{};
    for (final day in days) {
      if (day.day >= 1 && day.day <= 31) {
        summaries[day.day] = day.summary.trim();
      }
    }

    for (var day = 1; day <= 31; day += 1) {
      HomeWidgetMonthDayData? sourceDay;
      for (final candidate in days) {
        if (candidate.day == day) {
          sourceDay = candidate;
          break;
        }
      }
      success =
          await _saveOptionalValue(
            'month_day_${day}_summary',
            summaries[day],
          ) &&
          success;
      success =
          await _saveOptionalValue(
            'month_day_${day}_count',
            sourceDay?.eventCount,
          ) &&
          success;
      success =
          await _saveValue(
            'month_day_${day}_has_critical',
            sourceDay?.hasCritical ?? false,
          ) &&
          success;
    }

    return success;
  }

  Future<bool> _saveMonthCalendarData(
    List<HomeWidgetMonthCellData> cells, {
    String keyPrefix = 'month_cell',
  }) async {
    var success = true;
    final byCell = <int, HomeWidgetMonthCellData>{
      for (final cell in cells)
        if (cell.cellIndex >= 1 && cell.cellIndex <= 42) cell.cellIndex: cell,
    };
    for (var cellIndex = 1; cellIndex <= 42; cellIndex += 1) {
      final cell = byCell[cellIndex];
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${cellIndex}_date',
            cell?.date == null
                ? null
                : _localDateKey(planflowLocal(cell!.date!)),
          ) &&
          success;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${cellIndex}_day',
            cell?.day,
          ) &&
          success;
      success =
          await _saveValue(
            '${keyPrefix}_${cellIndex}_in_month',
            cell?.inMonth ?? false,
          ) &&
          success;
      success =
          await _saveValue(
            '${keyPrefix}_${cellIndex}_overflow_count',
            cell?.overflowCount ?? 0,
          ) &&
          success;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${cellIndex}_overflow_preview_title',
            cell?.overflowPreviewTitle,
          ) &&
          success;
      final events =
          cell?.events
              .take(HomeWidgetSchedulePayloadBuilder.monthlyWidgetEventRows)
              .toList(growable: false) ??
          const <HomeWidgetListEventData>[];
      for (
        var eventIndex = 0;
        eventIndex < HomeWidgetSchedulePayloadBuilder.monthlyWidgetEventRows;
        eventIndex += 1
      ) {
        final event = eventIndex < events.length ? events[eventIndex] : null;
        final eventSlot = eventIndex + 1;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_id',
              event?.eventId,
            ) &&
            success;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_title',
              event?.title,
            ) &&
            success;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_time',
              event?.startAt?.toUtc().toIso8601String(),
            ) &&
            success;
        success =
            await _saveValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_is_critical',
              event?.isCritical ?? false,
            ) &&
            success;
        // multi-day 연속 일정 pill 표시용
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_segment',
              event?.monthSegment,
            ) &&
            success;
        success =
            await _saveValue(
              '${keyPrefix}_${cellIndex}_event_${eventSlot}_show_title',
              event?.showTitleInMonth ?? true,
            ) &&
            success;
      }
    }
    return success;
  }

  Future<bool> _saveWeekData(
    List<HomeWidgetWeekDayData> days, {
    String keyPrefix = 'week_day',
    String? titleKey,
  }) async {
    var success = true;
    final slots = days.take(7).toList(growable: false);

    // 주 범위 타이틀 저장 (이전주/다음주)
    if (titleKey != null && slots.isNotEmpty) {
      final firstDay = slots.first.date;
      final lastDay = slots.last.date;
      final title =
          '${firstDay.month}/${firstDay.day}~${lastDay.month}/${lastDay.day}';
      success = await _saveOptionalValue(titleKey, title) && success;
    }

    for (var index = 0; index < 7; index += 1) {
      final day = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${slot}_date',
            day?.date.toUtc().toIso8601String(),
          ) &&
          success;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${slot}_summary',
            day?.summary,
          ) &&
          success;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${slot}_count',
            day?.eventCount ?? day?.events.length,
          ) &&
          success;
      success =
          await _saveValue(
            '${keyPrefix}_${slot}_has_critical',
            day?.hasCritical ??
                day?.events.any((event) => event.isCritical) ??
                false,
          ) &&
          success;
      success =
          await _saveOptionalValue(
            '${keyPrefix}_${slot}_overflow_preview_title',
            day?.overflowPreviewTitle,
          ) &&
          success;

      final events =
          day?.events
              .take(HomeWidgetSchedulePayloadBuilder.weeklyWidgetEventRows)
              .toList(growable: false) ??
          const <HomeWidgetListEventData>[];
      final eventCount = day?.eventCount ?? day?.events.length ?? 0;
      success =
          await _saveValue(
            '${keyPrefix}_${slot}_overflow_count',
            eventCount > events.length ? eventCount - events.length : 0,
          ) &&
          success;
      for (
        var eventIndex = 0;
        eventIndex < HomeWidgetSchedulePayloadBuilder.weeklyWidgetEventRows;
        eventIndex += 1
      ) {
        final event = eventIndex < events.length ? events[eventIndex] : null;
        final eventSlot = eventIndex + 1;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${slot}_event_${eventSlot}_id',
              event?.eventId,
            ) &&
            success;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${slot}_event_${eventSlot}_title',
              event?.title,
            ) &&
            success;
        success =
            await _saveOptionalValue(
              '${keyPrefix}_${slot}_event_${eventSlot}_time',
              event?.startAt?.toUtc().toIso8601String(),
            ) &&
            success;
        success =
            await _saveValue(
              '${keyPrefix}_${slot}_event_${eventSlot}_is_critical',
              event?.isCritical ?? false,
            ) &&
            success;
      }
    }

    return success;
  }

  /// 일별 offset 이벤트 저장 (-1: 어제, 0: 오늘, 1: 내일)
  Future<bool> _saveDayOffsetEvents(
    int offset,
    List<HomeWidgetListEventData> events,
  ) async {
    var success = true;
    // 세로 주간 위젯 최대 표시 슬롯(5) + overflow 처리
    const maxVisible = 5;
    final slots = events.take(maxVisible).toList(growable: false);
    for (var index = 0; index < maxVisible; index += 1) {
      final event = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success =
          await _saveOptionalValue(
            'day_offset_${offset}_event_${slot}_id',
            event?.eventId,
          ) &&
          success;
      success =
          await _saveOptionalValue(
            'day_offset_${offset}_event_${slot}_title',
            event?.title,
          ) &&
          success;
      success =
          await _saveOptionalValue(
            'day_offset_${offset}_event_${slot}_time',
            event?.startAt?.toUtc().toIso8601String(),
          ) &&
          success;
      success =
          await _saveValue(
            'day_offset_${offset}_event_${slot}_is_critical',
            event?.isCritical ?? false,
          ) &&
          success;
    }
    // 총 개수 및 overflow 미리보기 제목 저장
    success =
        await _saveValue('day_offset_${offset}_count', events.length) &&
        success;
    final overflowTitle = events.skip(maxVisible).firstOrNull?.title.trim();
    success =
        await _saveOptionalValue(
          'day_offset_${offset}_overflow_preview_title',
          overflowTitle == null || overflowTitle.isEmpty ? null : overflowTitle,
        ) &&
        success;
    return success;
  }

  Future<bool> _refreshWidgets({
    required String widgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (widgetName != defaultWidgetName ||
        androidName != null ||
        iOSName != null ||
        qualifiedAndroidName != null) {
      return _platform.updateWidget(
        name: widgetName,
        androidName: androidName,
        iOSName: iOSName,
        qualifiedAndroidName: qualifiedAndroidName,
      );
    }

    var success = true;
    for (final defaultName in defaultAndroidWidgetNames) {
      success = await _platform.updateWidget(name: defaultName) && success;
    }

    return success;
  }

  Future<bool> _ensureConfigured() async {
    if (iOSAppGroupId == null || iOSAppGroupId!.trim().isEmpty) {
      return true;
    }

    return _platform.setAppGroupId(iOSAppGroupId!.trim());
  }

  Future<bool> _saveListEvent(
    String prefix,
    HomeWidgetListEventData? event,
  ) async {
    var success = true;
    success =
        await _saveOptionalValue('${prefix}_id', event?.eventId) && success;
    success =
        await _saveOptionalValue('${prefix}_title', event?.title) && success;
    success =
        await _saveOptionalValue(
          '${prefix}_time',
          event?.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success =
        await _saveOptionalValue('${prefix}_location', event?.location) &&
        success;
    success =
        await _saveValue('${prefix}_is_critical', event?.isCritical ?? false) &&
        success;
    return success;
  }

  String _localDateKey(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  Future<bool> _saveValue(String key, Object? value) async {
    try {
      return await _platform.saveWidgetData(key, value);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _saveOptionalValue(String key, Object? value) async {
    if (value == null) {
      return _saveValue(key, null);
    }

    if (value is String && value.trim().isEmpty) {
      return _saveValue(key, '');
    }

    return _saveValue(key, value);
  }
}
