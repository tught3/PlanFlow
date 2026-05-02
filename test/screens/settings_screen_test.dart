import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';

void main() {
  testWidgets('SettingsScreen loads saved settings and shows Naver paused note',
      (tester) async {
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
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('06:40'), findsWidgets);
    expect(find.text('20:20'), findsWidgets);
    expect(find.text('45분 알림'), findsOneWidget);
    expect(
      find.text('네이버 캘린더는 1차에서 보류합니다. 이후 단계에서 다시 연결할 예정입니다.'),
      findsOneWidget,
    );
    expect(settingsRepository.fetchUserIds.single, 'user-1');
  });

  testWidgets('SettingsScreen saves settings and schedules briefing times',
      (tester) async {
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
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('60분'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('저장'), 200);
    await tester.tap(find.text('저장'));
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
          userId: 'user-1',
          envConfigured: false,
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Google Calendar 다시 동기화'), 200);
    await tester.tap(find.text('Google Calendar 다시 동기화'));
    await tester.pumpAndSettle();

    expect(calendarSyncService.syncCallCount, 1);
    expect(calendarSyncService.lastInteractive, isTrue);
    expect(
      find.textContaining('Google Calendar 동기화가 완료되었습니다. 2개 항목을 확인했습니다.'),
      findsOneWidget,
    );
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
