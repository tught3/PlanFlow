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

  testWidgets('예시 패널은 콘텐츠 폭을 채우고 지원 동작별 예시를 보인다',
      (tester) async {
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
    final result = Completer<bool>();
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
    expect(await result.future, isFalse);
  });
}
