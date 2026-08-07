import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/voice_conversation_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    VoiceConversationLauncher.debugShowButtonOverride = null;
  });

  testWidgets(
    'CalendarScreen renders exactly one voice FAB and one AI 대화 FAB',
    (tester) async {
      VoiceConversationLauncher.debugShowButtonOverride = true;

      await tester.pumpWidget(const MaterialApp(home: CalendarScreen()));
      await tester.pumpAndSettle();

      expect(find.text('음성으로 일정 관리'), findsOneWidget);
      expect(find.text('AI일정대화'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CalendarScreen with kill switch off renders only the voice FAB',
    (tester) async {
      VoiceConversationLauncher.debugShowButtonOverride = false;

      await tester.pumpWidget(const MaterialApp(home: CalendarScreen()));
      await tester.pumpAndSettle();

      expect(find.text('음성으로 일정 관리'), findsOneWidget);
      expect(find.text('AI일정대화'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
