import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_conversation_launcher.dart';
import 'package:planflow/widgets/planflow_global_fabs.dart';

void main() {
  tearDown(() {
    VoiceConversationLauncher.debugShowButtonOverride = null;
  });

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onVoice,
    VoidCallback? onAiConversation,
    bool showVoicePulse = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: PlanFlowGlobalFabs(
              onVoice: onVoice ?? () {},
              onAiConversation: onAiConversation ?? () {},
              showVoicePulse: showVoicePulse,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('AI일정대화 FAB이 음성 FAB보다 위에 위치한다', (tester) async {
    VoiceConversationLauncher.debugShowButtonOverride = true;

    await pump(tester);
    await tester.pumpAndSettle();

    final aiTop = tester.getTopLeft(find.text('AI일정대화')).dy;
    final voiceTop = tester.getTopLeft(find.text('음성으로 일정 관리')).dy;

    expect(
      aiTop,
      lessThan(voiceTop),
      reason: 'AI일정대화가 위, 음성으로 일정 관리가 아래 순서여야 한다',
    );
  });

  testWidgets('360x800 뷰포트에서 오버플로우 없이 렌더링된다', (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    VoiceConversationLauncher.debugShowButtonOverride = true;

    await pump(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('kill switch(shouldShowButton=false)면 AI FAB이 렌더되지 않는다', (
    tester,
  ) async {
    VoiceConversationLauncher.debugShowButtonOverride = false;

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('AI일정대화'), findsNothing);
    expect(find.text('음성으로 일정 관리'), findsOneWidget);
  });

  testWidgets('각 FAB을 탭하면 대응 콜백이 정확히 1회 호출된다', (tester) async {
    VoiceConversationLauncher.debugShowButtonOverride = true;
    var voiceTapCount = 0;
    var aiTapCount = 0;

    await pump(
      tester,
      onVoice: () => voiceTapCount += 1,
      onAiConversation: () => aiTapCount += 1,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI일정대화'));
    await tester.tap(find.text('음성으로 일정 관리'));
    await tester.pumpAndSettle();

    expect(aiTapCount, 1);
    expect(voiceTapCount, 1);
  });
}
