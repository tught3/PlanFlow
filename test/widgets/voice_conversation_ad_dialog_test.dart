import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/widgets/voice_conversation_ad_dialog.dart';

void main() {
  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () {
              unawaited(showVoiceConversationAdDialog(context));
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('예시 패널은 콘텐츠 폭을 채우고 지원 동작별 예시를 보인다', (tester) async {
    await openDialog(tester);

    final panel = tester.getRect(find.byKey(voiceConversationExamplesPanelKey));
    final intro = tester.getRect(find.byKey(voiceConversationIntroTextKey));
    expect(panel.width, equals(intro.width));

    for (final example in <String>[
      '내일 오후 2시에 팀 회의 추가해줘',
      '다음 주 금요일 일정 보여줘',
      '내일 일정 오후 5시 반으로 미뤄줘',
      '첫 번째 일정 장소를 본관 3층으로 바꿔줘',
      '첫 번째 일정 삭제해줘',
      '매주 월요일 오전 9시에 운동 일정 추가해줘',
    ]) {
      expect(find.text('• $example'), findsOneWidget);
    }
  });

  testWidgets('취소와 광고 시작 버튼은 각각 기존 결과를 반환한다', (tester) async {
    final result = Completer<VoiceConversationAdDialogResult>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () {
              showVoiceConversationAdDialog(context).then(result.complete);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    expect((await result.future).isAllowed, isFalse);
  });

  testWidgets('실패 원인과 단계 목록을 표시하고 재시도는 새 시도를 실행한다', (tester) async {
    var attempts = 0;
    final attemptNumbers = <int>[];
    final result = Completer<VoiceConversationAdDialogResult>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () {
              showVoiceConversationAdDialog(
                context,
                initialCompletedStages: const {
                  VoiceConversationAdDialogStage.entitlement,
                },
                onStartAttempt: (reportProgress, attemptNumber) async {
                  attempts += 1;
                  attemptNumbers.add(attemptNumber);
                  reportProgress(VoiceConversationAdDialogStage.remoteConfig);
                  reportProgress(VoiceConversationAdDialogStage.consent);
                  if (attempts == 1) {
                    return const VoiceConversationAdDialogAttemptResult.failure(
                      diagnosticCode: 'E-ADFAIL',
                      diagnosticDetail: 'reason=load_failed',
                    );
                  }
                  reportProgress(VoiceConversationAdDialogStage.loading);
                  reportProgress(
                    VoiceConversationAdDialogStage.rewardVerified,
                  );
                  return const VoiceConversationAdDialogAttemptResult
                      .rewarded();
                },
              ).then(result.complete);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(voiceConversationAdStageListKey), findsOneWidget);
    expect(find.text('광고 시청 확인'), findsOneWidget);

    await tester.tap(find.text('광고 보고 시작하기'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.byKey(voiceConversationAdDiagnosticKey), findsOneWidget);
    expect(find.textContaining('E-ADFAIL'), findsOneWidget);
    expect(find.byKey(voiceConversationAdRetryButtonKey), findsOneWidget);

    await tester.tap(find.byKey(voiceConversationAdRetryButtonKey));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(attemptNumbers, <int>[1, 2]);
    expect((await result.future).isRewarded, isTrue);
  });

  testWidgets('진행 중에는 바깥 탭이나 뒤로 닫을 수 없고 완료 후 취소할 수 있다', (tester) async {
    final pendingAttempt = Completer<VoiceConversationAdDialogAttemptResult>();
    final result = Completer<VoiceConversationAdDialogResult>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () {
              showVoiceConversationAdDialog(
                context,
                onStartAttempt: (_, __) => pendingAttempt.future,
              ).then(result.complete);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('광고 보고 시작하기'));
    await tester.pump();

    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    expect(find.byKey(voiceConversationAdStageListKey), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(voiceConversationAdStageListKey), findsOneWidget);

    pendingAttempt
        .complete(const VoiceConversationAdDialogAttemptResult.failure(
      diagnosticCode: 'E-ADFAIL',
      diagnosticDetail: 'reason=load_failed',
    ));
    await tester.pumpAndSettle();
    expect(find.text('광고 처리 실패'), findsOneWidget);
    await tester.tap(find.text('취소'));
    expect((await result.future).isAllowed, isFalse);
  });
}
