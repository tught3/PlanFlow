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
    expect(payload['product'], 'planflow');
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

  test('countNewAdminReports counts only new admin rows', () async {
    final gateway = _FakeFeedbackGateway(
      adminRows: <Map<String, Object?>>[
        _adminRow(id: 'report-1', status: 'new'),
        _adminRow(id: 'report-2', status: 'triaged'),
        _adminRow(id: 'report-3', status: 'new'),
      ],
    );
    final repository = _testRepository(gateway);

    final count = await repository.countNewAdminReports();

    expect(count, 2);
  });
}

Map<String, Object?> _adminRow({
  required String id,
  required String status,
}) {
  return <String, Object?>{
    'id': id,
    'user_id': 'user-1',
    'product': 'planflow',
    'type': 'bug',
    'message': '문제가 있어요',
    'expected_behavior': null,
    'app_version': '1.0.0+1',
    'platform': 'android',
    'device_summary': 'Android',
    'route_or_screen': 'settings',
    'diagnostics': <String, Object?>{},
    'status': status,
    'created_at': '2026-05-17T01:00:00Z',
    'updated_at': '2026-05-17T01:00:00Z',
  };
}

FeedbackRepository _testRepository(_FakeFeedbackGateway gateway) {
  return FeedbackRepository(
    gateway: gateway,
    currentUserId: () => 'user-1',
    diagnosticsProvider: (_) async => const FeedbackDiagnostics(
      appVersion: '1.0.0+1',
      platform: 'android',
      deviceSummary: 'Android',
      diagnostics: <String, Object?>{},
    ),
    analyticsLogger: (_) async {},
    crashlyticsLogger: (_, __) async {},
  );
}

class _FakeFeedbackGateway implements FeedbackReportAdminGateway {
  _FakeFeedbackGateway({
    this.adminRows = const <Map<String, Object?>>[],
  });

  final List<Map<String, Object?>> adminRows;
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];

  @override
  Future<void> insert(Map<String, Object?> payload) async {
    payloads.add(payload);
  }

  @override
  Future<List<Map<String, Object?>>> fetchAdminReports({
    FeedbackReportStatus? status,
    int limit = 100,
  }) async {
    final rows = status == null
        ? adminRows
        : adminRows
            .where((row) => row['status'] == status.value)
            .toList(growable: false);
    return rows.take(limit).toList(growable: false);
  }

  @override
  Future<void> updateReportStatus({
    required String reportId,
    required FeedbackReportStatus status,
  }) async {}
}
