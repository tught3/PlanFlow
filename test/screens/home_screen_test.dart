import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/home/home_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppEnv.markSupabaseInitialized();
    EventPrefetchService().invalidate();
  });

  testWidgets(
    'HomeScreen keeps rendered content visible during resume refresh',
    (tester) async {
      final firstLoad = Completer<List<EventModel>>();
      final secondLoad = Completer<List<EventModel>>();
      final repository = _QueuedEventRepository(
        responses: <Future<List<EventModel>> Function()>[
          () => firstLoad.future,
          () => secondLoad.future,
        ],
      );
      final initialEvents = <EventModel>[
        EventModel(
          id: 'event-1',
          userId: 'user-1',
          title: '첫 일정',
          startAt: DateTime(2026, 5, 16, 9),
        ),
      ];
      final refreshedEvents = <EventModel>[
        EventModel(
          id: 'event-2',
          userId: 'user-1',
          title: '갱신 일정',
          startAt: DateTime(2026, 5, 16, 10),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userIdOverride: 'user-1',
            eventRepository: repository,
            smartPreparationAlarmService:
                const _FakeSmartPreparationAlarmService(),
            loadHeaderSummary: false,
          ),
        ),
      );

      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('첫 일정'), findsNothing);

      firstLoad.complete(initialEvents);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('첫 일정'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('첫 일정'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.listEventsCallCount, 2);

      secondLoad.complete(refreshedEvents);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('갱신 일정'), findsOneWidget);
      expect(find.text('첫 일정'), findsNothing);
    },
  );
}

class _FakeSmartPreparationAlarmService extends SmartPreparationAlarmService {
  const _FakeSmartPreparationAlarmService();

  @override
  Future<Set<String>> listEventIdsWithSmartAlarms({
    required String userId,
    required Iterable<String> eventIds,
  }) async {
    return const <String>{};
  }
}

class _QueuedEventRepository extends EventRepository {
  _QueuedEventRepository({required this.responses});

  final List<Future<List<EventModel>> Function()> responses;
  int listEventsCallCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    final index = listEventsCallCount++;
    if (index >= responses.length) {
      return Future<List<EventModel>>.value(const <EventModel>[]);
    }
    return responses[index]();
  }

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) async {
    return null;
  }

  @override
  Future<EventModel?> findEventByTitleAndStart({
    required String title,
    required DateTime startAt,
    String? userId,
    Duration tolerance = const Duration(minutes: 1),
    Set<String> excludedSources = const <String>{},
  }) async {
    return null;
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return const <EventModel>[];
  }

  @override
  Future<EventModel?> attachExternalSyncMetadataIfCompatible({
    required EventModel existing,
    required EventModel incoming,
  }) async {
    return null;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateSuppliesChecked({
    required String eventId,
    required List<String> suppliesChecked,
    String? userId,
  }) async {
    return EventModel(
      id: eventId,
      userId: userId ?? '',
      title: 'temp',
      startAt: DateTime(2026, 5, 16, 9),
    );
  }

  @override
  Future<EventModel> upsertEvent(EventModel event) async => event;

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async =>
      event;
}
