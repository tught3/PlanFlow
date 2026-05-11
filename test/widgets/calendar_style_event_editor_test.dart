import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';
import 'package:planflow/widgets/recurrence_selector.dart';

void main() {
  testWidgets('date wheel is hidden until a start or end field is tapped',
      (tester) async {
    await tester.pumpWidget(_TestHost());

    expect(find.text('시작 시간 조정'), findsNothing);

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('시작 시간 조정'), findsOneWidget);
    expect(find.text('오늘'), findsOneWidget);
  });

  testWidgets('today action updates the active start value', (tester) async {
    DateTime? changedStart;

    await tester.pumpWidget(
      _TestHost(
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    expect(changedStart, isNotNull);
    expect(changedStart!.year, now.year);
    expect(changedStart!.month, now.month);
    expect(changedStart!.day, now.day);
  });

  testWidgets('all-day mode hides time wheels', (tester) async {
    await tester.pumpWidget(_TestHost(isAllDay: true));

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('오전'), findsNothing);
    expect(find.text('오후'), findsNothing);
  });
}

class _TestHost extends StatelessWidget {
  _TestHost({
    this.isAllDay = false,
    this.onStartChanged,
  });

  final bool isAllDay;
  final ValueChanged<DateTime>? onStartChanged;
  final titleController = TextEditingController(text: '팀장 동행방문');
  final locationController = TextEditingController(text: '서울');
  final memoController = TextEditingController(text: '메모');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CalendarStyleEventEditor(
            titleController: titleController,
            locationController: locationController,
            memoController: memoController,
            startAt: DateTime(2026, 5, 13, 9),
            endAt: DateTime(2026, 5, 13, 10),
            isAllDay: isAllDay,
            category: '업무',
            recurrence: const RecurrenceSelection(),
            reminderOffset: const Duration(hours: 1),
            isCritical: false,
            onStartChanged: onStartChanged ?? (_) {},
            onEndChanged: (_) {},
            onAllDayChanged: (_) {},
            onCategoryChanged: (_) {},
            onRecurrenceChanged: (_) {},
            onReminderChanged: (_) {},
            onCriticalChanged: (_) {},
            onLocationPick: () {},
          ),
        ),
      ),
    );
  }
}
