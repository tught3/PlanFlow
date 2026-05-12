import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/feedback_report_model.dart';
import 'package:planflow/data/repositories/feedback_repository.dart';

void main() {
  test('submitReport builds Supabase payload with diagnostics', () async {
    final gateway = _FakeFeedbackGateway();
    final repository = FeedbackRepository(
      gateway: gateway,
      currentUserId: () => 'user-1',
      diagnosticsProvider: (_) async => const FeedbackDiagnostics(
        appVersion: '1.0.0+1',
        platform: 'android',
        deviceSummary: 'Android 15',
        diagnostics: <String, Object?>{
          'route_or_screen': 'settings',
          'calendar_sync_last_failed': <String>['google_auto_sync'],
        },
      ),
      analyticsLogger: (_) async {},
      crashlyticsLogger: (_, __) async {},
    );

    await repository.submitReport(
      type: FeedbackReportType.calendarSync,
      message: '네이버 일정 시간이 맞지 않아요',
      expectedBehavior: '한국 시간으로 보여야 해요',
      routeOrScreen: 'settings',
    );

    expect(gateway.payloads, hasLength(1));
    final payload = gateway.payloads.single;
    expect(payload['user_id'], 'user-1');
    expect(payload['type'], 'calendar_sync');
    expect(payload['message'], '네이버 일정 시간이 맞지 않아요');
    expect(payload['expected_behavior'], '한국 시간으로 보여야 해요');
    expect(payload['app_version'], '1.0.0+1');
    expect(payload['platform'], 'android');
    expect(payload['device_summary'], 'Android 15');
    expect(payload['route_or_screen'], 'settings');
    expect(payload['status'], 'new');
    expect(payload['diagnostics'], isA<Map<String, Object?>>());
  });

  test('submitReport blocks anonymous users', () async {
    final repository = FeedbackRepository(
      gateway: _FakeFeedbackGateway(),
      currentUserId: () => null,
      diagnosticsProvider: (_) async => const FeedbackDiagnostics(
        appVersion: '1.0.0+1',
        platform: 'android',
        deviceSummary: 'Android',
        diagnostics: <String, Object?>{},
      ),
      analyticsLogger: (_) async {},
      crashlyticsLogger: (_, __) async {},
    );

    expect(
      () => repository.submitReport(
        type: FeedbackReportType.bug,
        message: '문제가 있어요',
        routeOrScreen: 'settings',
      ),
      throwsA(isA<FeedbackSubmissionException>()),
    );
  });

  test('submitReport validates message length', () async {
    final repository = FeedbackRepository(
      gateway: _FakeFeedbackGateway(),
      currentUserId: () => 'user-1',
      analyticsLogger: (_) async {},
      crashlyticsLogger: (_, __) async {},
    );

    expect(
      () => repository.submitReport(
        type: FeedbackReportType.bug,
        message: '짧음',
        routeOrScreen: 'settings',
      ),
      throwsA(isA<FeedbackSubmissionException>()),
    );
  });
}

class _FakeFeedbackGateway implements FeedbackReportGateway {
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];

  @override
  Future<void> insert(Map<String, Object?> payload) async {
    payloads.add(payload);
  }
}
