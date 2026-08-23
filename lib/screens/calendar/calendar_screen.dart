import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/recurrence_expansion.dart' as recurrence_expansion;
import '../../core/responsive.dart';
import '../../core/time_format_controller.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../features/groups/models/calendar_overlay_item.dart';
import '../../features/groups/providers/group_calendar_overlay_provider.dart';
import '../../features/groups/services/group_instruction_inbox_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/event_prefetch_service.dart';
import '../../services/korean_holidays.dart';
import '../../services/synced_public_holiday_visibility.dart';
import '../../services/voice_conversation_launcher.dart';
import '../../widgets/planflow_global_fabs.dart';
import '../../widgets/planflow_logo.dart';
import 'calendar_projection.dart';
part 'calendar_widgets.dart';

enum _CalendarLoadState {
  loading,
  ready,
  supabaseMissing,
  signedOut,
  error,
}

// Calendar semantic palette. Weekday colors are applied only to date numbers;
// event colors never inherit the weekday color.
const calendarCriticalEventMarkerColor = Color(0xFF8051B2);
const calendarCriticalEventTextColor = Color(0xFF633B8E);
const calendarCriticalEventBackgroundColor = Color(0xFFE2D2F3);
const calendarNormalEventTextColor = Color(0xFF435A70);
const calendarNormalEventBackgroundColor = Color(0xFFDCE8F2);
const calendarMultiDayEventBackgroundColor = Color(0xFFDCE8C9);
const calendarMultiDayEventTextColor = Color(0xFF4B6336);
const calendarMultiDayEventBorderColor = Color(0xFF78935B);
const calendarCriticalMultiDayAccentColor = Color(0xFF8051B2);
const calendarGroupEventColor = Color(0xFF7B560B);
const calendarGroupEventBackgroundColor = Color(0xFFF4DEAA);
const calendarRecurringEventColor = Color(0xFF126E68);
const calendarRecurringEventBackgroundColor = Color(0xFFD2ECE8);
const calendarHolidayColor = Color(0xFFC62828);
const calendarSaturdayColor = Color(0xFF1E64B7);

@visibleForTesting
List<EventModel> mergeCalendarEventsAfterReload({
  required List<EventModel> previous,
  required List<EventModel> loaded,
}) {
  if (previous.isEmpty || loaded.length >= previous.length) {
    return loaded;
  }

  if (loaded.isEmpty || loaded.length == 1) {
    return <String, EventModel>{
      for (final event in previous)
        if (event.id.trim().isNotEmpty) event.id: event,
      for (final event in loaded)
        if (event.id.trim().isNotEmpty) event.id: event,
    }.values.toList(growable: false)
      ..sort(compareCalendarEventsForDisplay);
  }

  return loaded;
}

@visibleForTesting
int compareCalendarEventsForDisplay(EventModel a, EventModel b) {
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
  final byTime = aStart.compareTo(bStart);
  return byTime == 0 ? a.title.compareTo(b.title) : byTime;
}

@visibleForTesting
bool calendarEventSpansMultipleLocalDays(EventModel event) {
  final startAt = event.startAt;
  final endAt = event.endAt;
  if (startAt == null || endAt == null) {
    return false;
  }
  return planflowLocalDay(startAt) != _calendarDisplayEndDay(startAt, endAt);
}

DateTime _calendarDisplayEndDay(DateTime startAt, DateTime endAt) {
  var localEnd = planflowLocal(endAt);
  if (endAt.isAfter(startAt) &&
      localEnd.hour == 0 &&
      localEnd.minute == 0 &&
      localEnd.second == 0 &&
      localEnd.millisecond == 0 &&
      localEnd.microsecond == 0) {
    localEnd = localEnd.subtract(const Duration(microseconds: 1));
  }
  // localEnd는 이미 로컬 시간이므로 planflowLocalDay (내부에서 planflowLocal 재호출)
  // 대신 날짜 부분만 직접 추출하여 이중 timezone 변환 방지
  return DateTime(localEnd.year, localEnd.month, localEnd.day);
}

@visibleForTesting
Map<int, Color> buildCalendarEventMarkerColorsByDay({
  required Iterable<EventModel> events,
  required DateTime focusedMonth,
}) {
  final markerColors = <int, Color>{};
  final monthStart = DateTime(focusedMonth.year, focusedMonth.month);
  final monthEnd = DateTime(focusedMonth.year, focusedMonth.month + 1);
  for (final event in events) {
    final rawStartAt = event.startAt;
    if (rawStartAt == null) {
      continue;
    }
    final startAt = planflowLocal(rawStartAt);
    final rawEndAt = event.endAt ?? rawStartAt;
    final eventEndDay = _calendarDisplayEndDay(rawStartAt, rawEndAt);
    final eventEnd = DateTime(
      eventEndDay.year,
      eventEndDay.month,
      eventEndDay.day,
      23,
      59,
      59,
    );
    if (!startAt.isBefore(monthEnd) || eventEnd.isBefore(monthStart)) {
      continue;
    }
    // startAt은 이미 planflowLocal() 결과이므로 planflowLocalDay(startAt) 대신
    // 날짜 부분만 직접 추출 (이중 timezone 변환 방지)
    final firstDay = startAt.isBefore(monthStart)
        ? monthStart
        : DateTime(startAt.year, startAt.month, startAt.day);
    final lastDay = !eventEnd.isBefore(monthEnd)
        ? monthEnd.subtract(const Duration(days: 1))
        : eventEndDay;
    for (var day = firstDay;
        !day.isAfter(lastDay);
        day = day.add(const Duration(days: 1))) {
      final currentColor = markerColors[day.day];
      if (event.isCritical ||
          currentColor != calendarCriticalEventMarkerColor) {
        markerColors[day.day] = event.isCritical
            ? calendarCriticalEventMarkerColor
            : PlanFlowColors.active;
      }
    }
  }
  return markerColors;
}

