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

  testWidgets('critical checkbox expands strong alarm and keeps checkbox visible',
      (tester) async {
    await tester.pumpWidget(
      _TestHost(
        startAt: DateTime(2026, 5, 13, 9),
        endAt: DateTime(2026, 5, 13, 10),
        initiallyExpandCriticalAlarm: true,
      ),
    );

    // 초기 상태: 중요한 일정 섹션이 펼쳐져 있고 체크박스 보임
    expect(find.text('중요한 일정으로 표시'), findsOneWidget);

    // 초기 상태: 강한 알람 스위치 없음 (isCritical이 false이므로)
    expect(find.text('강한 알람'), findsNothing);

    // 스크롤뷰에서 체크박스가 화면 밖이면 탭이 안 먹으므로 먼저 화면에
    // 들여온 뒤 탭한다(실제 앱에서도 사용자가 스크롤해 보고 누르는 상황).
    await tester.ensureVisible(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();

    // 중요한 일정 체크박스 탭
    await tester.tap(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();

    // 크래시 없음 & 강한 알람 옵션이 나타났는지 확인
    expect(find.text('강한 알람'), findsOneWidget);

    // 방금 토글한 체크박스 항목이 여전히 위젯 트리에 보이는지 확인
    expect(find.text('중요한 일정으로 표시'), findsOneWidget);
  });
}

class _TestHost extends StatefulWidget {
  _TestHost({
    this.onStartChanged,
    this.locationText = '',
    this.locationLat,
    this.locationLng,
    this.recurrence = const RecurrenceSelection(),
    this.initiallyExpandClassification = false,
    this.initiallyExpandDetails = false,
    this.initiallyExpandCriticalAlarm = false,
    this.isCritical = false,
    this.useStrongAlarm = false,
    required this.startAt,
    required this.endAt,
  });

  final ValueChanged<DateTime>? onStartChanged;
  final String locationText;
  final double? locationLat;
  final double? locationLng;
  final RecurrenceSelection recurrence;
  final bool initiallyExpandClassification;
  final bool initiallyExpandDetails;
  final bool initiallyExpandCriticalAlarm;
  final bool isCritical;
  final bool useStrongAlarm;
  final DateTime startAt;
  final DateTime endAt;

  @override
  State<_TestHost> createState() => _TestHostState();
}

class _TestHostState extends State<_TestHost> {
  late bool _isCritical;
  late bool _useStrongAlarm;
  late final TextEditingController titleController;
  late final TextEditingController locationController;
  final memoController = TextEditingController(text: '메모');

  @override
  void initState() {
    super.initState();
    _isCritical = widget.isCritical;
    _useStrongAlarm = widget.useStrongAlarm;
    titleController = TextEditingController(text: '팀장 동행방문');
    locationController =
        TextEditingController(text: widget.locationText);
  }

  @override
  void dispose() {
    titleController.dispose();
    locationController.dispose();
    memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CalendarStyleEventEditor(
            key: ValueKey(
                '${widget.startAt.toIso8601String()}-${widget.endAt.toIso8601String()}'),
            titleController: titleController,
            locationController: locationController,
            memoController: memoController,
            startAt: widget.startAt,
            endAt: widget.endAt,
            category: '업무',
            recurrence: widget.recurrence,
            reminderOffset: const Duration(hours: 1),
            isCritical: _isCritical,
            useStrongAlarm: _useStrongAlarm,
            locationLat: widget.locationLat,
            locationLng: widget.locationLng,
            initiallyExpandClassification:
                widget.initiallyExpandClassification,
            initiallyExpandDetails: widget.initiallyExpandDetails,
            initiallyExpandCriticalAlarm:
                widget.initiallyExpandCriticalAlarm,
            onStartChanged: widget.onStartChanged ?? (_) {},
            onEndChanged: (_) {},
            onCategoryChanged: (_) {},
            onRecurrenceChanged: (_) {},
            onReminderChanged: (_) {},
            onCriticalChanged: (v) => setState(() => _isCritical = v),
            onStrongAlarmChanged: (v) =>
                setState(() => _useStrongAlarm = v),
            onLocationPick: () {},
            isSearchingLocation: false,
          ),
        ),
      ),
    );
  }
}
