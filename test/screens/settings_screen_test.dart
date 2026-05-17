import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/device_calendar_service.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
    expect(find.text('캘린더 연동', skipOffstage: false), findsOneWidget);
    expect(find.text('연동 해제', skipOffstage: false), findsWidgets);
    expect(find.text('네이버 일정 동기화', skipOffstage: false), findsOneWidget);
    expect(find.text('저장 누락 진단'), findsNothing);
    expect(find.text('Naver CalDAV 직접 연결'), findsNothing);
    expect(find.text('네이버 CalDAV 연결 테스트'), findsNothing);
    expect(find.text('네이버 CalDAV 일정 가져오기'), findsNothing);
    final feedbackButton =
        find.byKey(const ValueKey('settings-feedback-report-button'));
    await _scrollUntilHitTestable(tester, feedbackButton);
    expect(find.text('문제 신고 / 의견 보내기'), findsOneWidget);
    expect(feedbackButton, findsOneWidget);
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets('SettingsScreen hides calendar auto-sync summary card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'calendar_sync:last_reason': 'app_resumed',
      'calendar_sync:last_attempt_at': '2026-05-09T08:30:00.000',
      'calendar_sync:last_completed': <String>['google_auto_sync'],
      'calendar_sync:last_failed': <String>['naver_caldav_auto_import'],
      'calendar_sync:provider:google_auto_sync:status': 'connected',
      'calendar_sync:provider:google_auto_sync:message': '정상 동기화됨',
      'calendar_sync:provider:google_auto_sync:checked_at':
          '2026-05-09T08:30:00.000',
      'calendar_sync:provider:naver_caldav_auto_import:status': 'attention',
      'calendar_sync:provider:naver_caldav_auto_import:message':
          'Naver CalDAV 아이디 또는 앱 비밀번호를 확인해 주세요.',
      'calendar_sync:provider:naver_caldav_auto_import:checked_at':
          '2026-05-09T08:31:00.000',
    });

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
    final googleStatus = find.text('Google Calendar');
    await _scrollUntilHitTestable(tester, googleStatus);

    expect(
      find.byKey(const ValueKey('settings-calendar-auto-sync-status-card')),
      findsNothing,
    );
    expect(find.text('자동 동기화 상태'), findsNothing);
    expect(find.text('최근 실행: 2026-05-09 08:30 · 앱 복귀'), findsNothing);
    expect(find.text('Google Calendar · 2026-05-09 08:30'), findsNothing);
    expect(find.text('Naver CalDAV · 2026-05-09 08:31'), findsNothing);
    expect(find.text('Google Calendar'), findsOneWidget);
    expect(find.text('Google Calendar 다시 동기화'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows briefing and departure runtime status',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'briefing:next_morning_at': '2026-05-09T07:30:00.000',
      'briefing:next_evening_at': '2026-05-09T21:00:00.000',
      'briefing:morning_scheduled': true,
      'briefing:evening_scheduled': false,
      'briefing:last_executed_type': 'morning',
      'briefing:last_executed_at': '2026-05-09T07:31:00.000',
      'briefing:last_execution_delivered': true,
      'briefing:last_execution_message': '모닝 브리핑을 재생했습니다.',
      'departure_alarm:last_event_id': 'event-1',
      'departure_alarm:last_event_title': '대전 성심당',
      'departure_alarm:last_status': 'scheduled',
      'departure_alarm:last_checked_at': '2026-05-09T08:00:00.000',
      'departure_alarm:last_notify_at': '2026-05-09T10:00:00.000',
      'departure_alarm:last_travel_minutes': 90,
      'departure_alarm:last_monitor_at': '2026-05-09T08:10:00.000',
      'departure_alarm:next_monitor_at': '2026-05-09T08:40:00.000',
      'departure_alarm:last_monitor_scheduled': 1,
      'departure_alarm:last_monitor_skipped': 2,
      'departure_alarm:monitor_scheduled': true,
    });

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
    final briefingCard =
        find.byKey(const ValueKey('settings-briefing-runtime-status-card'));
    await _scrollUntilHitTestable(tester, briefingCard);

    expect(find.text('브리핑 예약 상태'), findsOneWidget);
    expect(find.text('예약됨 · 2026-05-09 07:30'), findsOneWidget);
    expect(find.text('예약 실패 · 2026-05-09 21:00'), findsOneWidget);
    expect(
      find.text('최근 재생: 모닝 · 2026-05-09 07:31 · 성공'),
      findsOneWidget,
    );
    expect(find.text('모닝 브리핑을 재생했습니다.'), findsOneWidget);

    final departureCard = find.byKey(
      const ValueKey('settings-departure-alarm-runtime-status-card'),
    );
    await _scrollUntilHitTestable(tester, departureCard);

    expect(find.text('출발 알림 상태'), findsOneWidget);
    expect(find.text('대전 성심당'), findsOneWidget);
    expect(
      find.text(
        '예약됨 · 확인 2026-05-09 08:00 · 알림 2026-05-09 10:00 · 이동 90분',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '최근 모니터 2026-05-09 08:10 · 예약 1개 · 건너뜀 2개 · 다음 모니터 예약됨 · 2026-05-09 08:40',
      ),
      findsOneWidget,
    );
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

  testWidgets('SettingsScreen saves preferred map provider choice',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settingsRepository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
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
    final preferredMapSelector = find.byKey(
      const ValueKey('settings-preferred-map-provider-selector'),
    );
    await _scrollUntilHitTestable(tester, preferredMapSelector);

    await tester.tap(
      find.descendant(
        of: preferredMapSelector,
        matching: find.text('Google 지도'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings, isNotNull);
    expect(settingsRepository.savedSettings!.preferredMapProvider, 'google');

    await tester.tap(
      find.descendant(
        of: preferredMapSelector,
        matching: find.text('TMAP'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settingsRepository.savedSettings!.preferredMapProvider, 'tmap');
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
      syncDelay: const Duration(seconds: 1),
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
    await tester.pump();

    expect(
      find.textContaining('앱을 백그라운드로 보내도 동기화는 계속됩니다.'),
      findsWidgets,
    );
    expect(
      find.textContaining('완료되면 다시 알려드릴게요.'),
      findsWidgets,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(calendarSyncService.naverSyncCallCount, 0);
    expect(naverCalDavService.syncCallCount, 1);
  });

  testWidgets('logout does not clear saved Naver CalDAV credentials',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => authProvider.setUser(null));

    authProvider.setUser('user-1');

    final authService = _FakeAuthService();
    final naverCalDavService = _FakeNaverCalDavService(
      initialHasCredentials: true,
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => SettingsScreen(
            settingsRepository: _FakeSettingsRepository(),
            briefingSchedulerService: _FakeBriefingSchedulerService(),
            calendarSyncService: _FakeCalendarSyncService(
              summary: CalendarSyncSummary(
                google:
                    CalendarIntegrationResult.ready(CalendarProvider.google),
                naver: CalendarIntegrationResult.ready(CalendarProvider.naver),
              ),
            ),
            notificationService: _FakeNotificationService(),
            authService: authService,
            naverCalDavService: naverCalDavService,
            userId: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.login,
          builder: (context, state) => const Scaffold(
            body: SizedBox.shrink(),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );

    await tester.pumpAndSettle();
    await _scrollUntilHitTestable(
      tester,
      find.text('로그아웃'),
      maxScrolls: 16,
    );
    await tester.tap(find.text('로그아웃').hitTestable().first);
    await tester.pumpAndSettle();

    expect(authService.signOutCallCount, 1);
    expect(naverCalDavService.clearCallCount, 0);
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
    this.syncDelay = Duration.zero,
    this.syncResult = const NaverCalDavSyncResult(
      success: true,
      message: '네이버 CalDAV 연결은 성공했지만 가져올 일정이 없습니다.',
    ),
  });

  final bool initialHasCredentials;
  final Duration syncDelay;
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
    if (syncDelay > Duration.zero) {
      await Future<void>.delayed(syncDelay);
    }
    return syncResult;
  }

  @override
  Future<void> clearCredentials() async {
    clearCallCount += 1;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeAuthService extends AuthService {
  _FakeAuthService()
      : super(
          client: SupabaseClient(
            'https://example.com',
            'public-anon-key',
            authOptions: const FlutterAuthClientOptions(
              detectSessionInUri: false,
              autoRefreshToken: false,
            ),
          ),
        );

  int signOutCallCount = 0;

  @override
  Future<void> signOut() async {
    signOutCallCount += 1;
    authProvider.setUser(null);
  }
}
