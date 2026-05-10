import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';

void main() {
  testWidgets('음성 입력 화면은 짧은 사용 예시를 보여준다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VoiceInputScreen(autoStartOverride: false),
      ),
    );

    expect(find.text('이렇게 말해보세요'), findsOneWidget);
    expect(find.textContaining('내일 오전 10시 정장집 방문'), findsOneWidget);
    expect(find.textContaining('5월 10일 하루종일 휴가'), findsOneWidget);
    expect(find.textContaining('매주 화요일 팀 미팅'), findsOneWidget);
    expect(find.textContaining('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('병원 진료는 건강'), findsOneWidget);
  });

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
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']} / ${extra['start_at']}',
              textDirection: TextDirection.ltr,
            );
          },
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

    await tester.tap(find.text('직접 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('5분 뒤 요미 허리 약 주기'), findsOneWidget);
    expect(find.textContaining('T'), findsOneWidget);
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

    await tester.tap(find.text('직접 입력'));
    await tester.pumpAndSettle();

    expect(find.text('음성 관리: edit'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('오늘 일정 알려줘는 음성 조회 화면으로 이동한다', (tester) async {
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
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('직접 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 관리: query'), findsOneWidget);
    expect(find.textContaining('오늘 일정 알려줘'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });
}
