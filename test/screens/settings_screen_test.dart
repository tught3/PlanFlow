import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/device_calendar_service.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  testWidgets('SettingsScreen loads settings and shows Naver calendar actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
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
          naverCalDavService:
              _FakeNaverCalDavService(initialHasCredentials: true),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('계정'), findsOneWidget);
    expect(find.text('06:40'), findsWidgets);
    expect(find.text('20:20'), findsWidgets);
    expect(find.text('기본 알림'), findsNothing);
    expect(find.text('저장'), findsNothing);
    expect(find.text('변경 즉시 적용'), findsNothing);
    expect(find.text('네이버 캘린더'), findsOneWidget);
    expect(find.text('연동 해제'), findsWidgets);
    expect(find.text('네이버 일정 동기화'), findsOneWidget);
    expect(find.text('Naver CalDAV 직접 연결'), findsNothing);
    expect(find.text('네이버 CalDAV 연결 테스트'), findsNothing);
    expect(find.text('네이버 CalDAV 일정 가져오기'), findsNothing);
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets(
      'SettingsScreen auto-saves setting changes and schedules briefing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
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
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final travelModeSelector =
        find.byKey(const ValueKey('settings-travel-mode-selector'));
    await _scrollUntilHitTestable(tester, travelModeSelector);
    await tester.tap(
      find.descendant(
        of: travelModeSelector,
        matching: find.text('대중교통'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.defaultReminderMin, 45);
    expect(settingsRepository.savedSettings!.travelMode, 'transit');
    expect(settingsRepository.savedSettings!.morningBriefingAt, '07:10');
    expect(settingsRepository.savedSettings!.eveningBriefingAt, '21:20');
    expect(scheduler.lastMorningTime, '07:10');
    expect(scheduler.lastEveningTime, '21:20');
    expect(scheduler.callCount, 2);
  });

  testWidgets('SettingsScreen saves smart prep alarm settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settingsRepository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
        prepTimeMin: 30,
        prepPreAlarmOffset: 30,
        departPreAlarmOffset: 30,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: settingsRepository,
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
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final section = find.text('스마트 준비 알람 설정');
    await _scrollUntilHitTestable(tester, section);
    expect(section, findsOneWidget);
    expect(find.text('하루 평균 준비 시간'), findsOneWidget);
    expect(find.text('준비 시작 사전 알림'), findsOneWidget);
    expect(find.text('출발 사전 알림'), findsOneWidget);

    final prepTimeSelector =
        find.byKey(const ValueKey('settings-prep-time-selector'));
    await _scrollUntilHitTestable(tester, prepTimeSelector);
    await tester.tap(
      find.descendant(
        of: prepTimeSelector,
        matching: find.text('45분'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.prepTimeMin, 45);
    expect(settingsRepository.savedSettings!.prepPreAlarmOffset, 30);
    expect(settingsRepository.savedSettings!.departPreAlarmOffset, 30);

    final prepPreAlarmSelector =
        find.byKey(const ValueKey('settings-prep-pre-alarm-selector'));
    await _scrollUntilHitTestable(tester, prepPreAlarmSelector);
    await tester.tap(
      find.descendant(
        of: prepPreAlarmSelector,
        matching: find.text('둘 다'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings!.prepPreAlarmOffset, 31);

    final departPreAlarmSelector =
        find.byKey(const ValueKey('settings-depart-pre-alarm-selector'));
    await _scrollUntilHitTestable(tester, departPreAlarmSelector);
    await tester.tap(
      find.descendant(
        of: departPreAlarmSelector,
        matching: find.text('둘 다'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings!.departPreAlarmOffset, 31);
  });

  testWidgets('SettingsScreen saves voice auto-start toggle', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settingsRepository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
        voiceAutoStart: true,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: settingsRepository,
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
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final voiceAutoStartSelector =
        find.byKey(const ValueKey('settings-voice-auto-start-selector'));
    await _scrollUntilHitTestable(tester, voiceAutoStartSelector);
    await tester.tap(voiceAutoStartSelector.hitTestable().first);
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.voiceAutoStart, isFalse);
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
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final syncButton =
        find.byKey(const ValueKey('settings-google-calendar-sync-button'));
    await _scrollUntilHitTestable(tester, syncButton);
    await tester.tap(syncButton.hitTestable().first);
    await tester.pumpAndSettle();

    expect(calendarSyncService.googleSyncCallCount, 1);
    expect(calendarSyncService.lastInteractive, isTrue);
    expect(
      find.textContaining('Google Calendar 동기화가 완료되었습니다. 2개 일정을 가져왔습니다.'),
      findsWidgets,
    );
  });

  testWidgets('Naver calendar button runs CalDAV quick sync and shows feedback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final calendarSyncService = _FakeCalendarSyncService(
      summary: CalendarSyncSummary(
        google: CalendarIntegrationResult.ready(CalendarProvider.google),
        naver: CalendarIntegrationResult.signedOut(CalendarProvider.naver),
      ),
    );
    final naverCalDavService = _FakeNaverCalDavService(
      initialHasCredentials: true,
      syncResult: const NaverCalDavSyncResult(
        success: true,
        message: '네이버 CalDAV 일정 1개를 PlanFlow로 가져왔습니다.',
        createdOrUpdated: 1,
        events: 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsRepository: _FakeSettingsRepository(),
          briefingSchedulerService: _FakeBriefingSchedulerService(),
          calendarSyncService: calendarSyncService,
          notificationService: _FakeNotificationService(),
          naverCalDavService: naverCalDavService,
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final syncButton =
        find.byKey(const ValueKey('settings-naver-calendar-sync-button'));
    await _scrollUntilHitTestable(tester, syncButton);
    await tester.tap(syncButton.hitTestable().first);
    await tester.pumpAndSettle();

    expect(calendarSyncService.naverSyncCallCount, 0);
    expect(naverCalDavService.syncCallCount, 1);
    expect(
      find.textContaining('네이버 CalDAV 일정 1개를 PlanFlow로 가져왔습니다.'),
      findsWidgets,
    );
  });

  testWidgets('device Naver calendar import button imports phone calendars',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final deviceCalendarService = _FakeDeviceCalendarService(
      result: const DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.imported,
        message: '휴대폰 내부 캘린더 일정 2개를 PlanFlow로 가져왔습니다.',
        importedCount: 2,
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
              naver: CalendarIntegrationResult.ready(CalendarProvider.naver),
            ),
          ),
          deviceCalendarService: deviceCalendarService,
          notificationService: _FakeNotificationService(),
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    final importButton = find.byKey(
      const ValueKey('settings-device-calendar-import-button'),
    );
    await _scrollUntilHitTestable(tester, importButton);
    await tester.tap(importButton.hitTestable().first);
    await tester.pumpAndSettle();

    expect(deviceCalendarService.importCallCount, 1);
    expect(
      find.textContaining('휴대폰 내부 캘린더 일정 2개를 PlanFlow로 가져왔습니다.'),
      findsWidgets,
    );
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
          naverCalDavService: _FakeNaverCalDavService(),
          userId: 'user-1',
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('알림 권한'), findsNothing);
    expect(find.text('알림 권한 요청/재확인'), findsNothing);
  });
}

