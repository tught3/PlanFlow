import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';
import 'package:planflow/widgets/location_resolution_status.dart';
import 'package:planflow/widgets/recurrence_selector.dart';

void main() {
  testWidgets('date wheel is hidden until a start or end field is tapped',
      (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
      ),
    );

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
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
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
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
        isAllDay: true,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('오전'), findsNothing);
    expect(find.text('오후'), findsNothing);
  });

  testWidgets('time wheels handle minute wrap at 55 to 00', (tester) async {
    DateTime? changedStart;

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 10, 55),
        endAt: DateTime(2026, 5, 13, 11, 55),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    final minuteWheel =
        tester.widget(find.byKey(const Key('start-minute-wheel'))) as dynamic;
    minuteWheel.onChanged(0);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 11);
    expect(changedStart!.minute, 0);
  });

  testWidgets('time wheels handle minute wrap at 00 to 55', (tester) async {
    DateTime? changedStart;

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 11),
        endAt: DateTime(2026, 5, 13, 12),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    final minuteWheel =
        tester.widget(find.byKey(const Key('start-minute-wheel'))) as dynamic;
    minuteWheel.onChanged(55);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 10);
    expect(changedStart!.minute, 55);
  });

  testWidgets('time wheels move hour smoothly across noon and wrap',
      (tester) async {
    DateTime? changedStart;

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 11),
        endAt: DateTime(2026, 5, 13, 12),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    final hourWheel =
        tester.widget(find.byKey(const Key('start-hour-wheel'))) as dynamic;
    hourWheel.onChanged(12);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 12);

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 12),
        endAt: DateTime(2026, 5, 13, 13),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    final noonHourWheel =
        tester.widget(find.byKey(const Key('start-hour-wheel'))) as dynamic;
    noonHourWheel.onChanged(1);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 13);
  });

  testWidgets(
      'period wheel only toggles AM and PM with correct 12-hour mapping',
      (tester) async {
    DateTime? changedStart;

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13),
        endAt: DateTime(2026, 5, 13, 1),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('오전'), findsWidgets);
    expect(find.text('오후'), findsWidgets);

    final midnightPeriodWheel =
        tester.widget(find.byKey(const Key('start-period-wheel'))) as dynamic;
    midnightPeriodWheel.onChanged(1);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 12);

    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 12),
        endAt: DateTime(2026, 5, 13, 13),
        onStartChanged: (value) => changedStart = value,
      ),
    );

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    final noonPeriodWheel =
        tester.widget(find.byKey(const Key('start-period-wheel'))) as dynamic;
    noonPeriodWheel.onChanged(0);
    await tester.pump();

    expect(changedStart, isNotNull);
    expect(changedStart!.hour, 0);
  });

  testWidgets('timezone row is removed from editor', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
      ),
    );

    expect(find.text('서울 (GMT+9:00)'), findsNothing);
  });

  testWidgets('location status shows unresolved map position', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
        locationText: '원주세브란스기독병원',
      ),
    );

    expect(find.text('지도 위치 미지정'), findsOneWidget);
    expect(find.textContaining('스마트준비알람이 부정확'), findsOneWidget);
    expect(find.text('지도 지정'), findsOneWidget);
  });

  testWidgets('location clear button clears text and notifies parent',
      (tester) async {
    String? changedLocation;
    final host = _TestHost(
      startAt: DateTime(2026, 5, 13, 9),
      endAt: DateTime(2026, 5, 13, 10),
      locationText: '원주세브란스기독병원',
      onLocationTextChanged: (value) => changedLocation = value,
    );

    await tester.pumpWidget(host);

    expect(find.byTooltip('장소 지우기'), findsOneWidget);

    await tester.tap(find.byTooltip('장소 지우기'));
    await tester.pump();

    expect(host.locationController.text, isEmpty);
    expect(changedLocation, '');
    expect(find.byTooltip('장소 지우기'), findsNothing);
    expect(find.byTooltip('지도에서 위치 선택'), findsOneWidget);
  });

  testWidgets('location status shows resolved map position', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
        locationText: '원주세브란스기독병원',
        locationLat: 37.3495,
        locationLng: 127.9458,
      ),
    );

    expect(find.text('지도 위치 연결됨'), findsOneWidget);
    expect(find.textContaining('이 좌표로 이동시간'), findsOneWidget);
    expect(find.text('지도 지정'), findsNothing);
  });

  testWidgets('location status shows searching state while resolving',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationResolutionStatus(
            hasLocationText: true,
            isResolved: false,
            isSearching: true,
            onResolve: () {},
          ),
        ),
      ),
    );

    expect(find.text('위치 찾는 중'), findsOneWidget);
    expect(find.text('지도 위치를 검색하고 있어요.'), findsOneWidget);
    expect(find.text('지도 지정'), findsNothing);
  });

  testWidgets('less-used editor sections start collapsed and expand on tap',
      (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
      ),
    );

    expect(find.text('장소'), findsWidgets);
    expect(find.textContaining('반복 안 함'), findsOneWidget);
    expect(find.text('미리알림'), findsNothing);
    expect(find.widgetWithText(TextFormField, '설명'), findsNothing);

    await tester.tap(find.text('반복 설정'));
    await tester.pumpAndSettle();
    expect(find.text('업무'), findsNothing);
    expect(find.text('반복'), findsOneWidget);

    await tester.ensureVisible(find.text('설명 · 준비물'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('설명 · 준비물'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '설명'), findsOneWidget);

    await tester.ensureVisible(find.text('알림 옵션'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('알림 옵션'));
    await tester.pumpAndSettle();
    expect(find.text('미리알림'), findsOneWidget);
    expect(find.text('중요한 일정으로 표시'), findsNothing);

    await tester.ensureVisible(find.text('중요한 일정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('중요한 일정'));
    await tester.pumpAndSettle();
    expect(find.text('중요한 일정으로 표시'), findsOneWidget);
  });

  testWidgets('configured optional sections can start expanded',
      (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
        recurrence: const RecurrenceSelection(
          frequency: 'weekly',
          preservedParts: <String>['BYDAY=MO'],
        ),
        initiallyExpandClassification: true,
        initiallyExpandDetails: true,
      ),
    );

    expect(find.text('반복'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '설명'), findsOneWidget);
  });
}

