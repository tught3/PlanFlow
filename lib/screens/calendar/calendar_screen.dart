import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/event_metadata.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../features/groups/models/calendar_overlay_item.dart';
import '../../features/groups/providers/group_calendar_overlay_provider.dart';
import '../../services/event_refresh_bus.dart';
import '../../widgets/planflow_logo.dart';
import '../../widgets/planflow_voice_fab.dart';

enum _CalendarLoadState { loading, ready, supabaseMissing, signedOut, error }

const calendarCriticalEventMarkerColor = Color(0xFFB42318);
const calendarMultiDayEventBackgroundColor = Color(0xFFDDEFE6);
const calendarMultiDayEventTextColor = Color(0xFF174F4A);
const calendarCriticalMultiDayAccentColor = Color(0xFFE98B86);

Color _categoryColor(String category) {
  return PlanFlowEventCategories.colorOf(category);
}

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
    }.values.toList(growable: false)..sort(compareCalendarEventsForDisplay);
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
    for (
      var day = firstDay;
      !day.isAfter(lastDay);
      day = day.add(const Duration(days: 1))
    ) {
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
  '휴일',
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

List<EventModel> _eventsForLocalDay(Iterable<EventModel> events, DateTime day) {
  final result = <EventModel>[];
  for (final event in events) {
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
  });

  final int index;
  final DateTime? date;
  final int? dayNumber;
  final bool inMonth;
  final List<EventModel> events;
  final List<CalendarOverlayItem> overlayEvents;
  final int overflowCount;
  final bool isHoliday;
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

  final visibleOverlayEvents =
      overlayEvents
          .where((event) {
            final startAt = event.startAt;
            if (startAt == null) {
              return false;
            }
            final endAt = event.endAt ?? startAt;
            final monthStart = DateTime(focusedMonth.year, focusedMonth.month);
            final monthEnd = DateTime(
              focusedMonth.year,
              focusedMonth.month + 1,
            );
            final localStart = planflowLocalDay(startAt);
            final localEnd = planflowLocalDay(endAt);
            return !localStart.isAfter(monthEnd) &&
                !localEnd.isBefore(monthStart);
          })
          .toList(growable: false)
        ..sort((a, b) {
          final aStart = a.startAt ?? DateTime(0);
          final bStart = b.startAt ?? DateTime(0);
          final byStart = aStart.compareTo(bStart);
          if (byStart != 0) {
            return byStart;
          }
          return a.title.compareTo(b.title);
        });

  final sortedEvents =
      events.where((event) => event.startAt != null).toList(growable: false)
        ..sort(compareCalendarEventsForDisplay);

  final multiDayEvents = sortedEvents
      .where((event) {
        final startAt = event.startAt;
        if (startAt == null) {
          return false;
        }
        final firstDay = planflowLocalDay(startAt);
        final lastEventDay = _calendarDisplayEndDay(
          startAt,
          event.endAt ?? startAt,
        );
        return lastEventDay.isAfter(firstDay);
      })
      .toList(growable: false);

  for (final event in multiDayEvents) {
    final startAt = event.startAt;
    if (startAt == null) {
      continue;
    }
    final firstDay = planflowLocalDay(startAt);
    final lastEventDay = _calendarDisplayEndDay(
      startAt,
      event.endAt ?? startAt,
    );
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

    var reserved = false;
    for (var slot = 0; slot < _calendarMiniMonthEventRows; slot += 1) {
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
    final singleEvents = sortedEvents
        .where((event) {
          final startAt = event.startAt;
          if (startAt == null) {
            return false;
          }
          final firstDay = planflowLocalDay(startAt);
          final lastEventDay = _calendarDisplayEndDay(
            startAt,
            event.endAt ?? startAt,
          );
          return !lastEventDay.isAfter(firstDay) && firstDay == day;
        })
        .toList(growable: false);
    for (final event in singleEvents) {
      var placed = false;
      for (var slot = 0; slot < _calendarMiniMonthEventRows; slot += 1) {
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
    final visibleEvents = slotMap[index].whereType<EventModel>().toList(
      growable: false,
    );
    return CalendarMiniMonthCellData(
      index: index,
      date: day,
      dayNumber: day?.day,
      inMonth:
          day != null &&
          day.year == monthStart.year &&
          day.month == monthStart.month,
      events: visibleEvents,
      overlayEvents: overlayItemsByCell[index],
      overflowCount: overflowCounts[index],
      isHoliday:
          day != null &&
          _eventsForLocalDay(
            sortedEvents,
            day,
          ).any((event) => _looksLikeHolidayTitle(event.title)),
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

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _selectedDate;
  late DateTime _focusedMonth;
  List<EventModel> _allEvents = const <EventModel>[];
  GroupCalendarOverlayProvider? _groupOverlayProvider;
  _CalendarLoadState _loadState = _CalendarLoadState.ready;
  String? _loadMessage;
  bool _isSearching = false;
  bool _isRefreshing = false;
  bool _hasPendingRefresh = false;
  DateTime? _pendingFocusDate;
  DateTime? _pendingOpenDaySheetDate;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialDate = widget.initialDate ?? DateTime.now();
    _selectedDate = initialDate;
    _focusedMonth = DateTime(initialDate.year, initialDate.month);
    _pendingOpenDaySheetDate = widget.initialDate;
    EventRefreshBus.instance.latest.addListener(_handleEventRefresh);
    _searchController.addListener(() => setState(() {}));
    _loadEvents(focusDate: widget.initialDate);
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

  void _handleEventRefresh() {
    final signal = EventRefreshBus.instance.latest.value;
    unawaited(_loadEvents(focusDate: signal?.startAt));
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
    final canUseInjectedRepository =
        repositoryOverride != null &&
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
      var shouldOpenDaySheet = false;
      var daySheetDate = focusDate;
      if (mounted) {
        setState(() {
          _allEvents = _eventsForDisplayAfterReload(events);
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
      await _loadGroupOverlay(userId: userId);
      if (shouldOpenDaySheet && daySheetDate != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showDayEventsSheet(daySheetDate!);
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
    return _visibleEvents
        .where((event) {
          final startAt = event.startAt;
          if (startAt == null) {
            return false;
          }
          return _eventIntersectsDay(event, _selectedDate);
        })
        .toList(growable: false);
  }

  List<CalendarOverlayItem> get _overlayEventsForSelectedDate {
    return _visibleGroupOverlayEvents
        .where((event) {
          return event.spansLocalDay(_selectedDate);
        })
        .toList(growable: false);
  }

  List<CalendarOverlayItem> _overlayEventsForDay(DateTime day) {
    return _visibleGroupOverlayEvents
        .where((event) {
          return event.spansLocalDay(day);
        })
        .toList(growable: false);
  }

  List<CalendarMiniMonthCellData> get _miniMonthCells {
    return buildCalendarMiniMonthCells(
      events: _visibleEvents,
      focusedMonth: _focusedMonth,
      overlayEvents: _visibleGroupOverlayEvents,
    );
  }

  List<CalendarOverlayItem> get _visibleGroupOverlayEvents {
    final groupOverlayProvider = _groupOverlayProvider;
    if (groupOverlayProvider == null) {
      return const <CalendarOverlayItem>[];
    }
    final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month);
    final monthEnd = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    return groupOverlayProvider.items
        .where((event) {
          final start = event.startAt;
          if (start == null) {
            return false;
          }
          final end = event.endAt ?? start;
          return !start.isAfter(monthEnd) && !end.isBefore(monthStart);
        })
        .toList(growable: false)
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

  List<EventModel> get _filteredEvents {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _allEvents;
    }
    return _allEvents
        .where((event) {
          final searchable = <String>[
            event.title,
            event.location ?? '',
            event.memo ?? '',
            event.category,
          ].join(' ').toLowerCase();
          return searchable.contains(query);
        })
        .toList(growable: false);
  }

  List<EventModel> get _visibleEvents {
    final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month);
    final monthEnd = DateTime(
      _focusedMonth.year,
      _focusedMonth.month + 1,
      0,
    ).add(const Duration(days: 1));
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
    visible.sort(
      (a, b) => (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)),
    );
    return visible;
  }

  List<EventModel> _hideOverriddenRecurringOccurrences(
    List<EventModel> events,
  ) {
    final overrides = events
        .where(
          (event) =>
              event.parentEventId != null &&
              event.parentEventId!.trim().isNotEmpty &&
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

  bool _eventIntersectsDay(EventModel event, DateTime day) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    return planflowEventIntersectsLocalDay(
      startAt: startAt,
      endAt: event.endAt,
      day: day,
    );
  }

  List<EventModel> _expandRecurringEvent(
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
    final until = _parseRRuleUntil(
      RegExp(r'UNTIL=([0-9TzZ]+)').firstMatch(rule)?.group(1),
    );
    final hardEnd = until?.isBefore(rangeEnd) == true ? until! : rangeEnd;
    final localStartAt = planflowLocal(startAt);
    final duration = event.endAt?.difference(startAt);
    final occurrences = <EventModel>[];

    if (freq == 'WEEKLY') {
      final byDays = _parseRRuleByDays(rule);
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
            final candidate = _copyEventWithTime(
              event,
              startAt: current,
              endAt: occurrenceEnd,
            );
            if (_eventIntersectsRange(candidate, rangeStart, rangeEnd)) {
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
      final candidate = _copyEventWithTime(
        event,
        startAt: current,
        endAt: occurrenceEnd,
      );
      if (_eventIntersectsRange(candidate, rangeStart, rangeEnd)) {
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

  bool _eventIntersectsRange(
    EventModel event,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final localDisplayEnd = _calendarDisplayEndDay(
      startAt,
      event.endAt ?? startAt,
    );
    final eventDisplayEndExclusive = DateTime(
      localDisplayEnd.year,
      localDisplayEnd.month,
      localDisplayEnd.day + 1,
    );
    return planflowLocal(startAt).isBefore(rangeEnd) &&
        eventDisplayEndExclusive.isAfter(rangeStart);
  }

  DateTime? _parseRRuleUntil(String? value) {
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

  List<int> _parseRRuleByDays(String rule) {
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

  EventModel _copyEventWithTime(
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
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
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

  void _showDayEventsSheet(DateTime day) {
    final events = _visibleEvents
        .where((event) {
          return _eventIntersectsDay(event, day);
        })
        .toList(growable: false);
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
              groupEvents: _overlayEventsForDay(day),
              scrollController: scrollController,
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
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + delta);
    });
    unawaited(_loadGroupOverlay());
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

  Future<void> _loadGroupOverlay({String? userId}) async {
    if (!AppEnv.isSupabaseReady &&
        widget.groupCalendarOverlayProvider == null) {
      _groupOverlayProvider?.clear();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _groupOverlayProvider ??=
        widget.groupCalendarOverlayProvider ?? GroupCalendarOverlayProvider();
    final resolvedUserId = userId ?? _resolveCalendarUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      await _groupOverlayProvider!.clear();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    await _groupOverlayProvider!.loadForMonth(resolvedUserId, _focusedMonth);
    if (mounted) {
      setState(() {});
    }
  }

  String? _resolveCalendarUserId() {
    final explicitUserId = widget.userId?.trim();
    if (explicitUserId != null && explicitUserId.isNotEmpty) {
      return explicitUserId;
    }
    return Supabase.instance.client.auth.currentUser?.id;
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
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _loadEvents(),
          child: ResponsiveContent(
            maxWidth: context.planflowWindowInfo.wideContentMaxWidth,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useTwoPane =
                    constraints.maxWidth >=
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
                          setState(() {
                            _selectedDate = day;
                          });
                          if (!useTwoPane) {
                            _showDayEventsSheet(day);
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
                      onAdd: () =>
                          context.push(_eventEditRouteForDay(_selectedDate)),
                      onVoice: () => context.push(AppRoutes.voice),
                    ),
                    const SizedBox(height: 8),
                    _CalendarGroupContextChip(label: selectedGroupLabel),
                    if (_groupOverlayProvider?.error != null) ...[
                      const SizedBox(height: 8),
                      _CalendarOverlayErrorBanner(message: '그룹 일정만 불러오지 못했어요.'),
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
                            child: _EventAgendaCard(
                              event: event,
                              onTap: () => context.push(
                                '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                                extra: event,
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
    final date =
        '${day.year.toString().padLeft(4, '0')}-'
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

class _CalendarSelectedDateHeader extends StatelessWidget {
  const _CalendarSelectedDateHeader({
    required this.selectedDateLabel,
    required this.eventCount,
    required this.onAdd,
    required this.onVoice,
  });

  final String selectedDateLabel;
  final int eventCount;
  final VoidCallback onAdd;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 420;
        final countBadge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: PlanFlowColors.surface,
            border: Border.all(color: PlanFlowColors.primaryFaint),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$eventCount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: PlanFlowColors.primaryMid,
            ),
          ),
        );

        if (isNarrow) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth,
                child: Text(
                  selectedDateLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              countBadge,
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('직접 추가'),
              ),
              TextButton.icon(
                onPressed: onVoice,
                icon: const Icon(Icons.mic_none, size: 18),
                label: const Text('음성 추가'),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(
              child: Text(
                selectedDateLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            countBadge,
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('직접 추가'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onVoice,
              icon: const Icon(Icons.mic_none, size: 18),
              label: const Text('음성 추가'),
            ),
          ],
        );
      },
    );
  }
}

class DayEventsSheet extends StatelessWidget {
  const DayEventsSheet({
    super.key,
    required this.day,
    required this.personalEvents,
    required this.groupEvents,
    required this.onAdd,
    required this.onVoice,
    required this.onEventTap,
    required this.onGroupEventTap,
    this.scrollController,
  });

  final DateTime day;
  final List<EventModel> personalEvents;
  final List<CalendarOverlayItem> groupEvents;
  final VoidCallback onAdd;
  final VoidCallback onVoice;
  final ValueChanged<EventModel> onEventTap;
  final ValueChanged<CalendarOverlayItem> onGroupEventTap;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _koreanDateLabel(day);
    final totalCount = personalEvents.length + groupEvents.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: PlanFlowColors.primaryFaint),
                  ),
                  child: Text('$totalCount개'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '위로 끌어올려 더 많은 일정을 볼 수 있어요.',
              style: TextStyle(
                color: PlanFlowColors.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('직접 추가'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onVoice,
                    icon: const Icon(Icons.mic_none, size: 18),
                    label: const Text('음성 추가'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: personalEvents.isEmpty && groupEvents.isEmpty
                  ? ListView(
                      key: const ValueKey('calendar-day-events-empty-scroll'),
                      controller: scrollController,
                      children: const [_SheetEmptyState()],
                    )
                  : ListView(
                      key: const ValueKey('calendar-day-events-list'),
                      controller: scrollController,
                      children: [
                        if (personalEvents.isNotEmpty) ...[
                          const _AgendaSectionHeader(title: '개인 일정', count: 0),
                          const SizedBox(height: 10),
                          ...personalEvents.map(
                            (event) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _EventAgendaCard(
                                event: event,
                                onTap: () => onEventTap(event),
                              ),
                            ),
                          ),
                        ],
                        if (groupEvents.isNotEmpty) ...[
                          if (personalEvents.isNotEmpty)
                            const SizedBox(height: 4),
                          _AgendaSectionHeader(
                            title: '그룹 일정',
                            count: groupEvents.length,
                          ),
                          const SizedBox(height: 10),
                          ...groupEvents.map(
                            (event) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _GroupOverlayAgendaCard(
                                key: ValueKey(
                                  'calendar-group-overlay-event-${event.id}',
                                ),
                                event: event,
                                onTap: () => onGroupEventTap(event),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
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

class _SheetEmptyState extends StatelessWidget {
  const _SheetEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: const Text(
        '이 날은 아직 일정이 없어요. 직접 추가하거나 음성으로 빠르게 등록할 수 있습니다.',
        style: TextStyle(color: PlanFlowColors.textSecondary, height: 1.35),
      ),
    );
  }
}

class _CalendarStatusCard extends StatelessWidget {
  const _CalendarStatusCard({
    required this.state,
    required this.onRefresh,
    this.message,
  });

  final _CalendarLoadState state;
  final VoidCallback onRefresh;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (state) {
      _CalendarLoadState.supabaseMissing => (
        Icons.cloud_off_outlined,
        'Supabase 설정이 필요해요',
        '빌드 설정값이 없어서 캘린더 데이터를 가져올 수 없어요.',
      ),
      _CalendarLoadState.signedOut => (
        Icons.lock_outline,
        '로그인이 필요해요',
        '로그인한 뒤 내 일정 목록을 다시 불러올 수 있어요.',
      ),
      _CalendarLoadState.error => (
        Icons.error_outline,
        '캘린더 불러오기 실패',
        message ?? '캘린더 일정 목록을 불러오지 못했습니다.',
      ),
      _CalendarLoadState.loading => (
        Icons.hourglass_top_outlined,
        '캘린더 확인 중',
        '잠시만 기다려 주세요.',
      ),
      _CalendarLoadState.ready => (
        Icons.check_circle_outline,
        '정상',
        '캘린더 데이터를 불러왔어요.',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: PlanFlowColors.primaryMid),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('새로고침'),
          ),
        ],
      ),
    );
  }
}

// --- Month Header ---
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.monthLabel,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final String monthLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryMid,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            onPressed: onPrevious,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          Expanded(
            child: Text(
              monthLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onToday,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.7)),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              minimumSize: const Size(0, 38),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: (theme.textTheme.labelLarge?.fontSize ?? 14) * 1.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            icon: const Icon(Icons.today, size: 16),
            label: const Text('오늘'),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white),
            onPressed: onNext,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

// --- Mini Calendar Grid ---
class _MiniCalendarGrid extends StatelessWidget {
  const _MiniCalendarGrid({
    required this.focusedMonth,
    required this.selectedDate,
    required this.monthCells,
    required this.onDaySelected,
  });

  final DateTime focusedMonth;
  final DateTime selectedDate;
  final List<CalendarMiniMonthCellData> monthCells;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = (monthCells.length / 7).ceil();
    final today = DateTime.now();

    const weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Weekday header
            Row(
              children: weekdayLabels.map((label) {
                final isSunday = label == '일';
                final isSaturday = label == '토';
                return Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isSunday
                            ? const Color(0xFFB42318)
                            : isSaturday
                            ? PlanFlowColors.primaryMid
                            : PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),

            // Day cells
            ...List.generate(rows, (weekIndex) {
              return Row(
                children: List.generate(7, (dayIndex) {
                  final cellIndex = weekIndex * 7 + dayIndex;
                  if (cellIndex >= monthCells.length) {
                    return const Expanded(child: SizedBox(height: 74));
                  }
                  final cell = monthCells[cellIndex];
                  final dayDate = cell.date;
                  if (dayDate == null) {
                    return const Expanded(child: SizedBox(height: 74));
                  }
                  final dayNumber = cell.dayNumber ?? dayDate.day;

                  final isToday =
                      today.year == dayDate.year &&
                      today.month == dayDate.month &&
                      today.day == dayDate.day;
                  final isSelected =
                      selectedDate.year == dayDate.year &&
                      selectedDate.month == dayDate.month &&
                      selectedDate.day == dayDate.day;

                  return Expanded(
                    child: GestureDetector(
                      onTap: () => onDaySelected(dayDate),
                      child: Container(
                        key: ValueKey(
                          'calendar-mini-cell-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                        ),
                        height: 74,
                        margin: const EdgeInsets.all(1.5),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? PlanFlowColors.primaryMid
                              : isToday
                              ? PlanFlowColors.primaryFaint
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Text(
                                '$dayNumber',
                                key: ValueKey(
                                  'calendar-mini-day-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isToday || isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: isSelected
                                      ? Colors.white
                                      : isToday
                                      ? PlanFlowColors.primaryMid
                                      : cell.isHoliday
                                      ? calendarCriticalEventMarkerColor
                                      : PlanFlowColors.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Expanded(
                              child: _CalendarMiniEventList(
                                key: ValueKey(
                                  'calendar-mini-events-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                                ),
                                events: cell.events,
                                overlayEvents: cell.overlayEvents,
                                overflowCount: cell.overflowCount,
                                isSelected: isSelected,
                                day: dayDate,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _CalendarMiniEventList extends StatelessWidget {
  const _CalendarMiniEventList({
    super.key,
    required this.events,
    required this.overlayEvents,
    required this.overflowCount,
    required this.isSelected,
    required this.day,
  });

  final List<EventModel> events;
  final List<CalendarOverlayItem> overlayEvents;
  final int overflowCount;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty && overflowCount <= 0) {
      return const SizedBox.shrink();
    }
    final requiresOverflowLabel =
        overflowCount > 0 || events.length > _calendarMiniMonthEventRows;
    final maxVisibleEvents = requiresOverflowLabel
        ? (_calendarMiniMonthEventRows - 1).clamp(
            1,
            _calendarMiniMonthEventRows,
          )
        : _calendarMiniMonthEventRows;
    final displayEvents = events.length > maxVisibleEvents
        ? events.take(maxVisibleEvents).toList(growable: false)
        : events;
    final hiddenCount = requiresOverflowLabel
        ? (overflowCount > 0
              ? overflowCount
              : events.length - displayEvents.length)
        : 0;
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final event in displayEvents)
          _CalendarMiniEventLabel(
            event: event,
            isSelected: isSelected,
            day: day,
          ),
        for (final event in overlayEvents)
          _CalendarMiniOverlayLabel(
            event: event,
            isSelected: isSelected,
            day: day,
          ),
        if (hiddenCount > 0)
          SizedBox(
            height: 9,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 1),
                child: Text(
                  '+$hiddenCount개',
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 7,
                    height: 1,
                    color: isSelected
                        ? Colors.white
                        : PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CalendarGroupContextChip extends StatelessWidget {
  const _CalendarGroupContextChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: PlanFlowColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: PlanFlowColors.primaryFaint),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              label == '개인 모드' ? Icons.person_outline : Icons.groups_outlined,
              size: 14,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: PlanFlowColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgendaSectionHeader extends StatelessWidget {
  const _AgendaSectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: PlanFlowColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: PlanFlowColors.primaryFaint),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
          ),
      ],
    );
  }
}

class _CalendarOverlayErrorBanner extends StatelessWidget {
  const _CalendarOverlayErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF8C8C0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: Color(0xFFB42318),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF7A271A),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarMiniOverlayLabel extends StatelessWidget {
  const _CalendarMiniOverlayLabel({
    required this.event,
    required this.isSelected,
    required this.day,
  });

  final CalendarOverlayItem event;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final segment = _multiDaySegment(event, day);
    final isMultiDay = event.isMultiDay;
    final bg = isMultiDay
        ? const Color(0xFFD9E9FF)
        : isSelected
        ? Colors.white.withValues(alpha: 0.2)
        : const Color(0xFFD9E9FF);
    final fg = isSelected ? Colors.white : PlanFlowColors.primary;
    final showTitle = !isMultiDay || segment.$1;
    final hPadding = (isMultiDay && !segment.$1 && !segment.$2) ? 0.0 : 2.0;
    final extendLeft = isMultiDay && !segment.$1 ? 1.5 : 0.0;
    final extendRight = isMultiDay && !segment.$2 ? 1.5 : 0.0;
    return SizedBox(
      height: 9,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -extendLeft,
            right: -extendRight,
            top: 1,
            bottom: 0,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(segment.$1 ? 3 : 0),
                  right: Radius.circular(segment.$2 ? 3 : 0),
                ),
                border: Border.all(
                  color: PlanFlowColors.primaryMid.withValues(alpha: 0.18),
                  width: 0.4,
                ),
              ),
              alignment: Alignment.centerLeft,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: hPadding),
                  child: Text(
                    showTitle
                        ? (event.groupName != null &&
                                  event.groupName!.isNotEmpty
                              ? '팀 ${event.title}'
                              : event.title)
                        : '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 6.8,
                      height: 1.0,
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  (bool, bool) _multiDaySegment(CalendarOverlayItem event, DateTime day) {
    if (!event.isMultiDay || event.startAt == null || event.endAt == null) {
      return (true, true);
    }
    final current = DateTime(day.year, day.month, day.day);
    final first = event.localStart;
    final last = event.localEnd;
    return (
      current == first || current.weekday == DateTime.sunday,
      current == last || current.weekday == DateTime.saturday,
    );
  }
}

class _CalendarMiniEventLabel extends StatelessWidget {
  const _CalendarMiniEventLabel({
    required this.event,
    required this.isSelected,
    required this.day,
  });

  final EventModel event;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final segment = _multiDaySegment(event, day);
    final isMultiDay =
        event.isMultiDay || calendarEventSpansMultipleLocalDays(event);
    final isCriticalMultiDay = isMultiDay && event.isCritical;
    final bg = isMultiDay
        ? calendarMultiDayEventBackgroundColor
        : isSelected
        ? Colors.white.withValues(alpha: 0.18)
        : event.isCritical
        ? const Color(0xFFB42318).withValues(alpha: 0.12)
        : _categoryColor(event.category).withValues(alpha: 0.16);
    final fg = isMultiDay
        ? calendarMultiDayEventTextColor
        : isSelected
        ? Colors.white
        : event.isCritical
        ? const Color(0xFFB42318)
        : _categoryColor(event.category);
    final showTitle = !isMultiDay || segment.$1;
    final hPadding = (isMultiDay && !segment.$1 && !segment.$2) ? 0.0 : 2.0;
    // Neighboring day cells have 1.5px margins on each side, so extending
    // halfway into that gap lets range bars touch without alpha overlap.
    final extendLeft = isMultiDay && !segment.$1 ? 1.5 : 0.0;
    final extendRight = isMultiDay && !segment.$2 ? 1.5 : 0.0;
    return SizedBox(
      height: 9,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -extendLeft,
            right: -extendRight,
            top: 1,
            bottom: 0,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(segment.$1 ? 3 : 0),
                  right: Radius.circular(segment.$2 ? 3 : 0),
                ),
              ),
              alignment: Alignment.centerLeft,
              child: Stack(
                children: [
                  if (isCriticalMultiDay)
                    const Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      height: 1.4,
                      child: ColoredBox(
                        color: calendarCriticalMultiDayAccentColor,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: hPadding)
                          .copyWith(
                            top: isCriticalMultiDay && showTitle ? 1.0 : 0.0,
                          ),
                      child: Text(
                        showTitle
                            ? (event.isAllDay && !isMultiDay
                                  ? '종일 ${event.title}'
                                  : event.title)
                            : '',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 6.8,
                          height: 1.0,
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  (bool, bool) _multiDaySegment(EventModel event, DateTime day) {
    if ((!event.isMultiDay && !calendarEventSpansMultipleLocalDays(event)) ||
        event.startAt == null ||
        event.endAt == null) {
      return (true, true);
    }
    final current = DateTime(day.year, day.month, day.day);
    final first = planflowLocalDay(event.startAt!);
    final last = _calendarDisplayEndDay(event.startAt!, event.endAt!);
    return (
      current == first || current.weekday == DateTime.sunday,
      current == last || current.weekday == DateTime.saturday,
    );
  }
}

// --- Event Agenda Card ---
class _EventAgendaCard extends StatelessWidget {
  const _EventAgendaCard({required this.event, this.onTap});

  final EventModel event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final endAt = event.endAt;
    final timeLabel = _formatTimeRange(startAt, endAt);
    final accentColor = event.isCritical
        ? const Color(0xFFB42318)
        : _categoryColor(event.category);

    return Card(
      color: accentColor.withValues(alpha: 0.08),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accentColor.withValues(alpha: 0.26),
          width: event.isCritical ? 1.2 : 0.8,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (timeLabel != null)
                      Text(
                        timeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: PlanFlowColors.primaryMid,
                          fontSize: 10,
                        ),
                      ),
                    if (timeLabel != null) const SizedBox(height: 4),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (event.location != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: PlanFlowColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              event.location!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (event.supplies.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: event.supplies
                            .take(3)
                            .map(
                              (supply) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: PlanFlowColors.tagNormalBg,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.backpack_outlined,
                                      size: 10,
                                      color: PlanFlowColors.tagNormalText,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      supply,
                                      style: const TextStyle(
                                        fontSize: 9,
                                        color: PlanFlowColors.tagNormalText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final localStart = planflowLocal(start);
    final startStr =
        '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return startStr;
    }
    final localEnd = planflowLocal(end);
    final endStr =
        '${localEnd.hour.toString().padLeft(2, '0')}:${localEnd.minute.toString().padLeft(2, '0')}';
    return '$startStr - $endStr';
  }
}

class _GroupOverlayAgendaCard extends StatelessWidget {
  const _GroupOverlayAgendaCard({super.key, required this.event, this.onTap});

  final CalendarOverlayItem event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final endAt = event.endAt;
    final timeLabel = _formatOverlayTimeRange(startAt, endAt);
    final accentColor = const Color(0xFF2E6DA4);

    return Card(
      color: accentColor.withValues(alpha: 0.08),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accentColor.withValues(alpha: 0.28),
          width: event.isMultiDay ? 1.0 : 0.8,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '그룹',
                            style: TextStyle(
                              fontSize: 9,
                              color: PlanFlowColors.primaryMid,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if ((event.groupName ?? '').trim().isNotEmpty)
                          Text(
                            event.groupName!,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: PlanFlowColors.primaryMid,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                    if (timeLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        timeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: PlanFlowColors.primaryMid,
                          fontSize: 10,
                        ),
                      ),
                    ],
                    if (timeLabel != null) const SizedBox(height: 4),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (event.location != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: PlanFlowColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              event.location!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatOverlayTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final localStart = planflowLocal(start);
    final startStr =
        '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return startStr;
    }
    final localEnd = planflowLocal(end);
    final endStr =
        '${localEnd.hour.toString().padLeft(2, '0')}:${localEnd.minute.toString().padLeft(2, '0')}';
    return '$startStr - $endStr';
  }
}

// --- Empty State ---
class _EmptyAgendaCard extends StatelessWidget {
  const _EmptyAgendaCard({required this.onVoice});

  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surfaceFaint,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.event_busy_outlined,
              size: 40,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(height: 12),
            Text(
              '이 날은 예정된 일정이 없어요',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '음성으로 회의, 할 일, 알림을 추가하면 이곳에 표시됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onVoice,
              icon: const Icon(Icons.mic_none),
              label: const Text('음성 입력 시작'),
            ),
          ],
        ),
      ),
    );
  }
}
