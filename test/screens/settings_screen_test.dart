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
    expect(find.text('45분 알림'), findsOneWidget);
    expect(find.textContaining('네이버'), findsNothing);
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets('SettingsScreen saves settings and schedules briefing times',
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
    await tester.tap(find.text('60분'));
    await tester.pump();
    final saveButton = find.widgetWithText(FilledButton, '저장');
    await tester.scrollUntilVisible(saveButton, 200);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.defaultReminderMin, 60);
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
      find.textContaining('구글 캘린더 동기화가 완료되었습니다. 2개 항목을 확인했습니다.'),
      findsOneWidget,
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
  });

  final NotificationPermissionStatus status;

  @override
  Future<NotificationPermissionStatus> checkPermissionStatus() async => status;

  @override
  Future<NotificationPermissionStatus> requestAndCheckPermissions() async =>
      status;
}
