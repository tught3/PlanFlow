import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/region_settings.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  setUp(() {
    PlanFlowRegionController.instance.reset();
  });

  testWidgets(
      'ConfirmScreen shows a smart preparation card from both add buttons',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    expect(find.text('스마트 준비 알람 1'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(TextButton, '추가'));
    await tester.tap(find.widgetWithText(TextButton, '추가'));
    await tester.pumpAndSettle();

    expect(find.text('스마트 준비 알람 2'), findsOneWidget);
  });

  testWidgets(
      'ConfirmScreen schedules critical alarm when important is enabled',
      (tester) async {
    final backend = _FakeConfirmBackend();
    final notifications = _FakeNotificationService();
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            isCritical: true,
            startAt: DateTime.now().add(const Duration(hours: 2)),
          ),
          backend: backend,
          eventRepository: repository,
          notificationService: notifications,
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0;
        i < 30 && notifications.criticalAlarmTitles.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(
      backend.reminderPayloads.where((row) => row['type'] == 'system_alarm'),
      hasLength(1),
    );
    expect(notifications.criticalAlarmTitles, contains('성남 출발'));
    expect(
      notifications.criticalAlarmNotifyAts.single.difference(
        repository.createdEvents.single.startAt!.subtract(
          const Duration(minutes: 60),
        ),
      ),
      Duration.zero,
    );
  });

  testWidgets('ConfirmScreen warns before saving overlapping events',
      (tester) async {
    final repository = _FakeEventRepository();
    final existingStart = DateTime.now().add(const Duration(hours: 3));
    repository.createdEvents.add(
      EventModel(
        id: 'existing-1',
        userId: 'user-1',
        title: '겹치는 일정',
        startAt: existingStart,
        endAt: existingStart.add(const Duration(hours: 1)),
      ),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            startAt: existingStart.add(const Duration(minutes: 15)),
            endAt: existingStart.add(const Duration(minutes: 45)),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pumpAndSettle();

    expect(find.text('일정이 겹쳐요'), findsOneWidget);
    expect(find.text('계속 저장'), findsOneWidget);

    await tester.tap(find.text('중단'));
    await tester.pumpAndSettle();

    expect(repository.createdEvents, hasLength(1));
    expect(find.text('일정이 겹쳐요'), findsNothing);
  });

  testWidgets('ConfirmScreen opens location picker even when location is empty',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(location: ''),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );

    await tester.ensureVisible(find.byTooltip('지도에서 위치 선택'));
    await tester.tap(find.byTooltip('지도에서 위치 선택'));
    await tester.pumpAndSettle();

    expect(find.text('지도에서 장소 선택'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('검색'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'ConfirmScreen keeps user-edited fields while hydrating and does not seed memo from raw text',
      (tester) async {
    final parseCompleter = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '초기 제목',
            location: '',
            memo: null,
            rawText: '내일 오전 9시에 대전출발',
          )
            ..['parse_pending'] = true
            ..['manual_text_confirmed'] = true,
          gptService: _DeferredGptService(parseCompleter.future),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pump();

    final titleField = find.widgetWithText(TextFormField, '제목');
    final locationField = find.widgetWithText(TextFormField, '장소');
    final memoField = find.widgetWithText(TextFormField, '설명');

    expect(tester.widget<TextFormField>(memoField).controller?.text, isEmpty);

    await tester.enterText(titleField, '사용자 제목');
    await tester.enterText(memoField, '사용자 메모');
    await tester.pump();

    parseCompleter.complete(
      <String, dynamic>{
        'title': 'AI 제목',
        'location': 'AI 장소',
        'memo': 'AI 메모',
        'start_at': DateTime(2026, 5, 11, 9).toIso8601String(),
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      },
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextFormField>(titleField).controller?.text, '사용자 제목');
    expect(
        tester.widget<TextFormField>(locationField).controller?.text, 'AI 장소');
    expect(tester.widget<TextFormField>(memoField).controller?.text, '사용자 메모');
    expect(find.text('AI 제목'), findsNothing);
    expect(find.text('AI 메모'), findsNothing);
  });

  testWidgets('ConfirmScreen stores Korean wall time as UTC once',
      (tester) async {
    final repository = _FakeEventRepository();
    final start = DateTime(2026, 5, 13, 10);
    final end = DateTime(2026, 5, 14, 9);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(startAt: start, endAt: end),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(saved.startAt, DateTime.utc(2026, 5, 13, 1));
    expect(planflowLocal(saved.startAt!), start);
    expect(planflowLocal(saved.endAt!), end);
    expect(saved.isMultiDay, isTrue);
  });

  testWidgets('ConfirmScreen shows supplies as compact editable rows',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            supplies: const <String>['물', '충전기'],
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('물'));

    expect(find.text('물'), findsOneWidget);
    expect(find.text('충전기'), findsOneWidget);
    expect(find.textContaining('체크리스트로'), findsNothing);
    expect(find.text('진행 중'), findsNothing);
  });
  testWidgets('ConfirmScreen asks purpose for ambiguous hospital place only',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '병원',
            location: '병원',
            rawText: '내일 오전 10시 병원',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 목적을 선택해 주세요'));

    expect(find.text('일정 목적을 선택해 주세요'), findsOneWidget);
    expect(find.text('진료/검사'), findsOneWidget);
    expect(find.text('업무/영업'), findsOneWidget);
    expect(find.text('병문안'), findsOneWidget);

    await tester.tap(find.text('병문안'));
    await tester.pumpAndSettle();

    expect(find.text('꽃이나 선물 챙기기'), findsOneWidget);
    expect(find.text('병원 준비사항 확인'), findsNothing);
    expect(find.text('금식/복약 안내 확인'), findsNothing);
  });
}

