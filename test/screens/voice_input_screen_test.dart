import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';

void main() {
  testWidgets('일반 음성 문장은 일정 확인 화면으로 바로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => Text(
            '일정 확인: ${(state.extra as Map<String, dynamic>)['raw_text']}',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '5분 뒤 요미 허리 약 주기');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.tap(find.text('직접 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('5분 뒤 요미 허리 약 주기'), findsOneWidget);
    expect(find.text('음성 관리 화면'), findsNothing);
  });

  testWidgets('수정 의도가 명확하면 음성 관리 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '한강 피크닉 수정해줘');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.tap(find.text('직접 입력'));
    await tester.pumpAndSettle();

    expect(find.text('음성 관리: edit'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });
}
