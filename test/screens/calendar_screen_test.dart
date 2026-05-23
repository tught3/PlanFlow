import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(find.text('기존 일정'), findsOneWidget);
    expect(find.text('새 일정'), findsOneWidget);
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
