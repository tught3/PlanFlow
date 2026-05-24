import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/home/home_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppEnv.markSupabaseInitialized();
    EventPrefetchService().invalidate();
  });

  test(
      'formatHomeUpcomingDateTime uses relative labels for tomorrow and day after',
      () {
    final now = DateTime(2026, 5, 23, 10);

    expect(
      formatHomeUpcomingDateTime(
        DateTime(2026, 5, 24, 9, 30),
        now: now,
      ),
      '내일 09:30',
    );
    expect(
      formatHomeUpcomingDateTime(
        DateTime(2026, 5, 25, 9, 30),
        now: now,
      ),
      '모레 09:30',
    );
    expect(
      formatHomeUpcomingDateTime(
        DateTime(2026, 5, 26, 9, 30),
        now: now,
      ),
      '05/26 09:30',
    );
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
      final homeWidgetService = _RecordingHomeWidgetService();
      final now = DateTime.now();
      final firstStart = DateTime(now.year, now.month, now.day, 9);
      final secondStart = firstStart.add(const Duration(hours: 1));
      final initialEvents = <EventModel>[
        EventModel(
          id: 'event-1',
          userId: 'user-1',
          title: 'First event',
          startAt: firstStart,
        ),
      ];
      final refreshedEvents = <EventModel>[
        EventModel(
          id: 'event-2',
          userId: 'user-1',
          title: 'Updated event',
          startAt: secondStart,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userIdOverride: 'user-1',
            eventRepository: repository,
            smartPreparationAlarmService:
                const _FakeSmartPreparationAlarmService(),
            homeWidgetService: homeWidgetService,
            loadHeaderSummary: false,
          ),
        ),
      );

      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('First event'), findsNothing);

      firstLoad.complete(initialEvents);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('First event'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.listEventsCallCount, greaterThanOrEqualTo(1));
      expect(homeWidgetService.refreshCallCount, greaterThanOrEqualTo(1));
      expect(homeWidgetService.refreshEventTitles.single, <String>[
        'First event',
      ]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('First event'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.listEventsCallCount, greaterThanOrEqualTo(2));

      secondLoad.complete(refreshedEvents);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('Updated event'), findsOneWidget);
      expect(find.text('First event'), findsNothing);
      expect(homeWidgetService.refreshCallCount, greaterThanOrEqualTo(2));
      expect(homeWidgetService.refreshEventTitles.last, <String>[
        'Updated event',
      ]);
    },
  );

  testWidgets(
    'HomeScreen writes the widget payload from fresh events after cached UI',
    (tester) async {
      final now = DateTime.now();
      final cachedEvent = EventModel(
        id: 'cached',
        userId: 'user-1',
        title: 'Cached event',
        startAt: DateTime(now.year, now.month, now.day, 9),
      );
      final freshEvent = EventModel(
        id: 'fresh',
        userId: 'user-1',
        title: 'Fresh event',
        startAt: DateTime(now.year, now.month, now.day, 10),
      );
      EventPrefetchService().store('user-1', <EventModel>[cachedEvent]);
      final repository = _QueuedEventRepository(
        responses: <Future<List<EventModel>> Function()>[
          () async => <EventModel>[freshEvent],
        ],
      );
      final homeWidgetService = _RecordingHomeWidgetService();

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userIdOverride: 'user-1',
            eventRepository: repository,
            smartPreparationAlarmService:
                const _FakeSmartPreparationAlarmService(),
            homeWidgetService: homeWidgetService,
            loadHeaderSummary: false,
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(find.text('Fresh event'), findsOneWidget);
      expect(homeWidgetService.refreshCallCount, 1);
      expect(homeWidgetService.refreshEventTitles.single, <String>[
        'Fresh event',
      ]);
    },
  );

  testWidgets(
    'HomeScreen empty voice CTA uses the tertiary accent color',
    (tester) async {
      final repository = _QueuedEventRepository(
        responses: <Future<List<EventModel>> Function()>[
          () async => const <EventModel>[],
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userIdOverride: 'user-1',
            eventRepository: repository,
            smartPreparationAlarmService:
                const _FakeSmartPreparationAlarmService(),
            homeWidgetService: _RecordingHomeWidgetService(),
            loadHeaderSummary: false,
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      final cta = find.widgetWithText(
        FilledButton,
        '새 일정 음성으로 추가하기',
      );
      expect(cta, findsOneWidget);

      final button = tester.widget<FilledButton>(cta);
      expect(
        button.style?.backgroundColor?.resolve(<WidgetState>{}),
        PlanFlowColors.tertiaryAccent,
      );
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

class _RecordingHomeWidgetService extends HomeWidgetService {
  _RecordingHomeWidgetService()
      : super(platform: const _FakeHomeWidgetPlatformForHomeScreen());

  int refreshCallCount = 0;
  final List<List<String>> refreshEventTitles = <List<String>>[];

  @override
  Future<bool> refreshScheduleFromEvents(
    List<EventModel> events, {
    DateTime? now,
    String emptyTitle = 'No upcoming events',
    int? nextTravelBufferMinutes,
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    refreshCallCount += 1;
    refreshEventTitles.add(
      events.map((event) => event.title).toList(growable: false),
    );
    return true;
  }
}

class _FakeHomeWidgetPlatformForHomeScreen extends HomeWidgetPlatform {
  const _FakeHomeWidgetPlatformForHomeScreen();

  @override
  bool get isSupported => false;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async => false;

  @override
  Future<bool> setAppGroupId(String groupId) async => false;

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    return false;
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
