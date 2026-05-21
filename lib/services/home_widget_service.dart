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
  });

  final String title;
  final String? eventId;
  final DateTime? startAt;
  final String? location;
  final bool isCritical;
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
    this.hasCritical = false,
  });

  final DateTime date;
  final String? summary;
  final List<HomeWidgetListEventData> events;
  final int? eventCount;
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
  });

  final int cellIndex;
  final DateTime? date;
  final int? day;
  final bool inMonth;
  final List<HomeWidgetListEventData> events;
  final int overflowCount;
}

class HomeWidgetSchedulePayload {
  const HomeWidgetSchedulePayload({
    required this.nextEvent,
    required this.month,
    this.lastPastEvent,
    this.todayUpcomingEvents = const <HomeWidgetListEventData>[],
    this.tomorrowEvents = const <HomeWidgetListEventData>[],
    this.monthDays = const <HomeWidgetMonthDayData>[],
    this.monthCells = const <HomeWidgetMonthCellData>[],
    this.weekDays = const <HomeWidgetWeekDayData>[],
  });

  final HomeWidgetNextEventData nextEvent;
  final DateTime month;
  final HomeWidgetListEventData? lastPastEvent;
  final List<HomeWidgetListEventData> todayUpcomingEvents;
  final List<HomeWidgetListEventData> tomorrowEvents;
  final List<HomeWidgetMonthDayData> monthDays;
  final List<HomeWidgetMonthCellData> monthCells;
  final List<HomeWidgetWeekDayData> weekDays;
}

class HomeWidgetSchedulePayloadBuilder {
  const HomeWidgetSchedulePayloadBuilder._();

  static const int todayWidgetRowCapacity = 6;
  static const int tomorrowWidgetMaxRows = 2;

  static HomeWidgetSchedulePayload fromEvents({
    required List<EventModel> events,
    required DateTime now,
    String emptyTitle = '예정된 일정이 없어요',
    int? nextTravelBufferMinutes,
  }) {
    final localNow = planflowLocal(now);
    final sortedEvents = events
        .where((event) => event.startAt != null)
        .toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    final futureEvents = sortedEvents
        .where((event) => !event.startAt!.isBefore(now))
        .toList(growable: false);
    final nextEvent = futureEvents.isEmpty ? null : futureEvents.first;
    final todayEvents = _eventsForDay(
      sortedEvents,
      DateTime(
        localNow.year,
        localNow.month,
        localNow.day,
      ),
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
    final month = DateTime(localNow.year, localNow.month);

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
      monthDays: _monthDays(sortedEvents, month),
      monthCells: _monthCells(sortedEvents, month),
      weekDays: _weekDays(sortedEvents, now),
    );
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
    return List<HomeWidgetMonthCellData>.generate(42, (index) {
      final day = firstCellDay.add(Duration(days: index));
      final inMonth = day.year == month.year && day.month == month.month;
      final dayEvents = inMonth ? _eventsForDay(events, day) : <EventModel>[];
      return HomeWidgetMonthCellData(
        cellIndex: index + 1,
        date: day,
        day: inMonth ? day.day : null,
        inMonth: inMonth,
        events: dayEvents.map(_listEvent).take(3).toList(growable: false),
        overflowCount: dayEvents.length > 3 ? dayEvents.length - 3 : 0,
      );
    });
  }

  static List<HomeWidgetWeekDayData> _weekDays(
    List<EventModel> events,
    DateTime now,
  ) {
    final localNow = planflowLocal(now);
    final weekStart = DateTime(localNow.year, localNow.month, localNow.day)
        .subtract(Duration(days: localNow.weekday - 1));
    return List<HomeWidgetWeekDayData>.generate(7, (index) {
      final day = weekStart.add(Duration(days: index));
      final dayEvents = _eventsForDay(events, day);
      return HomeWidgetWeekDayData(
        date: day,
        summary: dayEvents.isEmpty ? '일정 없음' : '${dayEvents.length}건',
        eventCount: dayEvents.length,
        hasCritical: dayEvents.any((event) => event.isCritical),
        events: dayEvents.map(_listEvent).take(2).toList(growable: false),
      );
    });
  }

