import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/screens/voice/voice_launcher_screen.dart';

void main() {
  testWidgets('VoiceLauncherScreen routes schedule voice with auto start',
      (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voiceLauncher,
      routes: [
        GoRoute(
          path: AppRoutes.voiceLauncher,
          builder: (context, state) => const VoiceLauncherScreen(),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => Text(
            'voice-auto-${state.uri.queryParameters['autoStart']}',
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => Text(
            'conversation-auto-${state.uri.queryParameters['autoStart']}',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('일정 추가'));
    await tester.pumpAndSettle();

    expect(find.text('voice-auto-1'), findsOneWidget);
  });

  testWidgets('VoiceLauncherScreen routes conversation voice with auto start',
      (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voiceLauncher,
      routes: [
        GoRoute(
          path: AppRoutes.voiceLauncher,
          builder: (context, state) => const VoiceLauncherScreen(),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => Text(
            'voice-auto-${state.uri.queryParameters['autoStart']}',
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => Text(
            'conversation-auto-${state.uri.queryParameters['autoStart']}',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('AI 자동대화'));
    await tester.pumpAndSettle();

    expect(find.text('conversation-auto-1'), findsOneWidget);
  });
}
