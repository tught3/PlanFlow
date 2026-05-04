import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  testWidgets('SettingsScreen loads saved settings and hides Naver calendar UI',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settingsRepository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
        morningBriefingAt: '06:40',
        eveningBriefingAt: '20:20',
        defaultReminderMin: 45,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: settingsRepository,
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: _FakeCalendarSyncService(
            summary: CalendarSyncSummary(
              google: CalendarIntegrationResult.ready(
                CalendarProvider.google,
              ),
              naver: CalendarIntegrationResult.unsupported(
                CalendarProvider.naver,
              ),
            ),
          ),
          notificationService: _FakeNotificationService(),
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('06:40'), findsWidgets);
    expect(find.text('20:20'), findsWidgets);
    expect(find.text('기본 알림'), findsNothing);
    expect(find.text('저장'), findsNothing);
    expect(find.text('계정'), findsOneWidget);
    expect(find.textContaining('네이버 캘린더'), findsNothing);
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets('SettingsScreen auto-saves setting changes and schedules briefing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settingsRepository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
        morningBriefingAt: '07:10',
        eveningBriefingAt: '21:20',
        defaultReminderMin: 45,
      ),
    );
    final scheduler = _FakeBriefingSchedulerService();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: settingsRepository,
          briefingSchedulerService: scheduler,
          calendarSyncService: _FakeCalendarSyncService(
            summary: CalendarSyncSummary(
              google: CalendarIntegrationResult.ready(
                CalendarProvider.google,
              ),
              naver: CalendarIntegrationResult.unsupported(
                CalendarProvider.naver,
              ),
            ),
          ),
          notificationService: _FakeNotificationService(),
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    final transitOption = find.text('대중교통');
    await tester.scrollUntilVisible(transitOption, 200);
    await tester.ensureVisible(transitOption);
    await tester.tap(transitOption);
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.defaultReminderMin, 45);
    expect(settingsRepository.savedSettings!.travelMode, 'transit');
    expect(settingsRepository.savedSettings!.morningBriefingAt, '07:10');
    expect(settingsRepository.savedSettings!.eveningBriefingAt, '21:20');
    expect(scheduler.lastMorningTime, '07:10');
    expect(scheduler.lastEveningTime, '21:20');
    expect(scheduler.callCount, 1);
  });

  testWidgets('Google calendar button syncs interactively and shows feedback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final calendarSyncService = _FakeCalendarSyncService(
      summary: CalendarSyncSummary(
        google: CalendarIntegrationResult.ready(CalendarProvider.google),
        naver: CalendarIntegrationResult.unsupported(CalendarProvider.naver),
      ),
      syncResult: CalendarIntegrationResult.synced(
        CalendarProvider.google,
        message: 'Google Calendar 동기화가 완료되었습니다. 2개 항목을 확인했습니다.',
        syncedItems: 2,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: _FakeSettingsRepository(),
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: calendarSyncService,
          notificationService: _FakeNotificationService(),
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    final syncButton = find.widgetWithText(FilledButton, '구글 캘린더 다시 동기화');
    await tester.scrollUntilVisible(syncButton, 200);
    await tester.ensureVisible(syncButton);
    await tester.tap(syncButton);
    await tester.pumpAndSettle();

    expect(calendarSyncService.syncCallCount, 1);
    expect(calendarSyncService.lastInteractive, isTrue);
    expect(
      find.textContaining('Google Calendar 동기화가 완료되었습니다. 2개 항목을 확인했습니다.'),
      findsWidgets,
    );
  });

  testWidgets('SettingsScreen shows notification permission status',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final notificationService = _FakeNotificationService(
      status: const NotificationPermissionStatus(
        notificationsEnabled: true,
        exactAlarmsEnabled: null,
        fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: _FakeSettingsRepository(),
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: _FakeCalendarSyncService(
            summary: CalendarSyncSummary(
              google: CalendarIntegrationResult.ready(CalendarProvider.google),
              naver: CalendarIntegrationResult.unsupported(
                CalendarProvider.naver,
              ),
            ),
          ),
          notificationService: notificationService,
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    final sectionTitle = find.text('알림 권한');
    await tester.scrollUntilVisible(sectionTitle, 200);
    expect(sectionTitle, findsOneWidget);
    expect(find.text('허용됨'), findsWidgets);
    expect(find.text('지원 안 함'), findsOneWidget);
    expect(find.text('Android 설정에서 확인'), findsOneWidget);
  });

  testWidgets(
      'notification permission request rechecks status after request failure',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final notificationService = _FakeNotificationService(
      status: const NotificationPermissionStatus(
        notificationsEnabled: true,
        exactAlarmsEnabled: true,
        fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
      ),
      throwOnRequest: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: _FakeSettingsRepository(),
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: _FakeCalendarSyncService(
            summary: CalendarSyncSummary(
              google: CalendarIntegrationResult.ready(CalendarProvider.google),
              naver: CalendarIntegrationResult.unsupported(
                CalendarProvider.naver,
              ),
            ),
          ),
          notificationService: notificationService,
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    final requestButton = find.widgetWithText(
      OutlinedButton,
      '알림 권한 요청/재확인',
    );
    await tester.scrollUntilVisible(requestButton, 200);
    await tester.ensureVisible(requestButton);
    await tester.tap(requestButton);
    await tester.pumpAndSettle();

    expect(notificationService.requestCallCount, 1);
    expect(notificationService.checkCallCount, greaterThanOrEqualTo(1));
    expect(find.textContaining('앱 알림과 정확한 알람은 허용됨'), findsWidgets);
  });
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository({this.fetched});

  final UserSettingsModel? fetched;
  UserSettingsModel? savedSettings;
  final List<String> fetchUserIds = <String>[];

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    fetchUserIds.add(userId);
    return fetched;
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    savedSettings = settings;
    return settings.copyWith(id: 'settings-1');
  }
}

class _FakeBriefingSchedulerService extends BriefingSchedulerService {
  int callCount = 0;
  String? lastMorningTime;
  String? lastEveningTime;

  @override
  Future<void> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
  }) async {
    callCount += 1;
    lastMorningTime = morningTime;
    lastEveningTime = eveningTime;
  }
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({
    required this.summary,
    this.syncResult,
  });

  final CalendarSyncSummary summary;
  final CalendarIntegrationResult? syncResult;
  int syncCallCount = 0;
  bool? lastInteractive;

  @override
  Future<CalendarSyncSummary> fetchStatus() async => summary;

  @override
  Future<CalendarIntegrationResult> syncGoogleCalendar({
    bool interactive = true,
  }) async {
    syncCallCount += 1;
    lastInteractive = interactive;
    return syncResult ??
        CalendarIntegrationResult.synced(CalendarProvider.google);
  }
}

class _FakeNotificationService extends NotificationService {
  _FakeNotificationService({
    this.status = const NotificationPermissionStatus(
      notificationsEnabled: true,
      exactAlarmsEnabled: true,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    ),
    this.throwOnRequest = false,
  });

  final NotificationPermissionStatus status;
  final bool throwOnRequest;
  int checkCallCount = 0;
  int requestCallCount = 0;

  @override
  Future<NotificationPermissionStatus> checkPermissionStatus() async {
    checkCallCount += 1;
    return status;
  }

  @override
  Future<NotificationPermissionStatus> requestAndCheckPermissions() async {
    requestCallCount += 1;
    if (throwOnRequest) {
      throw StateError('request failed');
    }
    return status;
  }
}
