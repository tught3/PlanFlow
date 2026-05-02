import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  testWidgets('ConfirmScreen shows a pre-action card from both add buttons',
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

    await tester.ensureVisible(find.text('선행행동 추가'));
    await tester.tap(find.text('선행행동 추가'));
    await tester.pumpAndSettle();

    expect(find.text('선행행동 1'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(TextButton, '추가'));
    await tester.tap(find.widgetWithText(TextButton, '추가'));
    await tester.pumpAndSettle();

    expect(find.text('선행행동 2'), findsOneWidget);
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
    await tester.pumpAndSettle();

    expect(repository.createdEvents, hasLength(1));
    expect(
      backend.reminderPayloads.where((row) => row['type'] == 'system_alarm'),
      hasLength(1),
    );
    expect(notifications.criticalAlarmTitles, contains('성남 출발'));
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
}) {
  return {
    'title': '성남 출발',
    'start_at': (startAt ?? DateTime.now().add(const Duration(hours: 3)))
        .toIso8601String(),
    'end_at': null,
    'location': '성남',
    'memo': '테스트 일정',
    'supplies': <String>[],
    'is_critical': isCritical,
    'pre_actions': <Map<String, dynamic>>[],
    'raw_text': '내일 오전 10시에 성남으로 출발',
  };
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
  Future<EventModel> createEvent(EventModel event) async {
    final saved = EventModel(
      id: 'event-${createdEvents.length + 1}',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      memo: event.memo,
      supplies: event.supplies,
      isCritical: event.isCritical,
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

  @override
  int notificationIdFor(String id) => id.hashCode & 0x7fffffff;

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
  }) async {}

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    criticalAlarmTitles.add(title);
  }
}

class _FakeHomeWidgetService extends HomeWidgetService {
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
