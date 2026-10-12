import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../integration_test/_harness/seed/fixture_events.dart';
import '../integration_test/support/widget_probe_calendar_sheet_finder.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    EventPrefetchService().invalidate();
  });

  testWidgets('real CalendarScreen sheet title is uniquely scoped', (
    tester,
  ) async {
    final event = FixtureEvents.simple(
      id: 'calendar-sheet-finder-real-event',
      title: 'Calendar sheet finder real event',
      daysFromNow: 3,
    );
    final day =
        DateTime(event.startAt!.year, event.startAt!.month, event.startAt!.day);
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: _MemoryEventRepository(<EventModel>[event]),
          userId: 'calendar-sheet-finder-user',
          initialDate: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scoped = findWidgetProbeCalendarDaySheetEventTitle(event.title);
    expect(find.byKey(const ValueKey('calendar-day-events-draggable-sheet')),
        findsOneWidget);
    expect(scoped, findsOneWidget);
    expect(find.text(event.title), findsNWidgets(2));
  });

  testWidgets('scoped finder excludes underlay-only text and absent sheet', (
    tester,
  ) async {
    const title = 'underlay only title';
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: <Widget>[
            Text(title),
            SizedBox(
                key: ValueKey<String>('calendar-day-events-draggable-sheet')),
          ],
        ),
      ),
    );
    expect(find.text(title), findsOneWidget);
    expect(findWidgetProbeCalendarDaySheetEventTitle(title), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: Text(title)));
    expect(findWidgetProbeCalendarDaySheetEventTitle(title), findsNothing);
  });

  testWidgets('scoped finder excludes offstage sheet contents', (tester) async {
    const title = 'offstage sheet title';
    await tester.pumpWidget(
      const MaterialApp(
        home: Offstage(
          offstage: true,
          child: Column(
            children: <Widget>[
              SizedBox(
                  key: ValueKey<String>('calendar-day-events-draggable-sheet')),
              Text(title),
            ],
          ),
        ),
      ),
    );
    expect(findWidgetProbeCalendarDaySheetEventTitle(title), findsNothing);
  });

  testWidgets('scoped finder preserves non-unique evidence', (tester) async {
    const title = 'two sheet titles';
    await tester.pumpWidget(
      const MaterialApp(
        home: KeyedSubtree(
          key: ValueKey<String>('calendar-day-events-draggable-sheet'),
          child: Column(children: <Widget>[Text(title), Text(title)]),
        ),
      ),
    );
    final scoped = findWidgetProbeCalendarDaySheetEventTitle(title);
    expect(scoped, findsNWidgets(2));
    expect(findsOneWidget.matches(scoped, {}), isFalse);
  });
}

class _MemoryEventRepository extends EventRepository {
  _MemoryEventRepository(this.events);

  final List<EventModel> events;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      List<EventModel>.of(events);

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel> createEvent(EventModel event) =>
      throw UnimplementedError();

  @override
  Future<EventModel> updateEvent(EventModel event) =>
      throw UnimplementedError();

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) =>
      throw UnimplementedError();
}