  static List<EventModel> _eventsForDay(List<EventModel> events, DateTime day) {
    final dayEvents = events
        .where(
          (event) => planflowEventIntersectsLocalDay(
            startAt: event.startAt,
            endAt: event.endAt,
            day: day,
          ),
        )
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
  })  : _platform = platform ?? createHomeWidgetPlatform(),
        _travelTimeBufferService =
            travelTimeBufferService ?? TravelTimeBufferService();

  static const String defaultWidgetName = 'PlanFlowHomeWidgetProvider';
  static const List<String> defaultAndroidWidgetNames = <String>[
    'PlanFlowHomeWidgetProvider',
    'PlanFlowMonthlyWidgetProvider',
    'PlanFlowVerticalScheduleWidgetProvider',
    'PlanFlowWeeklyWidgetProvider',
    'PlanFlowMicWidgetProvider',
  ];

  final HomeWidgetPlatform _platform;
  final TravelTimeBufferService _travelTimeBufferService;
  final String? iOSAppGroupId;

  bool get isSupported => _platform.isSupported;

  Future<bool> refreshScheduleFromEvents(
    List<EventModel> events, {
    DateTime? now,
    String emptyTitle = '예정된 일정이 없어요',
    int? nextTravelBufferMinutes,
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) {
    return updateSchedulePayload(
      HomeWidgetSchedulePayloadBuilder.fromEvents(
        events: events,
        now: now ?? DateTime.now(),
        emptyTitle: emptyTitle,
        nextTravelBufferMinutes: nextTravelBufferMinutes,
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
    final resolvedBufferMinutes = travelBufferMinutes ??
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
    success = await _saveOptionalValue(
            'next_event_start_at', data.startAt?.toUtc().toIso8601String()) &&
        success;
    success = await _saveOptionalValue('next_event_location', data.location) &&
        success;
    success = await _saveOptionalValue(
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
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
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
    success = await _saveOptionalValue(
          'next_event_start_at',
          nextEvent.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success =
        await _saveOptionalValue('next_event_location', nextEvent.location) &&
            success;
    success = await _saveOptionalValue(
          'next_event_travel_buffer_minutes',
          nextEvent.travelBufferMinutes,
        ) &&
        success;
    success = await _saveValue(
          'next_event_is_critical',
          nextEvent.isCritical,
        ) &&
        success;
    success = await _saveTodayEvents(todayEvents) && success;
    success = await _saveTodayScheduleData(
          lastPastEvent: lastPastEvent,
          todayUpcomingEvents:
              todayUpcomingEvents.isEmpty ? todayEvents : todayUpcomingEvents,
          tomorrowEvents: tomorrowEvents,
        ) &&
        success;
    success = await _saveMonthData(month: month, days: monthDays) && success;
    success = await _saveMonthCalendarData(monthCells) && success;
    success = await _saveWeekData(weekDays) && success;

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
      todayEvents: payload.todayUpcomingEvents,
      lastPastEvent: payload.lastPastEvent,
      todayUpcomingEvents: payload.todayUpcomingEvents,
      tomorrowEvents: payload.tomorrowEvents,
      month: payload.month,
      monthDays: payload.monthDays,
      monthCells: payload.monthCells,
      weekDays: payload.weekDays,
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
      success = await _saveOptionalValue(
            'event_list_${slot}_id',
            event?.eventId,
          ) &&
          success;
      success = await _saveOptionalValue(
            'event_list_${slot}_title',
            event?.title,
          ) &&
          success;
      success = await _saveOptionalValue(
            'event_list_${slot}_time',
            event?.startAt?.toUtc().toIso8601String(),
          ) &&
          success;
      success = await _saveOptionalValue(
            'event_list_${slot}_location',
            event?.location,
          ) &&
          success;
      success = await _saveValue(
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
    final tomorrowLimit = remainingCapacity <
            HomeWidgetSchedulePayloadBuilder.tomorrowWidgetMaxRows
        ? remainingCapacity
        : HomeWidgetSchedulePayloadBuilder.tomorrowWidgetMaxRows;
    final tomorrowSlots = tomorrowLimit <= 0
        ? const <HomeWidgetListEventData>[]
        : tomorrowEvents.take(tomorrowLimit).toList(growable: false);
    success =
        await _saveValue('today_upcoming_count', todaySlots.length) && success;
    success = await _saveValue('tomorrow_event_count', tomorrowSlots.length) &&
        success;
    for (var index = 0;
        index < HomeWidgetSchedulePayloadBuilder.todayWidgetRowCapacity;
        index += 1) {
      success = await _saveListEvent(
            'today_upcoming_${index + 1}',
            index < todaySlots.length ? todaySlots[index] : null,
          ) &&
          success;
    }
    for (var index = 0; index < 2; index += 1) {
      success = await _saveListEvent(
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
    success = await _saveValue(
          'month_title',
          '${resolvedMonth.year}년 ${resolvedMonth.month}월',
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
      success = await _saveOptionalValue(
            'month_day_${day}_summary',
            summaries[day],
          ) &&
          success;
      success = await _saveOptionalValue(
            'month_day_${day}_count',
            sourceDay?.eventCount,
          ) &&
          success;
      success = await _saveValue(
            'month_day_${day}_has_critical',
            sourceDay?.hasCritical ?? false,
          ) &&
          success;
    }

    return success;
  }

  Future<bool> _saveMonthCalendarData(
    List<HomeWidgetMonthCellData> cells,
  ) async {
    var success = true;
    final byCell = <int, HomeWidgetMonthCellData>{
      for (final cell in cells)
        if (cell.cellIndex >= 1 && cell.cellIndex <= 42) cell.cellIndex: cell,
    };
    for (var cellIndex = 1; cellIndex <= 42; cellIndex += 1) {
      final cell = byCell[cellIndex];
      success = await _saveOptionalValue(
            'month_cell_${cellIndex}_date',
            cell?.date == null
                ? null
                : _localDateKey(planflowLocal(cell!.date!)),
          ) &&
          success;
      success = await _saveOptionalValue(
            'month_cell_${cellIndex}_day',
            cell?.day,
          ) &&
          success;
      success = await _saveValue(
            'month_cell_${cellIndex}_in_month',
            cell?.inMonth ?? false,
          ) &&
          success;
      success = await _saveValue(
            'month_cell_${cellIndex}_overflow_count',
            cell?.overflowCount ?? 0,
          ) &&
          success;
      final events = cell?.events.take(3).toList(growable: false) ??
          const <HomeWidgetListEventData>[];
      for (var eventIndex = 0; eventIndex < 3; eventIndex += 1) {
        final event = eventIndex < events.length ? events[eventIndex] : null;
        final eventSlot = eventIndex + 1;
        success = await _saveOptionalValue(
              'month_cell_${cellIndex}_event_${eventSlot}_id',
              event?.eventId,
            ) &&
            success;
        success = await _saveOptionalValue(
              'month_cell_${cellIndex}_event_${eventSlot}_title',
              event?.title,
            ) &&
            success;
        success = await _saveOptionalValue(
              'month_cell_${cellIndex}_event_${eventSlot}_time',
              event?.startAt?.toUtc().toIso8601String(),
            ) &&
            success;
        success = await _saveValue(
              'month_cell_${cellIndex}_event_${eventSlot}_is_critical',
              event?.isCritical ?? false,
            ) &&
            success;
      }
    }
    return success;
  }

  Future<bool> _saveWeekData(List<HomeWidgetWeekDayData> days) async {
    var success = true;
    final slots = days.take(7).toList(growable: false);

    for (var index = 0; index < 7; index += 1) {
      final day = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success = await _saveOptionalValue(
            'week_day_${slot}_date',
            day?.date.toUtc().toIso8601String(),
          ) &&
          success;
      success = await _saveOptionalValue(
            'week_day_${slot}_summary',
            day?.summary,
          ) &&
          success;
      success = await _saveOptionalValue(
            'week_day_${slot}_count',
            day?.eventCount ?? day?.events.length,
          ) &&
          success;
      success = await _saveValue(
            'week_day_${slot}_has_critical',
            day?.hasCritical ??
                day?.events.any((event) => event.isCritical) ??
                false,
          ) &&
          success;

      final events = day?.events.take(2).toList(growable: false) ??
          const <HomeWidgetListEventData>[];
      final eventCount = day?.eventCount ?? day?.events.length ?? 0;
      success = await _saveValue(
            'week_day_${slot}_overflow_count',
            eventCount > events.length ? eventCount - events.length : 0,
          ) &&
          success;
      for (var eventIndex = 0; eventIndex < 2; eventIndex += 1) {
        final event = eventIndex < events.length ? events[eventIndex] : null;
        final eventSlot = eventIndex + 1;
        success = await _saveOptionalValue(
              'week_day_${slot}_event_${eventSlot}_id',
              event?.eventId,
            ) &&
            success;
        success = await _saveOptionalValue(
              'week_day_${slot}_event_${eventSlot}_title',
              event?.title,
            ) &&
            success;
        success = await _saveOptionalValue(
              'week_day_${slot}_event_${eventSlot}_time',
              event?.startAt?.toUtc().toIso8601String(),
            ) &&
            success;
        success = await _saveValue(
              'week_day_${slot}_event_${eventSlot}_is_critical',
              event?.isCritical ?? false,
            ) &&
            success;
      }
    }

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
    success = await _saveOptionalValue(
          '${prefix}_time',
          event?.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success = await _saveOptionalValue('${prefix}_location', event?.location) &&
        success;
    success = await _saveValue(
          '${prefix}_is_critical',
          event?.isCritical ?? false,
        ) &&
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
