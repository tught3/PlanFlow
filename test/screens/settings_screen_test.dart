import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/calendar_sync_service.dart';

void main() {
  testWidgets('SettingsScreen renders calendar status from the service',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          envConfigured: false,
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
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(find.text('구글 캘린더'), findsOneWidget);
    expect(find.text('사용 가능'), findsOneWidget);
    expect(find.text('동기화'), findsOneWidget);
    expect(find.text('네이버 캘린더'), findsOneWidget);
    expect(find.text('지원 전'), findsOneWidget);
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
          envConfigured: false,
          calendarSyncService: calendarSyncService,
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('동기화'), 300);
    await tester.tap(find.text('동기화'));
    await tester.pumpAndSettle();

    expect(calendarSyncService.syncCallCount, 1);
    expect(calendarSyncService.lastInteractive, isTrue);
    expect(find.textContaining('구글 캘린더 동기화가 완료되었습니다'), findsOneWidget);
  });

  testWidgets('Google calendar button is disabled while sync is running',
      (tester) async {
    final syncCompleter = Completer<CalendarIntegrationResult>();
    final calendarSyncService = _FakeCalendarSyncService(
      summary: CalendarSyncSummary(
        google: CalendarIntegrationResult.ready(CalendarProvider.google),
        naver: CalendarIntegrationResult.unsupported(CalendarProvider.naver),
      ),
      syncCompleter: syncCompleter,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          envConfigured: false,
          calendarSyncService: calendarSyncService,
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('동기화'), 300);
    await tester.tap(find.text('동기화'));
    await tester.pump();

    final syncingButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('동기화 중...'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(syncingButton.onPressed, isNull);

    syncCompleter.complete(
      CalendarIntegrationResult.signedOut(CalendarProvider.google),
    );
    await tester.pumpAndSettle();

    expect(calendarSyncService.syncCallCount, 1);
    expect(find.textContaining('구글 계정 로그인이 완료되지 않았습니다'), findsOneWidget);
  });
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({
    required this.summary,
    this.syncResult,
    this.syncCompleter,
  });

  final CalendarSyncSummary summary;
  final CalendarIntegrationResult? syncResult;
  final Completer<CalendarIntegrationResult>? syncCompleter;
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

    final completer = syncCompleter;
    if (completer != null) {
      return completer.future;
    }

    return syncResult ??
        CalendarIntegrationResult.synced(CalendarProvider.google);
  }
}