Future<void> _scrollUntilHitTestable(
  WidgetTester tester,
  Finder finder, {
  int maxScrolls = 12,
}) async {
  for (var i = 0; i < maxScrolls; i += 1) {
    if (finder.hitTestable().evaluate().isNotEmpty) {
      return;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
    await tester.pumpAndSettle();
  }
  expect(finder.hitTestable(), findsWidgets);
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
  Future<BriefingDailyScheduleResult> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
  }) async {
    callCount += 1;
    lastMorningTime = morningTime;
    lastEveningTime = eveningTime;
    return BriefingDailyScheduleResult(
      morning: BriefingScheduleEntry(
        scheduledAt: DateTime(2026, 5, 7, 7, 30),
        scheduled: true,
      ),
      evening: BriefingScheduleEntry(
        scheduledAt: DateTime(2026, 5, 7, 21),
        scheduled: true,
      ),
    );
  }
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({
    required this.summary,
    this.googleSyncResult,
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
    return CalendarIntegrationResult.synced(CalendarProvider.naver);
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

class _FakeDeviceCalendarService extends DeviceCalendarService {
  _FakeDeviceCalendarService({required this.result})
      : super(
          gateway: _FakeDeviceCalendarGateway(),
          eventRepository: _FakeDeviceEventRepository(),
          currentUserId: 'user-1',
        );

  final DeviceCalendarImportResult result;
  int importCallCount = 0;

  @override
  Future<DeviceCalendarImportResult> importNaverEvents({
    String? userId,
    DateTime? startAt,
    DateTime? endAt,
  }) async {
    importCallCount += 1;
    return result;
  }
}

class _FakeDeviceCalendarGateway implements DeviceCalendarGateway {
  @override
  Future<bool> checkCalendarPermission() async => true;

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendarEvents({
    required List<String> calendarIds,
    required DateTime startAt,
    required DateTime endAt,
  }) async {
    return const [];
  }

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendars() async => const [];

  @override
  Future<bool> requestCalendarPermission() async => true;

  @override
  Future<bool> upsertDeviceCalendarEvent(EventModel event) async => true;
}

class _FakeDeviceEventRepository extends EventRepository {
  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => const [];

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeNaverCalDavService extends NaverCalDavService {
  _FakeNaverCalDavService({
    this.initialHasCredentials = false,
    this.syncResult = const NaverCalDavSyncResult(
      success: true,
      message: '네이버 CalDAV 연결은 성공했지만 가져올 일정이 없습니다.',
    ),
  });

  final bool initialHasCredentials;
  final NaverCalDavSyncResult syncResult;
  int syncCallCount = 0;
  int clearCallCount = 0;

  @override
  Future<bool> hasCredentials() async => initialHasCredentials;

  @override
  Future<NaverCalDavConnectionResult> testConnection({
    required String naverId,
    required String appPassword,
    bool saveOnSuccess = false,
  }) async {
    return const NaverCalDavConnectionResult(
      status: NaverCalDavConnectionStatus.success,
      message: '네이버 CalDAV 연결 테스트에 성공했습니다.',
    );
  }

  @override
  Future<NaverCalDavSyncResult> syncAll({
    String? userId,
    DateTime? from,
    DateTime? to,
    NaverCalDavSyncMode mode = NaverCalDavSyncMode.custom,
    bool skipUnchanged = true,
    bool diagnosticImport = false,
    NaverCalDavProgressCallback? onProgress,
  }) async {
    syncCallCount += 1;
    onProgress?.call(
      NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.saving,
        message: '일정을 저장하는 중입니다.',
        processedEvents: syncResult.events,
        totalEvents: syncResult.events,
        savedEvents: syncResult.createdOrUpdated,
        skippedEvents: syncResult.skipped,
        failedEvents: syncResult.failed,
      ),
    );
    return syncResult;
  }

  @override
  Future<void> clearCredentials() async {
    clearCallCount += 1;
  }

  @override
  Future<void> dispose() async {}
}
