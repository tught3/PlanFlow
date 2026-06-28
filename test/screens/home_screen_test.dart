import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/home/home_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
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

  test('homeVisiblePastTodayEvents keeps all latest same-minute past events',
      () {
    final older = EventModel(
      id: 'older',
      userId: 'user-1',
      title: '오래전 일정',
      startAt: DateTime(2026, 5, 28, 8, 30),
    );
    final latestA = EventModel(
      id: 'latest-a',
      userId: 'user-1',
      title: '같은 시간 일정 A',
      startAt: DateTime(2026, 5, 28, 9, 0, 10),
    );
    final latestB = EventModel(
      id: 'latest-b',
      userId: 'user-1',
      title: '같은 시간 일정 B',
      startAt: DateTime(2026, 5, 28, 9, 0, 50),
    );

    final visible = homeVisiblePastTodayEvents(<EventModel>[
      latestB,
      older,
      latestA,
    ]);

    expect(
      visible.map((event) => event.id),
      <String>['latest-a', 'latest-b'],
    );
  });

  testWidgets('HomeScreen shows every past event at the latest same time',
      (tester) async {
    final now = DateTime(2026, 5, 28, 12);
    final latestStart = now.subtract(const Duration(hours: 1));
    final repository = _QueuedEventRepository(
      responses: <Future<List<EventModel>> Function()>[
        () async => <EventModel>[
              EventModel(
                id: 'older',
                userId: 'user-1',
                title: '오래전 일정',
                startAt: latestStart.subtract(const Duration(hours: 1)),
              ),
              EventModel(
                id: 'same-a',
                userId: 'user-1',
                title: '같은 시간 일정 A',
                startAt: latestStart,
              ),
              EventModel(
                id: 'same-b',
                userId: 'user-1',
                title: '같은 시간 일정 B',
                startAt: latestStart.add(const Duration(seconds: 30)),
              ),
            ],
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
          nowProvider: () => now,
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('같은 시간 일정 A'), findsOneWidget);
    expect(find.text('같은 시간 일정 B'), findsOneWidget);
    expect(find.text('오래전 일정'), findsNothing);
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
        '음성으로 새 일정 추가하기',
      );
      expect(cta, findsOneWidget);

      final button = tester.widget<FilledButton>(cta);
      expect(
        button.style?.backgroundColor?.resolve(<WidgetState>{}),
        PlanFlowColors.tertiaryAccent,
      );
    },
  );

  // 회귀: 좌표 못 찾는 일정이 매 홈 새로고침마다 외부 지오코딩 API를 재호출해
  // tmap_poi 800회까지 폭주하던 사건(2026-06-28). 근본 2종:
  //  (1) _resolveEventsMissingCoords가 끝에서 무조건 notifyChanged를 쏴
  //      홈 리로드 → 좌표 보정 → notifyChanged의 자기피드백 루프를 만들고,
  //  (2) 실패(빈 결과)한 (일정,위치)에 쿨다운이 없어 매 패스마다 재검색.
  // 수정: 재진입 가드 + (일정,위치) 24h 쿨다운 + 좌표를 실제로 채운 경우에만
  //       notifyChanged. 이 테스트는 반복 새로고침에도 재검색이 1회로 묶이는지 본다.
  testWidgets(
    'HomeScreen는 좌표 못 찾는 일정을 반복 새로고침에도 한 번만 검색한다(폭주 방지)',
    (tester) async {
      final now = DateTime(2026, 6, 28, 12);
      final unresolved = EventModel(
        id: 'no-coords-1',
        userId: 'user-1',
        title: '좌표 없는 일정',
        startAt: DateTime(2026, 6, 28, 13),
        location: '존재하지 않는 장소 zzz',
      );
      final repository =
          _StuckUnresolvedEventRepository(<EventModel>[unresolved]);
      final lookup = _CountingLocationLookupService();

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userIdOverride: 'user-1',
            eventRepository: repository,
            smartPreparationAlarmService:
                const _FakeSmartPreparationAlarmService(),
            homeWidgetService: _RecordingHomeWidgetService(),
            locationLookupService: lookup,
            loadHeaderSummary: false,
            nowProvider: () => now,
          ),
        ),
      );

      // 초기 로드 → 좌표 보정 1회(검색 1회).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        lookup.searchCallCount,
        1,
        reason: '미해결 일정은 처음 한 번만 검색해야 한다',
      );

      // 홈 새로고침(앱 재개)을 여러 번 일으켜도 쿨다운 때문에 재검색 금지.
      for (var i = 0; i < 5; i++) {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      expect(
        lookup.searchCallCount,
        1,
        reason: '반복 새로고침에도 같은 미해결 (일정,위치)는 재검색되지 않아야 한다 '
            '— 자기피드백 루프 + 무쿨다운이 tmap_poi 800회 폭주를 일으켰던 회귀',
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

/// 매 listEvents 호출마다 같은 (미해결) 일정 목록을 반환해, 반복 새로고침에도
/// 좌표 보정 대상이 계속 남아있는 폭주 시나리오를 재현한다.
class _StuckUnresolvedEventRepository extends _QueuedEventRepository {
  _StuckUnresolvedEventRepository(this._events)
      : super(responses: const <Future<List<EventModel>> Function()>[]);

  final List<EventModel> _events;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listEventsCallCount += 1;
    return _events;
  }
}

/// search() 호출 횟수를 세고 항상 빈 결과(좌표 못 찾음)를 돌려주는 fake.
/// 빈 결과 = 폭주를 유발하던 "영영 못 찾는 위치" 케이스.
class _CountingLocationLookupService extends LocationLookupService {
  int searchCallCount = 0;
  final List<String> searchedQueries = <String>[];

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchCallCount += 1;
    searchedQueries.add(query);
    return const <LocationLookupResult>[];
  }
}