class _TestHost extends StatelessWidget {
  _TestHost({
    this.isAllDay = false,
    this.onStartChanged,
    this.locationText = '',
    this.locationLat,
    this.locationLng,
    this.onLocationTextChanged,
    this.recurrence = const RecurrenceSelection(),
    this.initiallyExpandClassification = false,
    this.initiallyExpandDetails = false,
    required this.startAt,
    required this.endAt,
  });

  final bool isAllDay;
  final ValueChanged<DateTime>? onStartChanged;
  final String locationText;
  final double? locationLat;
  final double? locationLng;
  final ValueChanged<String>? onLocationTextChanged;
  final RecurrenceSelection recurrence;
  final bool initiallyExpandClassification;
  final bool initiallyExpandDetails;
  final DateTime startAt;
  final DateTime endAt;
  final titleController = TextEditingController(text: '팀장 동행방문');
  late final locationController = TextEditingController(text: locationText);
  final memoController = TextEditingController(text: '메모');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CalendarStyleEventEditor(
            key: ValueKey(
                '${startAt.toIso8601String()}-${endAt.toIso8601String()}'),
            titleController: titleController,
            locationController: locationController,
            memoController: memoController,
            startAt: startAt,
            endAt: endAt,
            isAllDay: isAllDay,
            category: '업무',
            recurrence: recurrence,
            reminderOffset: const Duration(hours: 1),
            isCritical: false,
            useStrongAlarm: false,
            locationLat: locationLat,
            locationLng: locationLng,
            initiallyExpandClassification: initiallyExpandClassification,
            initiallyExpandDetails: initiallyExpandDetails,
            onStartChanged: onStartChanged ?? (_) {},
            onEndChanged: (_) {},
            onAllDayChanged: (_) {},
            onCategoryChanged: (_) {},
            onRecurrenceChanged: (_) {},
            onReminderChanged: (_) {},
            onCriticalChanged: (_) {},
            onStrongAlarmChanged: (_) {},
            onLocationTextChanged: onLocationTextChanged,
            onLocationPick: () {},
            isSearchingLocation: false,
          ),
        ),
      ),
    );
  }
}
