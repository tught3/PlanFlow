import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/feedback_report_model.dart';
import 'package:planflow/data/repositories/feedback_repository.dart';
import 'package:planflow/screens/settings/feedback_report_sheet.dart';

void main() {
  testWidgets('FeedbackReportSheet validates and submits a report',
      (tester) async {
    final gateway = _FakeFeedbackGateway();
    final repository = _testRepository(gateway);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => FeedbackReportSheet(
                      repository: repository,
                      routeOrScreen: 'settings',
                    ),
                  );
                },
                child: const Text('열기'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('문제 신고 / 의견 보내기'), findsOneWidget);
    expect(
      find.text('음성 파일, 캘린더 전체 내용, 위치 이력은 자동 첨부하지 않아요.'),
      findsOneWidget,
    );
    expect(find.text('버그'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const ValueKey('feedback-submit-button')));
    await tester.pumpAndSettle();
    expect(find.text('내용을 5자 이상 입력해 주세요.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('feedback-message-field')),
      '음성 수정 대상이 보이지 않아요',
    );
    await tester.enterText(
      find.byKey(const ValueKey('feedback-expected-field')),
      '후보 일정이 떠야 해요',
    );
    await tester.tap(find.text('음성 인식 오류'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const ValueKey('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(gateway.payloads, hasLength(1));
    expect(gateway.payloads.single['type'], 'voice');
    expect(gateway.payloads.single['message'], '음성 수정 대상이 보이지 않아요');
    expect(find.text('문제 신고 / 의견 보내기'), findsNothing);
  });

  testWidgets('FeedbackReportSheet opens mailto fallback', (tester) async {
    Uri? openedUri;
    final repository = _testRepository(_FakeFeedbackGateway());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackReportSheet(
            repository: repository,
            launchUrlFn: (uri) async {
              openedUri = uri;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('feedback-email-button')),
    );
    await tester.tap(find.byKey(const ValueKey('feedback-email-button')));
    await tester.pumpAndSettle();

    expect(openedUri?.scheme, 'mailto');
    expect(openedUri?.path, officialSupportEmail);
  });

  testWidgets('FeedbackReportSheet shows visible error and keeps typed text',
      (tester) async {
    final gateway = _FakeFeedbackGateway(
      error: const FeedbackSubmissionException('문제 신고 저장소를 확인해 주세요.'),
    );
    final repository = _testRepository(gateway);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackReportSheet(repository: repository),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('feedback-message-field')),
      '문제 신고가 보내지지 않아요',
    );
    await tester.tap(find.byKey(const ValueKey('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('feedback-status-banner')), findsOneWidget);
    expect(find.text('문제 신고 저장소를 확인해 주세요.'), findsWidgets);
    expect(find.text('문제 신고가 보내지지 않아요'), findsOneWidget);
  });

  testWidgets('FeedbackAdminReportsSheet marks new reports as triaged when opened',
      (tester) async {
    final gateway = _FakeFeedbackGateway(
      adminRows: <Map<String, Object?>>[
        <String, Object?>{
          'id': 'report-1',
          'user_id': 'user-1',
          'type': 'voice',
          'message': '새 기능 안내가 보이지 않아요',
          'expected_behavior': '안내가 보이도록 해주세요',
          'app_version': '1.0.0+1',
          'platform': 'android',
          'device_summary': 'Android',
          'route_or_screen': 'settings',
          'diagnostics': <String, Object?>{'screen': 'settings'},
          'status': 'new',
          'created_at': '2026-05-15T01:00:00Z',
          'updated_at': '2026-05-15T01:00:00Z',
        },
      ],
    );
    final repository = _testRepository(gateway);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackAdminReportsSheet(repository: repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.statusUpdates, <String, String>{'report-1': 'triaged'});
    expect(find.text('새 기능 안내가 보이지 않아요'), findsOneWidget);
  });

  testWidgets('FeedbackReportSheet passes attachDiagLog=true by default',
      (tester) async {
    final gateway = _FakeFeedbackGateway();
    bool? capturedAttachDiagLog;
    final repository = FeedbackRepository(
      gateway: gateway,
      currentUserId: () => 'user-1',
      diagnosticsProvider: (_, {bool attachDiagLog = true}) async {
        capturedAttachDiagLog = attachDiagLog;
        return FeedbackDiagnostics(
          appVersion: '1.0.0+1',
          platform: 'android',
          deviceSummary: 'Android',
          diagnostics: <String, Object?>{
            if (attachDiagLog) 'diag_log': '로그 샘플',
          },
        );
      },
      analyticsLogger: (_) async {},
      crashlyticsLogger: (_, __) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FeedbackReportSheet(repository: repository)),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('feedback-message-field')),
      '기본 ON 상태에서 진단 로그가 첨부되는지 확인해요',
    );
    await tester.tap(find.byKey(const ValueKey('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(capturedAttachDiagLog, isTrue);
  });

  testWidgets('FeedbackReportSheet toggle OFF excludes diag log',
      (tester) async {
    final gateway = _FakeFeedbackGateway();
    bool? capturedAttachDiagLog;
    final repository = FeedbackRepository(
      gateway: gateway,
      currentUserId: () => 'user-1',
      diagnosticsProvider: (_, {bool attachDiagLog = true}) async {
        capturedAttachDiagLog = attachDiagLog;
        return FeedbackDiagnostics(
          appVersion: '1.0.0+1',
          platform: 'android',
          deviceSummary: 'Android',
          diagnostics: <String, Object?>{},
        );
      },
      analyticsLogger: (_) async {},
      crashlyticsLogger: (_, __) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FeedbackReportSheet(repository: repository)),
      ),
    );

    // 토글 OFF
    await tester.tap(find.byKey(const ValueKey('feedback-diag-log-toggle')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('feedback-message-field')),
      '토글 OFF 시 진단 로그가 제외되는지 확인해요',
    );
    await tester.tap(find.byKey(const ValueKey('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(capturedAttachDiagLog, isFalse);
  });

  testWidgets('FeedbackReportSection shows new admin report badge',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackReportSection(
            onPressed: () {},
            onOpenAdminInbox: () {},
            newAdminReportCount: 3,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('settings-feedback-admin-new-badge')),
      findsOneWidget,
    );
    expect(find.text('3'), findsOneWidget);
  });
}

FeedbackRepository _testRepository(_FakeFeedbackGateway gateway) {
  return FeedbackRepository(
    gateway: gateway,
    currentUserId: () => 'user-1',
    diagnosticsProvider: (_, {bool attachDiagLog = true}) async =>
        const FeedbackDiagnostics(
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
    this.error,
    this.adminRows = const <Map<String, Object?>>[],
  });

  final Object? error;
  final List<Map<String, Object?>> adminRows;
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
  final Map<String, String> statusUpdates = <String, String>{};

  @override
  Future<void> insert(Map<String, Object?> payload) async {
    final nextError = error;
    if (nextError != null) {
      throw nextError;
    }
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
  }) async {
    statusUpdates[reportId] = status.value;
  }
}
