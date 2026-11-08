import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Control tests for CalendarScreen._guideSuppressesInitialDaySheet. The guide
// suppresses the automatic initial day sheet ONLY when ALL hold: briefing is
// null, run active, step savedDetail, createdEventId set, savedLocalDate set,
// and savedLocalDate is the same day as the sheet date. Every case below
// breaks exactly one condition and asserts the sheet DOES open, by looking up
// the real sheet key 'calendar-day-events-draggable-sheet'. The suppressed
// baseline asserts the key is absent, so the positive findings cannot be
// vacuous (same harness, same data, only the guarded condition differs).
//
// Note: GuideSnapshot.uid is a non-null String, so the "uid == null" branch of
// the lib condition is unreachable from the type system and cannot be tested.
// Synthetic injected ports only, not native or cloud evidence.

const _sheetKey = ValueKey('calendar-day-events-draggable-sheet');

class _Guide implements GuideCoordinator {
  _Guide(GuideSnapshot s) : state = ValueNotifier(s);
  @override
  final ValueNotifier<GuideSnapshot> state;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends EventRepository {
  _Repo(this.rows);
  final List<EventModel> rows;
  @override
  Future<List<EventModel>> listEvents({String? userId}) async => rows;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _day = DateTime(2030, 1, 2);

EventModel _saved() => EventModel(
    id: 'saved',
    userId: 'u',
    title: 'Actual saved row',
    startAt: DateTime(2030, 1, 2, 10),
    endAt: DateTime(2030, 1, 2, 11));

GuideSnapshot _snap({
  GuideRun run = GuideRun.active,
  GuideStep step = GuideStep.savedDetail,
  String? createdEventId = 'saved',
  DateTime? savedLocalDate,
  bool useDefaultDate = true,
}) =>
    GuideSnapshot(
        uid: 'u',
        revision: 1,
        serverRevision: 1,
        version: 'v',
        sessionId: 's',
        run: run,
        step: step,
        createdEventId: createdEventId,
        savedLocalDate: useDefaultDate ? _day : savedLocalDate);

Future<void> _pump(WidgetTester tester, GuideSnapshot snap,
    {bool? briefingIsMorning}) async {
  await tester.pumpWidget(GuideScope(
      coordinator: _Guide(snap),
      child: MaterialApp(
        home: CalendarScreen(
            // Same arguments ShellScreen passes: initialDate only.
            initialDate: _day,
            eventRepository: _Repo([_saved()]),
            userId: 'u',
            briefingIsMorning: briefingIsMorning),
      )));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EventPrefetchService().invalidate();
  });

  testWidgets('baseline: same day + active + savedDetail suppresses the sheet',
      (tester) async {
    await _pump(tester, _snap());
    // Harness sanity: calendar loaded the saved day (row visible), but the
    // sheet is NOT open.
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(find.text('Actual saved row', skipOffstage: false), findsWidgets);
    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('(1) savedLocalDate on a different day: sheet opens',
      (tester) async {
    await _pump(
        tester, _snap(useDefaultDate: false, savedLocalDate: DateTime(2030, 1, 3)));
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  testWidgets('(2) step other than savedDetail: sheet opens', (tester) async {
    await _pump(tester, _snap(step: GuideStep.queryMic));
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  for (final run in [GuideRun.paused, GuideRun.blocked, GuideRun.terminal]) {
    testWidgets('(3) run=$run (not active): sheet opens', (tester) async {
      await _pump(tester, _snap(run: run));
      expect(find.byKey(_sheetKey), findsOneWidget);
    });
  }

  testWidgets('(4) createdEventId null: sheet opens', (tester) async {
    await _pump(tester, _snap(createdEventId: null));
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  testWidgets('(4b) savedLocalDate null: sheet opens', (tester) async {
    await _pump(tester, _snap(useDefaultDate: false, savedLocalDate: null));
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  testWidgets('no GuideScope at all: sheet opens', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CalendarScreen(
          initialDate: _day, eventRepository: _Repo([_saved()]), userId: 'u'),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  testWidgets(
      'suppressed state: user tapping the saved day cell still opens the sheet',
      (tester) async {
    await _pump(tester, _snap());
    expect(find.byKey(_sheetKey), findsNothing,
        reason: 'precondition: initial sheet is suppressed');
    final cell = find.byKey(const ValueKey('calendar-mini-day-2030-1-2'));
    expect(cell, findsOneWidget);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheetKey), findsOneWidget);
  });

  testWidgets(
      'briefing path (briefingIsMorning != null) opens the sheet even in the '
      'suppressed guide state', (tester) async {
    await tester.pumpWidget(GuideScope(
        coordinator: _Guide(_snap()),
        child: MaterialApp(
          home: CalendarScreen(
              initialDate: _day,
              eventRepository: _Repo([_saved()]),
              userId: 'u',
              briefingIsMorning: true),
        )));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_sheetKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
