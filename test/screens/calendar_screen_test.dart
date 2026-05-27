import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_refresh_bus.dart';

void main() {
  testWidgets('CalendarScreen does not show a loading panel while loading',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CalendarScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('\uD655\uC778\uC911'), findsNothing);
    expect(find.textContaining('Supabase'), findsOneWidget);
  });

  test(
      'mergeCalendarEventsAfterReload preserves existing events after suspiciously small reload',
      () {
    final now = DateTime.now();
    final merged = mergeCalendarEventsAfterReload(
      previous: [
        _event('old-1', '기존 일정 1', now.add(const Duration(minutes: 1))),
        _event('old-2', '기존 일정 2', now.add(const Duration(minutes: 2))),
      ],
      loaded: [
        _event('new-1', '새 일정', now.add(const Duration(minutes: 3))),
      ],
    );

    expect(merged.map((event) => event.id), ['old-1', 'old-2', 'new-1']);
  });

  testWidgets(
      'CalendarScreen runs a queued reload after refresh signal arrives while loading',
      (tester) async {
    final now = DateTime.now();
    final firstLoad = Completer<List<EventModel>>();
    final repository = _AsyncEventRepository([
      firstLoad.future,
      Future.value([
        _event('old-1', '기존 일정', now.add(const Duration(hours: 1))),
        _event('new-1', '새 일정', now.add(const Duration(hours: 2))),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: now,
        ),
      ),
    );
    await tester.pump();

    EventRefreshBus.instance.notifyChanged(
      reason: 'test_queued',
      startAt: now,
    );
    await tester.pump();

    firstLoad.complete([
      _event('old-1', '기존 일정', now.add(const Duration(hours: 1))),
    ]);
    await tester.pumpAndSettle();

    expect(repository.listCalls, 2);
    expect(find.text('기존 일정'), findsWidgets);
    expect(find.text('새 일정'), findsWidgets);
  });

  testWidgets('CalendarScreen opens selected day sheet from initialDate',
      (tester) async {
    final selectedDay = DateTime(2026, 5, 15, 9);
    final repository = _AsyncEventRepository([
      Future.value([
        _event('selected-1', '선택한 날짜 일정', selectedDay),
        _event('other-1', '다른 날짜 일정', selectedDay.add(const Duration(days: 1))),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: selectedDay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('calendar-day-events-draggable-sheet')),
      findsOneWidget,
    );
    final dayEventsList =
        find.byKey(const ValueKey('calendar-day-events-list'));
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('선택한 날짜 일정'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('다른 날짜 일정'),
      ),
      findsNothing,
    );
  });

  test('calendar marks date-range events across every local day', () {
    final rangeEvent = EventModel(
      id: 'range-1',
      userId: 'user-1',
      title: '원주집방문',
      startAt: DateTime.utc(2026, 4, 30, 15),
      endAt: DateTime.utc(2026, 5, 10, 15),
      isMultiDay: false,
    );

    expect(calendarEventSpansMultipleLocalDays(rangeEvent), isTrue);

    final markers = buildCalendarEventMarkerColorsByDay(
      events: <EventModel>[rangeEvent],
      focusedMonth: DateTime(2026, 5),
    );

    for (var day = 1; day <= 10; day += 1) {
      expect(markers[day], PlanFlowColors.active);
    }
    expect(markers[11], isNull);
  });

  test('calendar treats midnight end as the previous display day', () {
    final event = EventModel(
      id: 'range-midnight',
      userId: 'user-1',
      title: '테스트',
      startAt: DateTime.utc(2026, 5, 18, 15),
      endAt: DateTime.utc(2026, 5, 22, 15),
      isMultiDay: true,
    );

    final markers = buildCalendarEventMarkerColorsByDay(
      events: <EventModel>[event],
      focusedMonth: DateTime(2026, 5),
    );

    for (var day = 19; day <= 22; day += 1) {
      expect(markers[day], PlanFlowColors.active);
    }
    expect(markers[23], isNull);
  });

  testWidgets('CalendarScreen shows cross-month range on selected end day',
      (tester) async {
    final selectedDay = DateTime(2026, 6);
    final repository = _AsyncEventRepository([
      Future.value([
        EventModel(
          id: 'wonju-home',
          userId: 'user-1',
          title: '원주집방문',
          startAt: DateTime.utc(2026, 5, 25, 15),
          endAt: DateTime.utc(2026, 6, 1, 14, 59, 59),
          isAllDay: true,
          isMultiDay: true,
        ),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: selectedDay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dayEventsList =
        find.byKey(const ValueKey('calendar-day-events-list'));
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('원주집방문'),
      ),
      findsOneWidget,
    );
  });
}

EventModel _event(String id, String title, DateTime startAt) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt,
    endAt: startAt.add(const Duration(minutes: 30)),
  );
}

class _AsyncEventRepository extends EventRepository {
  _AsyncEventRepository(this._responses);

  final List<Future<List<EventModel>>> _responses;
  int listCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    final index = listCalls;
    listCalls += 1;
    if (index >= _responses.length) {
      return _responses.last;
    }
    return _responses[index];
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError();
  }
}
