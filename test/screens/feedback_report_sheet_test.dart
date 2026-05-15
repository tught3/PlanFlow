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

class _FakeFeedbackGateway implements FeedbackReportGateway {
  _FakeFeedbackGateway({this.error});

  final Object? error;
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];

  @override
  Future<void> insert(Map<String, Object?> payload) async {
    final nextError = error;
    if (nextError != null) {
      throw nextError;
    }
    payloads.add(payload);
  }
}
