import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';

void main() {
  testWidgets('EventDetailScreen back falls back to home when opened directly',
      (tester) async {
    final event = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: '알림으로 연 일정',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
    );
    final router = GoRouter(
      initialLocation: '${AppRoutes.eventDetail}/${event.id}',
      routes: [
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, __) => EventDetailScreen(
            event: event,
            eventRepository: _FakeEventRepository(event),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('홈탭')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('홈탭'), findsOneWidget);
  });
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.event);

  final EventModel event;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return event;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return [event];
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    return event;
  }
}
