import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/reminder_offset_selector.dart';

void main() {
  testWidgets('알림 선택 바텀시트는 작은 화면에서도 overflow 없이 스크롤된다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 360));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReminderOffsetSelector(
            value: const Duration(minutes: 60),
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('1시간 전'));
    await tester.pumpAndSettle();

    expect(find.text('일정 알림 선택'), findsOneWidget);
    expect(find.text('알림 없음'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
