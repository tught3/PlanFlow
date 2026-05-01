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

    expect(find.text('Google Calendar'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Naver Calendar'), findsOneWidget);
    expect(find.text('Unsupported'), findsOneWidget);
  });
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({
    required this.summary,
  });

  final CalendarSyncSummary summary;

  @override
  Future<CalendarSyncSummary> fetchStatus() async => summary;
}
