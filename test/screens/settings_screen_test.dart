import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  testWidgets('SettingsScreen loads settings and shows Naver calendar actions',
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
              naver: CalendarIntegrationResult.ready(
                CalendarProvider.naver,
                message: 'Naver Calendar 권한을 사용할 수 있습니다.',
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

    expect(find.text('계정'), findsOneWidget);
    expect(find.text('06:40'), findsWidgets);
    expect(find.text('20:20'), findsWidgets);
    expect(find.text('기본 알림'), findsNothing);
    expect(find.text('저장'), findsNothing);
    expect(find.text('Naver Calendar'), findsOneWidget);
    expect(find.text('연동 해제'), findsWidgets);
    expect(find.text('네이버 동기화'), findsOneWidget);
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets(
      'SettingsScreen auto-saves setting changes and schedules briefing',
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
              naver: CalendarIntegrationResult.signedOut(
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
        naver: CalendarIntegrationResult.signedOut(CalendarProvider.naver),
      ),
      googleSyncResult: CalendarIntegrationResult.synced(
        CalendarProvider.google,
        message: 'Google Calendar 동기화가 완료되었습니다. 2개 일정을 가져왔습니다.',
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
    final syncButton =
        find.widgetWithText(FilledButton, 'Google Calendar 다시 동기화');
    await tester.scrollUntilVisible(syncButton, 200);
    await tester.ensureVisible(syncButton);
    await tester.tap(syncButton);
    await tester.pumpAndSettle();

    expect(calendarSyncService.googleSyncCallCount, 1);
    expect(calendarSyncService.lastInteractive, isTrue);
    expect(
      find.textContaining('Google Calendar 동기화가 완료되었습니다. 2개 일정을 가져왔습니다.'),
      findsWidgets,
    );
  });

  testWidgets('Naver calendar button exports events and shows feedback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final calendarSyncService = _FakeCalendarSyncService(
      summary: CalendarSyncSummary(
        google: CalendarIntegrationResult.ready(CalendarProvider.google),
        naver: CalendarIntegrationResult.ready(CalendarProvider.naver),
      ),
      naverSyncResult: CalendarIntegrationResult.synced(
        CalendarProvider.naver,
        message: 'Naver Calendar에 1개 일정을 반영했습니다.',
        syncedItems: 1,
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
    final syncButton = find.widgetWithText(FilledButton, '네이버 동기화');
    await tester.scrollUntilVisible(syncButton, 200);
    await tester.ensureVisible(syncButton);
    await tester.tap(syncButton);
    await tester.pumpAndSettle();

    expect(calendarSyncService.naverSyncCallCount, 1);
    expect(find.textContaining('Naver Calendar에 1개 일정을 반영했습니다.'), findsWidgets);
  });

  testWidgets('SettingsScreen hides notification permission controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: _FakeSettingsRepository(),
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: _FakeCalendarSyncService(
            summary: CalendarSyncSummary(
              google: CalendarIntegrationResult.ready(CalendarProvider.google),
              naver: CalendarIntegrationResult.signedOut(
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
    expect(find.text('알림 권한'), findsNothing);
    expect(find.text('알림 권한 요청/재확인'), findsNothing);
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
    this.googleSyncResult,
    this.naverSyncResult,
  }) : super(
          naverStatusProvider: () async {
            return const NaverCalendarPermissionResult(
              status: NaverCalendarPermissionStatus.unknown,
              message: '테스트 권한 상태',
            );
          },
          naverAccessTokenProvider: () async => null,
          naverStatusSaver: (_) async {},
        );

  final CalendarSyncSummary summary;
  final CalendarIntegrationResult? googleSyncResult;
  final CalendarIntegrationResult? naverSyncResult;
  int googleSyncCallCount = 0;
  int naverSyncCallCount = 0;
  bool? lastInteractive;

  @override
  Future<CalendarSyncSummary> fetchStatus() async => summary;

  @override
  Future<CalendarIntegrationResult> syncGoogleCalendar({
    bool interactive = true,
  }) async {
    googleSyncCallCount += 1;
    lastInteractive = interactive;
    return googleSyncResult ??
        CalendarIntegrationResult.synced(CalendarProvider.google);
  }

  @override
  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    naverSyncCallCount += 1;
    return naverSyncResult ??
        CalendarIntegrationResult.synced(CalendarProvider.naver);
  }
}

class _FakeNotificationService extends NotificationService {
  @override
  Future<NotificationPermissionStatus> checkPermissionStatus() async {
    return const NotificationPermissionStatus(
      notificationsEnabled: true,
      exactAlarmsEnabled: true,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }
}