Widget _testApp(Widget child) {
  final router = GoRouter(
    initialLocation: AppRoutes.confirm,
    routes: [
      GoRoute(
        path: AppRoutes.confirm,
        builder: (_, __) => child,
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, __) => const Scaffold(body: Text('홈')),
      ),
      GoRoute(
        path: AppRoutes.calendar,
        builder: (_, __) => const Scaffold(body: Text('일정')),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, __) => const Scaffold(body: Text('설정')),
      ),
    ],
  );

  return MaterialApp.router(routerConfig: router);
}

Map<String, dynamic> _parsedSchedule({
  bool isCritical = false,
  DateTime? startAt,
  DateTime? endAt,
  List<String> supplies = const <String>[],
  String? title,
  String? location,
  String? rawText,
  String? memo = '테스트 일정',
}) {
  return {
    'title': title ?? '성남 출발',
    'start_at': (startAt ?? DateTime.now().add(const Duration(hours: 3)))
        .toIso8601String(),
    'end_at': endAt?.toIso8601String(),
    'location': location ?? '성남',
    'memo': memo,
    'supplies': supplies,
    'is_critical': isCritical,
    'pre_actions': <Map<String, dynamic>>[],
    'raw_text': rawText ?? '내일 오전 10시에 성남으로 출발',
  };
}

class _DeferredGptService extends GptService {
  _DeferredGptService(this._resultFuture);

  final Future<Map<String, dynamic>> _resultFuture;

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    return _resultFuture;
  }
}

class _EmptyLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(String query) async {
    return const <LocationLookupResult>[];
  }
}

class _FakeConfirmBackend extends ConfirmScreenBackend {
  final reminderPayloads = <Map<String, dynamic>>[];

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async {
    return const <String>[];
  }

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    reminderPayloads.addAll(payloads);
  }

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _FakeEventRepository extends EventRepository {
  final createdEvents = <EventModel>[];

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return createdEvents.where((event) {
      if (excludedEventId != null && event.id == excludedEventId) {
        return false;
      }
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
      return startAt.toUtc().isBefore(rangeEnd.toUtc()) &&
          rangeStart.toUtc().isBefore(endAt.toUtc());
    }).toList(growable: false);
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    final saved = EventModel(
      id: 'event-${createdEvents.length + 1}',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      isCritical: event.isCritical,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      category: event.category,
    );
    createdEvents.add(saved);
    return saved;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return createdEvents.where((event) => event.id == eventId).firstOrNull;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => createdEvents;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeNotificationService extends NotificationService {
  final criticalAlarmTitles = <String>[];
  final criticalAlarmNotifyAts = <DateTime>[];

  @override
  int notificationIdFor(String id) => id.hashCode & 0x7fffffff;

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {}

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    criticalAlarmTitles.add(title);
    criticalAlarmNotifyAts.add(notifyAt);
  }

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    criticalAlarmTitles.add(title);
    criticalAlarmNotifyAts.add(notifyAt);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}

class _FakeHomeWidgetService extends HomeWidgetService {
  @override
  Future<bool> updateScheduleData({
    required HomeWidgetNextEventData nextEvent,
    List<HomeWidgetListEventData> todayEvents =
        const <HomeWidgetListEventData>[],
    DateTime? month,
    List<HomeWidgetMonthDayData> monthDays = const <HomeWidgetMonthDayData>[],
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    return true;
  }

  @override
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
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    return true;
  }
}