const _calendarMiniMonthEventRows = 4;
const _calendarMiniEventRowHeight = 10.0;

const _holidayTitleKeywords = <String>[
  '공휴일',
  '대체공휴일',
  '임시공휴일',
  '신정',
  '설날',
  '추석',
  '삼일절',
  '어린이날',
  '현충일',
  '광복절',
  '개천절',
  '한글날',
  '성탄절',
  '부처님오신날',
  '석가탄신일',
  '휴일',
  // 주의: '제헌절'은 여기 넣지 않는다. 2008년부터 비휴무 국경일이라
  // 동기화된 캘린더 이벤트 제목에 "제헌절"이 있어도 날짜를 빨간색(휴무)으로
  // 칠하면 안 된다(KoreanHolidays.holidayName은 이름 표시용으로 별도 처리).
];

String _normalizeHolidayTitle(String title) {
  return title.replaceAll(RegExp(r'\s+'), '').toLowerCase();
}

bool _looksLikeHolidayTitle(String title) {
  final normalized = _normalizeHolidayTitle(title);
  if (normalized.isEmpty) {
    return false;
  }
  return _holidayTitleKeywords.any((keyword) {
    final normalizedKeyword = _normalizeHolidayTitle(keyword);
    return normalized.contains(normalizedKeyword);
  });
}

List<EventModel> _eventsForLocalDay(
  Iterable<EventModel> events,
  DateTime day,
) {
  final result = <EventModel>[];
  for (final event in events) {
    if (isSyncedPublicHolidayDuplicate(event)) {
      continue;
    }
    final startAt = event.startAt;
    if (startAt == null) {
      continue;
    }
    if (planflowEventIntersectsLocalDay(
      startAt: startAt,
      endAt: event.endAt,
      day: day,
    )) {
      result.add(event);
    }
  }
  result.sort(compareCalendarEventsForDisplay);
  return result;
}

@visibleForTesting
class CalendarMiniMonthCellData {
  const CalendarMiniMonthCellData({
    required this.index,
    required this.date,
    required this.dayNumber,
    required this.inMonth,
    required this.events,
    required this.overlayEvents,
    required this.overflowCount,
    required this.isHoliday,
    this.holidayName,
    this.leadingEventRowCount = 0,
  });

  final int index;
  final DateTime? date;
  final int? dayNumber;
  final bool inMonth;
  final List<EventModel> events;
  final List<CalendarOverlayItem> overlayEvents;
  final int overflowCount;
  final bool isHoliday;
  final String? holidayName;

  /// Empty rows reserved before a multi-day band so it stays aligned with a
  /// holiday row on another day in the same span.
  final int leadingEventRowCount;
}

