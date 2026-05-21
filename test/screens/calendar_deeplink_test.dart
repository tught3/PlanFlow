import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';

void main() {
  testWidgets('CalendarScreen resets to today when deep-link date is cleared',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(initialDate: DateTime(2026, 5, 7)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      const MaterialApp(
        home: CalendarScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final today = DateTime.now();
    expect(find.text('${today.year}년 ${today.month}월'), findsWidgets);
  });
}
