import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';

void main() {
  testWidgets('CalendarScreen does not show a loading panel while loading',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CalendarScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('캘린더 확인 중'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Supabase'), findsOneWidget);
  });
}