@visibleForTesting
List<CalendarMiniMonthCellData> buildCalendarMiniMonthCells({
  required Iterable<EventModel> events,
  required DateTime focusedMonth,
  Iterable<CalendarOverlayItem> overlayEvents = const <CalendarOverlayItem>[],
}) {
  final monthStart = DateTime(focusedMonth.year, focusedMonth.month);
  final firstDayOfMonth = monthStart;
  final lastDay = DateTime(focusedMonth.year, focusedMonth.month + 1, 0).day;
  final startWeekday = firstDayOfMonth.weekday % 7;
  final rowCount = ((startWeekday + lastDay + 6) ~/ 7).clamp(1, 6).toInt();
  final cellCount = rowCount * 7;
  final slotMap = List.generate(
    cellCount,
    (_) => List<EventModel?>.filled(
      _calendarMiniMonthEventRows,
      null,
      growable: false,
    ),
  );
  final overflowCounts = List<int>.filled(cellCount, 0);
  final overlayItemsByCell = List<List<CalendarOverlayItem>>.generate(
    cellCount,
    (_) => <CalendarOverlayItem>[],
    growable: false,
  );
  final cellDates = List<DateTime?>.generate(cellCount, (index) {
    final dayNumber = index - startWeekday + 1;
    if (dayNumber < 1 || dayNumber > lastDay) {
      return null;
    }
    return DateTime(monthStart.year, monthStart.month, dayNumber);
  }, growable: false);

  final visibleOverlayEvents = overlayEvents.where((event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final endAt = event.endAt ?? startAt;
    final overlayMonthStart = DateTime(focusedMonth.year, focusedMonth.month);
    final overlayMonthEnd = DateTime(focusedMonth.year, focusedMonth.month + 1);
    final localStart = planflowLocalDay(startAt);
    final localEnd = planflowLocalDay(endAt);
    return !localStart.isAfter(overlayMonthEnd) &&
        !localEnd.isBefore(overlayMonthStart);
  }).toList(growable: false)
    ..sort((a, b) {
      final aStart = a.startAt ?? DateTime(0);
      final bStart = b.startAt ?? DateTime(0);
      final byStart = aStart.compareTo(bStart);
      if (byStart != 0) {
        return byStart;
      }
      return a.title.compareTo(b.title);
    });

  // The mini calendar has its own slot allocator, so filtering only in the
  // selected-day list is too late: an imported holiday could still consume a
  // visible slot or overflow count here.
  final sortedEvents = events
      .where((event) => !isSyncedPublicHolidayDuplicate(event))
      .where((event) => event.startAt != null)
      .toList(growable: false)
    ..sort(compareCalendarEventsForDisplay);

  final multiDayEvents = sortedEvents.where((event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final firstDay = planflowLocalDay(startAt);
    final lastEventDay =
        _calendarDisplayEndDay(startAt, event.endAt ?? startAt);
    return lastEventDay.isAfter(firstDay);
  }).toList(growable: false);

  for (final event in multiDayEvents) {
    final startAt = event.startAt;
    if (startAt == null) {
      continue;
    }
    final firstDay = planflowLocalDay(startAt);
    final lastEventDay =
        _calendarDisplayEndDay(startAt, event.endAt ?? startAt);
    final cellIndices = <int>[
      for (var i = 0; i < cellDates.length; i += 1)
        if (cellDates[i] != null &&
            !cellDates[i]!.isBefore(firstDay) &&
            !cellDates[i]!.isAfter(lastEventDay))
          i,
    ];
    if (cellIndices.isEmpty) {
      continue;
    }

    final spanContainsHoliday = cellIndices.any((index) {
      final day = cellDates[index];
      return day != null && KoreanHolidays.holidayName(day) != null;
    });
    var reserved = false;
    for (var slot = spanContainsHoliday ? 1 : 0;
        slot < _calendarMiniMonthEventRows;
        slot += 1) {
      if (cellIndices.every((index) => slotMap[index][slot] == null)) {
        for (final index in cellIndices) {
          slotMap[index][slot] = event;
        }
        reserved = true;
        break;
      }
    }
    if (!reserved) {
      for (final index in cellIndices) {
        overflowCounts[index] += 1;
      }
    }
  }

  for (var index = 0; index < cellDates.length; index += 1) {
    final day = cellDates[index];
    if (day == null) {
      continue;
    }
    final singleEvents = sortedEvents.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final firstDay = planflowLocalDay(startAt);
      final lastEventDay =
          _calendarDisplayEndDay(startAt, event.endAt ?? startAt);
      return !lastEventDay.isAfter(firstDay) && firstDay == day;
    }).toList(growable: false);
    for (final event in singleEvents) {
      var placed = false;
      final firstAvailableSlot =
          KoreanHolidays.holidayName(day) != null ? 1 : 0;
      for (var slot = firstAvailableSlot;
          slot < _calendarMiniMonthEventRows;
          slot += 1) {
        if (slotMap[index][slot] == null) {
          slotMap[index][slot] = event;
          placed = true;
          break;
        }
      }
      if (!placed) {
        overflowCounts[index] += 1;
      }
    }
  }

  for (final event in visibleOverlayEvents) {
    for (var index = 0; index < cellDates.length; index += 1) {
      final day = cellDates[index];
      if (day == null || !event.spansLocalDay(day)) {
        continue;
      }
      overlayItemsByCell[index].add(event);
    }
  }

  return List.generate(cellCount, (index) {
    final day = cellDates[index];
    final visibleEvents =
        slotMap[index].whereType<EventModel>().toList(growable: false);
    final holidayName = day == null ? null : KoreanHolidays.holidayName(day);
    final firstOccupiedSlot =
        slotMap[index].indexWhere((event) => event != null);
    return CalendarMiniMonthCellData(
      index: index,
      date: day,
      dayNumber: day?.day,
      inMonth: day != null &&
          day.year == monthStart.year &&
          day.month == monthStart.month,
      events: visibleEvents,
      overlayEvents: overlayItemsByCell[index],
      overflowCount: overflowCounts[index],
      isHoliday: day != null &&
          (KoreanHolidays.isDayOff(day) ||
              _eventsForLocalDay(sortedEvents, day)
                  .any((event) => _looksLikeHolidayTitle(event.title))),
      holidayName: holidayName,
      leadingEventRowCount:
          holidayName == null && firstOccupiedSlot > 0 ? firstOccupiedSlot : 0,
    );
  }, growable: false);
}

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    this.initialDate,
    this.eventRepository,
    this.userId,
    this.groupCalendarOverlayProvider,
  });

  final DateTime? initialDate;
  final EventRepository? eventRepository;
  final String? userId;
  final GroupCalendarOverlayProvider? groupCalendarOverlayProvider;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarMonthProjection {
  const _CalendarMonthProjection({
    required this.visibleEvents,
    required this.cells,
    required this.dayEvents,
  });

  final List<EventModel> visibleEvents;
  final List<CalendarMiniMonthCellData> cells;
  final Map<int, List<EventModel>> dayEvents;
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _selectedDate;
  late DateTime _focusedMonth;
  List<EventModel> _allEvents = const <EventModel>[];
  List<EventModel> _visibleEventsCache = const <EventModel>[];
  List<CalendarOverlayItem> _visibleGroupOverlayEventsCache =
      const <CalendarOverlayItem>[];
  List<CalendarMiniMonthCellData> _miniMonthCellsCache =
      const <CalendarMiniMonthCellData>[];
  List<EventModel> _selectedDateEventsCache = const <EventModel>[];
  List<CalendarOverlayItem> _selectedDateGroupEventsCache =
      const <CalendarOverlayItem>[];
  final Map<String, _CalendarMonthProjection> _monthProjectionCache =
      <String, _CalendarMonthProjection>{};
  GroupCalendarOverlayProvider? _groupOverlayProvider;

  /// 미확인 리더 지시가 있는 개인 이벤트 id 집합
  Set<String> _instructionEventIds = const <String>{};
  _CalendarLoadState _loadState = _CalendarLoadState.ready;
  String? _loadMessage;
  bool _isSearching = false;
  bool _isRefreshing = false;
  bool _hasPendingRefresh = false;
  int _monthNavigationGeneration = 0;
  int _calendarInputRevision = 0;
  DateTime? _pendingFocusDate;
  DateTime? _pendingOpenDaySheetDate;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialDate = widget.initialDate ?? DateTime.now();
    _selectedDate = initialDate;
    _focusedMonth = DateTime(initialDate.year, initialDate.month);
    _miniMonthCellsCache = buildCalendarMiniMonthCells(
      events: const <EventModel>[],
      focusedMonth: _focusedMonth,
    );
    _pendingOpenDaySheetDate = widget.initialDate;
    EventRefreshBus.instance.latest.addListener(_handleEventRefresh);
    _searchController.addListener(_handleSearchChanged);
    _seedPrefetchedEvents();
    _loadEvents(focusDate: widget.initialDate);
  }

  void _seedPrefetchedEvents() {
    final userId = _resolveCalendarUserId();
    if (userId == null || userId.isEmpty) return;
    final cached = EventPrefetchService().getCached(userId);
    if (cached == null) return;
    _allEvents = cached;
    _loadState = _CalendarLoadState.ready;
    final projection = _projectionForMonth(_focusedMonth);
    _visibleEventsCache = projection.visibleEvents;
    _miniMonthCellsCache = projection.cells;
    _selectedDateEventsCache =
        projection.dayEvents[_selectedDate.day] ?? const <EventModel>[];
  }

  @override
  void didUpdateWidget(covariant CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextDate = widget.initialDate;
    if (oldWidget.initialDate == nextDate) {
      return;
    }
    if (nextDate == null) {
      final today = DateTime.now();
      setState(() {
        _selectedDate = today;
        _focusedMonth = DateTime(today.year, today.month);
      });
      _refreshCalendarViewCache();
      return;
    }
    _pendingOpenDaySheetDate = nextDate;
    unawaited(_loadEvents(focusDate: nextDate));
  }

  @override
  void dispose() {
    EventRefreshBus.instance.latest.removeListener(_handleEventRefresh);
    _groupOverlayProvider?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String? get _selectedDateHolidayName =>
      KoreanHolidays.holidayName(_selectedDate);

  void _handleSearchChanged() {
    if (!mounted) {
      return;
    }
    _calendarInputRevision += 1;
    _monthProjectionCache.clear();
    _refreshCalendarViewCache();
  }

  String _monthCacheKey(DateTime month) =>
      '${month.year}-${month.month}-${_searchController.text.trim().toLowerCase()}';

  _CalendarMonthProjection _projectionForMonth(DateTime month) {
    final key = _monthCacheKey(month);
    final cached = _monthProjectionCache[key];
    if (cached != null) return cached;
    final visibleEvents = _computeVisibleEvents(month: month);
    final projection = _CalendarMonthProjection(
      visibleEvents: visibleEvents,
      cells: buildCalendarMiniMonthCells(
        events: visibleEvents,
        focusedMonth: month,
      ),
      dayEvents: buildCalendarDayEventIndex(
        events: visibleEvents,
        focusedMonth: month,
      ),
    );
    _monthProjectionCache[key] = projection;
    return projection;
  }

  Future<_CalendarMonthProjection?> _projectionForMonthInChunks(
    DateTime month, {
    required int expectedGeneration,
    required int expectedInputRevision,
  }) async {
    final key = _monthCacheKey(month);
    final cached = _monthProjectionCache[key];
    if (cached != null) return cached;
    bool isCurrent() =>
        mounted &&
        expectedGeneration == _monthNavigationGeneration &&
        expectedInputRevision == _calendarInputRevision;
    if (!isCurrent()) return null;
    final monthStart = DateTime(month.year, month.month);
    final monthEnd =
        DateTime(month.year, month.month + 1, 0).add(const Duration(days: 1));
    final expanded = <EventModel>[];
    final source = _filteredEvents;
    const chunkSize = 64;
    for (var offset = 0; offset < source.length; offset += chunkSize) {
      if (!isCurrent()) return null;
      final end = (offset + chunkSize).clamp(0, source.length);
      for (final event in source.sublist(offset, end)) {
        expanded.addAll(
          _expandRecurringEvent(
            event,
            rangeStart: monthStart,
            rangeEnd: monthEnd,
          ),
        );
      }
      // Give the renderer a chance to paint month navigation and receive a
      // newer tap before continuing the projection.
      await Future<void>.delayed(Duration.zero);
      if (!isCurrent()) return null;
    }
    final visible = _hideOverriddenRecurringOccurrences(expanded)
      ..removeWhere(isSyncedPublicHolidayDuplicate)
      ..sort(
        (a, b) =>
            (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)),
      );
    if (!isCurrent()) return null;
    await Future<void>.delayed(Duration.zero);
    if (!isCurrent()) return null;
    final cells = buildCalendarMiniMonthCells(
      events: visible,
      focusedMonth: month,
    );
    if (!isCurrent()) return null;
    await Future<void>.delayed(Duration.zero);
    if (!isCurrent()) return null;
    final dayEvents = buildCalendarDayEventIndex(
      events: visible,
      focusedMonth: month,
    );
    if (!isCurrent()) return null;
    final projection = _CalendarMonthProjection(
      visibleEvents: visible,
      cells: cells,
      dayEvents: dayEvents,
    );
    _monthProjectionCache[key] = projection;
    return projection;
  }

  void _handleEventRefresh() {
    final signal = EventRefreshBus.instance.latest.value;
    unawaited(_loadEvents(focusDate: signal?.startAt));
  }

  void _refreshCalendarViewCache({bool includeOverlayEvents = true}) {
    final projection = _projectionForMonth(_focusedMonth);
    final visibleEvents = projection.visibleEvents;
    final visibleGroupOverlayEvents = includeOverlayEvents
        ? _computeVisibleGroupOverlayEvents(visibleEvents)
        : const <CalendarOverlayItem>[];
    final miniMonthCells = visibleGroupOverlayEvents.isEmpty
        ? projection.cells
        : buildCalendarMiniMonthCells(
            events: visibleEvents,
            focusedMonth: _focusedMonth,
            overlayEvents: visibleGroupOverlayEvents,
          );
    final selectedDayEvents = _selectedDate.year == _focusedMonth.year &&
            _selectedDate.month == _focusedMonth.month
        ? projection.dayEvents[_selectedDate.day] ?? const <EventModel>[]
        : _eventsForLocalDay(visibleEvents, _selectedDate);
    final selectedGroupEvents = visibleGroupOverlayEvents
        .where((event) => event.spansLocalDay(_selectedDate))
        .toList(growable: false);

    if (!mounted) {
      return;
    }
    setState(() {
      _visibleEventsCache = visibleEvents;
      _visibleGroupOverlayEventsCache = visibleGroupOverlayEvents;
      _miniMonthCellsCache = miniMonthCells;
      _selectedDateEventsCache = selectedDayEvents;
      _selectedDateGroupEventsCache = selectedGroupEvents;
    });
  }

  List<EventModel> _computeVisibleEvents({DateTime? month}) {
    final targetMonth = month ?? _focusedMonth;
    final monthStart = DateTime(targetMonth.year, targetMonth.month);
    final monthEnd = DateTime(targetMonth.year, targetMonth.month + 1, 0)
        .add(const Duration(days: 1));
    final expanded = <EventModel>[];
    for (final event in _filteredEvents) {
      expanded.addAll(
        _expandRecurringEvent(
          event,
          rangeStart: monthStart,
          rangeEnd: monthEnd,
        ),
      );
    }
    final visible = _hideOverriddenRecurringOccurrences(expanded);
    visible.removeWhere(isSyncedPublicHolidayDuplicate);
    visible.sort(
      (a, b) => (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)),
    );
    return visible;
  }

  List<CalendarOverlayItem> _computeVisibleGroupOverlayEvents(
    List<EventModel> visibleEvents,
  ) {
    final groupOverlayProvider = _groupOverlayProvider;
    if (groupOverlayProvider == null) {
      return const <CalendarOverlayItem>[];
    }
    final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month);
    final monthEnd = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    final linkedGroupEventIds = visibleEvents
        .map((event) => event.groupEventId)
        .whereType<String>()
        .toSet();
    return groupOverlayProvider.items.where((event) {
      final start = event.startAt;
      if (start == null) {
        return false;
      }
      if (event.isGroup && linkedGroupEventIds.contains(event.id)) {
        return false;
      }
      final localStart = planflowLocalDay(start);
      final localEnd = planflowLocalDay(event.endAt ?? start);
      return !localStart.isAfter(monthEnd) && !localEnd.isBefore(monthStart);
    }).toList(growable: false)
      ..sort((a, b) {
        final aStart = a.startAt ?? DateTime(0);
        final bStart = b.startAt ?? DateTime(0);
        final byStart = aStart.compareTo(bStart);
        if (byStart != 0) {
          return byStart;
        }
        return a.title.compareTo(b.title);
      });
  }

  void _updateSelectedDateCache(DateTime day) {
    final projection =
        day.year == _focusedMonth.year && day.month == _focusedMonth.month
            ? _monthProjectionCache[_monthCacheKey(_focusedMonth)]
            : null;
    final selectedEvents = projection?.dayEvents[day.day] ??
        (day.year == _focusedMonth.year && day.month == _focusedMonth.month
            ? _eventsForLocalDay(_visibleEventsCache, day)
            : const <EventModel>[]);
    final selectedGroupEvents = _visibleGroupOverlayEventsCache
        .where((event) => event.spansLocalDay(day))
        .toList(growable: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedDate = day;
      _selectedDateEventsCache = selectedEvents;
      _selectedDateGroupEventsCache = selectedGroupEvents;
    });
  }

  Future<void> _loadEvents({DateTime? focusDate}) async {
    if (_isRefreshing) {
      _hasPendingRefresh = true;
      _pendingFocusDate = focusDate ?? _pendingFocusDate;
      debugPrint(
        'CalendarScreen reload queued while refreshing: '
        'focusDate=$focusDate',
      );
      return;
    }

    if (mounted) {
      setState(() {
        _isRefreshing = true;
        if (focusDate != null) {
          _selectedDate = focusDate;
          _focusedMonth = DateTime(focusDate.year, focusDate.month);
        }
      });
    }

    final repositoryOverride = widget.eventRepository;
    final explicitUserId = widget.userId?.trim();
    final canUseInjectedRepository = repositoryOverride != null &&
        explicitUserId != null &&
        explicitUserId.isNotEmpty;

    if (!canUseInjectedRepository && !AppEnv.isSupabaseReady) {
      if (mounted) {
        setState(() {
          _loadState = _CalendarLoadState.supabaseMissing;
          _loadMessage = null;
        });
      }
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
      return;
    }
    final user = canUseInjectedRepository
        ? null
        : Supabase.instance.client.auth.currentUser;
    final userId = canUseInjectedRepository ? explicitUserId : user?.id;
    if (userId == null || userId.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _loadState = _CalendarLoadState.signedOut;
          _loadMessage = null;
        });
      }
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
      return;
    }

    try {
      final repository = repositoryOverride ?? EventRepository.supabase();
      final events = await repository.listEvents(userId: userId);
      // Apply the same suspiciously-small-response protection used by the
      // visible calendar before publishing a new prefetch snapshot. A
      // transient empty/partial response must never poison the cache that a
      // later CalendarScreen instance uses for its first frame.
      final displayEvents = _eventsForDisplayAfterReload(events);
      EventPrefetchService().store(userId, displayEvents);
      var shouldOpenDaySheet = false;
      var daySheetDate = focusDate;
      if (mounted) {
        setState(() {
          _allEvents = displayEvents;
          _calendarInputRevision += 1;
          // Loaded data changes the projection inputs; never reuse a month
          // computed from the previous repository snapshot.
          _monthProjectionCache.clear();
          if (focusDate != null) {
            _selectedDate = focusDate;
            _focusedMonth = DateTime(focusDate.year, focusDate.month);
          }
          if (focusDate != null &&
              _isSameLocalDate(_pendingOpenDaySheetDate, focusDate)) {
            shouldOpenDaySheet = true;
            daySheetDate = focusDate;
            _pendingOpenDaySheetDate = null;
          }
          _loadState = _CalendarLoadState.ready;
          _loadMessage = null;
        });
      }
      _refreshCalendarViewCache(includeOverlayEvents: false);
      // Personal events are the critical path. Group overlays and badges are
      // independent decorations and must not delay the first useful calendar
      // frame or each other.
      final groupOverlayFuture = _loadGroupOverlay(userId: userId);
      unawaited(groupOverlayFuture);
      unawaited(_loadGroupInstructionBadges(userId));
      if (shouldOpenDaySheet && daySheetDate != null && mounted) {
        // The calendar frame is already visible. Only an explicitly opened
        // day sheet waits for its group decoration so it never opens empty.
        await groupOverlayFuture;
        if (!mounted) return;
        final personalEvents = List<EventModel>.of(_selectedDateEventsCache);
        final groupEvents = List<CalendarOverlayItem>.of(
          _selectedDateGroupEventsCache,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showDayEventsSheet(
              daySheetDate!,
              personalEvents: personalEvents,
              groupEvents: groupEvents,
            );
          }
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadState = _CalendarLoadState.error;
          _loadMessage = '캘린더 일정을 불러오지 못했어요. 다시 시도해 주세요.';
        });
      }
      debugPrint('CalendarScreen load failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
      if (_hasPendingRefresh) {
        final pendingFocusDate = _pendingFocusDate;
        _hasPendingRefresh = false;
        _pendingFocusDate = null;
        debugPrint(
          'CalendarScreen running queued reload: '
          'focusDate=$pendingFocusDate',
        );
        unawaited(_loadEvents(focusDate: pendingFocusDate));
      }
    }
  }

  bool _isSameLocalDate(DateTime? a, DateTime? b) {
    if (a == null || b == null) {
      return false;
    }
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  List<EventModel> _eventsForDisplayAfterReload(List<EventModel> loaded) {
    final merged = mergeCalendarEventsAfterReload(
      previous: _allEvents,
      loaded: loaded,
    );

    if (identical(merged, loaded)) {
      debugPrint('CalendarScreen reload success: events=${loaded.length}');
      return loaded;
    }

    if (loaded.isEmpty || loaded.length == 1) {
      debugPrint(
        'CalendarScreen preserved previous list after suspiciously small '
        'reload: previous=${_allEvents.length} loaded=${loaded.length} '
        'merged=${merged.length}',
      );
      return merged;
    }

    debugPrint(
      'CalendarScreen reload success with smaller list: '
      'previous=${_allEvents.length} loaded=${loaded.length}',
    );
    return loaded;
  }

  List<EventModel> get _eventsForSelectedDate {
    return _selectedDateEventsCache;
  }

  List<CalendarOverlayItem> get _overlayEventsForSelectedDate {
    return _selectedDateGroupEventsCache;
  }

  List<CalendarMiniMonthCellData> get _miniMonthCells {
    return _miniMonthCellsCache;
  }

  /// 미확인 리더 지시가 있는 개인 이벤트 id 를 로드해 badge 표시에 사용한다.
  Future<void> _loadGroupInstructionBadges(String userId) async {
    // Supabase 미초기화(테스트 등)면 스킵 — _loadGroupOverlay와 동일 가드.
    if (!AppEnv.isSupabaseReady) return;
    try {
      final service = GroupInstructionInboxService();
      final ids = await service.unconfirmedPersonalEventIds(userId: userId);
      if (mounted) {
        setState(() {
          _instructionEventIds = ids;
        });
      }
      // 새 지시 알림 (best-effort) — 같은 서비스 인스턴스 재사용.
      unawaited(service.notifyNewInstructions(userId: userId));
    } catch (error, stackTrace) {
      debugPrint('CalendarScreen 리더 지시 badge 로드 실패: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _loadGroupOverlay({
    String? userId,
    DateTime? requestedMonth,
    int? requestedGeneration,
  }) async {
    final loadMonth = requestedMonth ?? _focusedMonth;
    final loadKey = _monthCacheKey(loadMonth);
    try {
      if (!AppEnv.isSupabaseReady &&
          widget.groupCalendarOverlayProvider == null) {
        _groupOverlayProvider?.clear();
        _refreshCalendarViewCache(includeOverlayEvents: false);
        return;
      }
      _groupOverlayProvider ??=
          widget.groupCalendarOverlayProvider ?? GroupCalendarOverlayProvider();
      final resolvedUserId = userId ?? _resolveCalendarUserId();
      if (resolvedUserId == null || resolvedUserId.isEmpty) {
        await _groupOverlayProvider!.clear();
        _refreshCalendarViewCache(includeOverlayEvents: false);
        return;
      }
      await _groupOverlayProvider!.loadForMonth(resolvedUserId, loadMonth);
      if (!mounted ||
          (requestedGeneration != null &&
              requestedGeneration != _monthNavigationGeneration) ||
          loadKey != _monthCacheKey(_focusedMonth)) {
        return;
      }
      _refreshCalendarViewCache();
    } catch (error, stackTrace) {
      // 그룹 오버레이 로드 실패가 개인 일정 로드 흐름(_loadEvents의 재시도
      // 로직)에 영향을 주지 않도록 여기서 흡수한다.
      debugPrint('CalendarScreen 그룹 오버레이 로드 실패: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String? _resolveCalendarUserId() {
    final explicitUserId = widget.userId?.trim();
    if (explicitUserId != null && explicitUserId.isNotEmpty) {
      return explicitUserId;
    }
    // CalendarScreen is also used in isolated widget tests and during the
    // pre-auth shell. Supabase.instance asserts before initialization, so do
    // not touch the singleton until the app environment says it is ready.
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return Supabase.instance.client.auth.currentUser?.id;
  }

  List<EventModel> get _filteredEvents {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _allEvents;
    }
    return _allEvents.where((event) {
      final searchable = <String>[
        event.title,
        event.location ?? '',
        event.memo ?? '',
        event.category,
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList(growable: false);
  }

  // lib/core/recurrence_expansion.dart의 공용 유틸로 위임한다(순수 리팩터,
  // 동작 동일 — 예외 이벤트가 대체하는 원본 회차 날짜(overriddenOccurrenceDate)로
  // 매칭하는 로직 그대로 유지).
  List<EventModel> _hideOverriddenRecurringOccurrences(
    List<EventModel> events,
  ) {
    return recurrence_expansion.hideOverriddenRecurringOccurrences(events);
  }

  // lib/core/recurrence_expansion.dart의 공용 유틸로 위임한다(순수 리팩터,
  // 동작 동일). 그 유틸은 "범위 안에 회차가 없으면 anchor 이벤트를 그대로
  // 반환"하는 폴백을 의도적으로 제외했으므로(문서 참조) 여기 호출부에서
  // 원래 동작대로 재적용한다.
  List<EventModel> _expandRecurringEvent(
    EventModel event, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) {
    final occurrences = recurrence_expansion.expandRecurringEvent(
      event: event,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      includeOccurrence: _eventIntersectsRange,
    );
    return occurrences.isEmpty ? <EventModel>[event] : occurrences;
  }

  // 캘린더 화면 전용 술어: _calendarDisplayEndDay(화면 표시용 종료일 보정)
  // 기반이라 공용 유틸의 기본 판정과 다르다 — 유틸의 includeOccurrence
  // 콜백으로 그대로 주입해서 쓴다(공용 유틸 문서 참조).
  bool _eventIntersectsRange(
    EventModel event,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final localDisplayEnd =
        _calendarDisplayEndDay(startAt, event.endAt ?? startAt);
    final eventDisplayEndExclusive = DateTime(
      localDisplayEnd.year,
      localDisplayEnd.month,
      localDisplayEnd.day + 1,
    );
    return planflowLocal(startAt).isBefore(rangeEnd) &&
        eventDisplayEndExclusive.isAfter(rangeStart);
  }

  void _showDayEventsSheet(
    DateTime day, {
    List<EventModel>? personalEvents,
    List<CalendarOverlayItem>? groupEvents,
  }) {
    final events = personalEvents ?? _selectedDateEventsCache;
    final resolvedGroupEvents = groupEvents ?? _selectedDateGroupEventsCache;
    final groupOverlayProvider = _groupOverlayProvider;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: PlanFlowColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        key: const ValueKey('calendar-day-events-draggable-sheet'),
        expand: false,
        initialChildSize: 0.84,
        minChildSize: 0.58,
        maxChildSize: 0.97,
        builder: (context, scrollController) {
          Widget sheetBuilder() {
            return DayEventsSheet(
              day: day,
              personalEvents: events,
              groupEvents: resolvedGroupEvents,
              scrollController: scrollController,
              holidayName: KoreanHolidays.holidayName(day),
              isDayOff: KoreanHolidays.isDayOff(day),
              onAdd: () {
                Navigator.of(context).pop();
                context.push(_eventEditRouteForDay(day));
              },
              onVoice: () {
                Navigator.of(context).pop();
                context.push(AppRoutes.voice);
              },
              onEventTap: (event) {
                Navigator.of(context).pop();
                context.push(
                  '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                  extra: event,
                );
              },
              onGroupEventTap: (event) {
                Navigator.of(context).pop();
                context.push(
                  '${AppRoutes.groupEvents}/${Uri.encodeComponent(event.id)}',
                );
              },
            );
          }

          if (groupOverlayProvider == null) {
            return sheetBuilder();
          }
          return AnimatedBuilder(
            animation: groupOverlayProvider,
            builder: (context, _) => sheetBuilder(),
          );
        },
      ),
    );
  }

  void _changeMonth(int delta) {
    final nextMonth = DateTime(
      _focusedMonth.year,
      _focusedMonth.month + delta,
    );
    final generation = ++_monthNavigationGeneration;
    final inputRevision = _calendarInputRevision;
    setState(() {
      _focusedMonth = nextMonth;
      _visibleEventsCache = const <EventModel>[];
      _visibleGroupOverlayEventsCache = const <CalendarOverlayItem>[];
      _selectedDateGroupEventsCache = const <CalendarOverlayItem>[];
      _selectedDateEventsCache = const <EventModel>[];
      _miniMonthCellsCache = buildCalendarMiniMonthCells(
        events: const <EventModel>[],
        focusedMonth: nextMonth,
      );
    });
    // Yield the month-transition frame before recurrence expansion and slot
    // allocation. This keeps rapid month taps responsive even with thousands
    // of events; stale projections are discarded by the generation check.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _monthNavigationGeneration) return;
      final projection = await _projectionForMonthInChunks(
        nextMonth,
        expectedGeneration: generation,
        expectedInputRevision: inputRevision,
      );
      if (projection == null ||
          !mounted ||
          generation != _monthNavigationGeneration ||
          inputRevision != _calendarInputRevision) {
        return;
      }
      setState(() {
        _visibleEventsCache = projection.visibleEvents;
        _miniMonthCellsCache = projection.cells;
        if (_selectedDate.year == nextMonth.year &&
            _selectedDate.month == nextMonth.month) {
          _selectedDateEventsCache =
              projection.dayEvents[_selectedDate.day] ?? const <EventModel>[];
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          generation == _monthNavigationGeneration &&
          inputRevision == _calendarInputRevision) {
        unawaited(
          _loadGroupOverlay(
            requestedMonth: nextMonth,
            requestedGeneration: generation,
          ),
        );
      }
    });
  }

  void _handleMonthSwipe(DragEndDetails details) {
    final velocityX = details.primaryVelocity ?? 0;
    if (velocityX.abs() < 250) {
      return;
    }
    if (velocityX < 0) {
      _changeMonth(1);
    } else {
      _changeMonth(-1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = '${_focusedMonth.year}년 ${_focusedMonth.month}월';
    final selectedDateLabel = _koreanDateLabel(_selectedDate);
    final dayEvents = _eventsForSelectedDate;
    final groupDayEvents = _overlayEventsForSelectedDate;
    final totalDayEventCount = dayEvents.length + groupDayEvents.length;
    final selectedGroupLabel =
        _groupOverlayProvider?.selectedGroup?.name ?? '개인 모드';

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const PlanFlowLogo(),
        actions: [
          IconButton(
            tooltip: _isSearching ? '검색 닫기' : '일정 검색',
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                }
              });
            },
            icon: Icon(_isSearching ? Icons.close : Icons.search),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: () => _loadEvents(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: PlanFlowGlobalFabs(
        onVoice: () => context.push(AppRoutes.voice),
        onAiConversation: () => VoiceConversationLauncher.open(
          context,
          userIdOverride: widget.userId,
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _loadEvents(),
          child: ResponsiveContent(
            maxWidth: context.planflowWindowInfo.wideContentMaxWidth,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useTwoPane = constraints.maxWidth >=
                        PlanFlowResponsive.twoPaneBreakpoint &&
                    MediaQuery.sizeOf(context).height >=
                        PlanFlowResponsive.minimumTwoPaneHeight;
                final calendarPane = GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragEnd: _handleMonthSwipe,
                  child: Column(
                    children: [
                      _MonthHeader(
                        monthLabel: monthLabel,
                        onPrevious: () => _changeMonth(-1),
                        onNext: () => _changeMonth(1),
                        onToday: () {
                          setState(() {
                            _focusedMonth = DateTime.now();
                            _selectedDate = DateTime.now();
                          });
                          _refreshCalendarViewCache(
                              includeOverlayEvents: false);
                          unawaited(_loadGroupOverlay());
                        },
                      ),
                      const SizedBox(height: 8),
                      _CalendarGroupContextChip(label: selectedGroupLabel),
                      const SizedBox(height: 12),
                      _MiniCalendarGrid(
                        focusedMonth: _focusedMonth,
                        selectedDate: _selectedDate,
                        monthCells: _miniMonthCells,
                        onDaySelected: (day) {
                          _updateSelectedDateCache(day);
                          if (!useTwoPane) {
                            final personalEvents =
                                List<EventModel>.of(_selectedDateEventsCache);
                            final groupEvents = List<CalendarOverlayItem>.of(
                              _selectedDateGroupEventsCache,
                            );
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _showDayEventsSheet(
                                  day,
                                  personalEvents: personalEvents,
                                  groupEvents: groupEvents,
                                );
                              }
                            });
                          }
                        },
                      ),
                    ],
                  ),
                );
                final agendaPane = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CalendarSelectedDateHeader(
                      selectedDateLabel: selectedDateLabel,
                      eventCount: totalDayEventCount,
                      holidayName: _selectedDateHolidayName,
                      isHoliday: KoreanHolidays.isDayOff(_selectedDate),
                      onAdd: () =>
                          context.push(_eventEditRouteForDay(_selectedDate)),
                      onVoice: () => context.push(AppRoutes.voice),
                    ),
                    const SizedBox(height: 8),
                    _CalendarGroupContextChip(label: selectedGroupLabel),
                    if (_groupOverlayProvider?.error != null) ...[
                      const SizedBox(height: 8),
                      const _CalendarOverlayErrorBanner(
                        message: '그룹 일정만 불러오지 못했어요.',
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (dayEvents.isEmpty && groupDayEvents.isEmpty)
                      _EmptyAgendaCard(
                        onVoice: () => context.push(AppRoutes.voice),
                      )
                    else ...[
                      if (dayEvents.isNotEmpty) ...[
                        _AgendaSectionHeader(
                          title: '개인 일정',
                          count: dayEvents.length,
                        ),
                        const SizedBox(height: 8),
                        ...dayEvents.map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _InstructionBadgeWrapper(
                              hasInstruction:
                                  _instructionEventIds.contains(event.id),
                              child: _EventAgendaCard(
                                event: event,
                                onTap: () => context.push(
                                  '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                                  extra: event,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (groupDayEvents.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _AgendaSectionHeader(
                          title: '그룹 일정',
                          count: groupDayEvents.length,
                        ),
                        const SizedBox(height: 8),
                        ...groupDayEvents.map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _GroupOverlayAgendaCard(
                              event: event,
                              onTap: () => context.push(
                                '${AppRoutes.groupEvents}/${Uri.encodeComponent(event.id)}',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                );

                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppConstants.defaultPadding),
                  children: [
                    if (_loadState == _CalendarLoadState.supabaseMissing ||
                        _loadState == _CalendarLoadState.signedOut ||
                        _loadState == _CalendarLoadState.error) ...[
                      _CalendarStatusCard(
                        state: _loadState,
                        message: _loadMessage,
                        onRefresh: () => _loadEvents(),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_isSearching) ...[
                      TextField(
                        controller: _searchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: '제목, 장소, 메모로 검색',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '검색어 지우기',
                                  onPressed: _searchController.clear,
                                  icon: const Icon(Icons.clear),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (useTwoPane)
                      ResponsiveTwoPane(
                        primary: calendarPane,
                        secondary: agendaPane,
                        breakpoint: PlanFlowResponsive.twoPaneBreakpoint,
                        gap: 20,
                        primaryFlex: 6,
                        secondaryFlex: 4,
                      )
                    else ...[
                      calendarPane,
                      const SizedBox(height: 16),
                      agendaPane,
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _eventEditRouteForDay(DateTime day) {
    final date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    return '${AppRoutes.eventEdit}?date=$date';
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }
}
