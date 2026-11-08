import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic injected ports only, not native or cloud evidence.
class _Guide implements GuideCoordinator {
  @override
  final state = ValueNotifier(GuideSnapshot(
      uid: 'u',
      revision: 1,
      serverRevision: 1,
      version: 'v',
      sessionId: 's',
      run: GuideRun.active,
      step: GuideStep.savedDetail,
      createdEventId: 'saved',
      // banned-ok: Fixed event fixture for the guide assertion.
      savedLocalDate: DateTime(2030, 1, 2)));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends EventRepository {
  List<EventModel> rows = [];
  int reads = 0;
  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    reads++;
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EventModel saved() => EventModel(
    id: 'saved',
    userId: 'u',
    title: 'Actual saved row',
    // banned-ok: Fixed event fixture for the guide assertion.
    startAt: DateTime(2030, 1, 2, 10),
    // banned-ok: Fixed event fixture for the guide assertion.
    endAt: DateTime(2030, 1, 2, 11));
Finder anchor() =>
    find.byWidgetPredicate((w) => w is GuidedAnchor && w.id == 'calendar.saved',
        skipOffstage: false);
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EventPrefetchService().invalidate();
  });
  Widget app(_Guide guide, Widget child) =>
      GuideScope(coordinator: guide, child: MaterialApp(home: child));
  Widget calendar(_Repo repo) => CalendarScreen(
      eventRepository: repo, userId: 'u', suppressInitialDaySheet: true);
  testWidgets('saved-detail host targets the visible detail summary first',
      (tester) async {
    final guide = _Guide();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(fit: StackFit.expand, children: [
          ListView(children: [
            // 실제 화면의 '저장된 일정 확인' 카드처럼 화면에 그려지는 크기다.
            GuidedAnchor(
                id: 'saved.summary',
                registry: GuidedAnchorRegistry.shared,
                child: const SizedBox(
                    height: 64, width: 220, child: Text('Saved summary'))),
            const SizedBox(height: 500),
            GuidedAnchor(
                id: 'saved.departure',
                registry: GuidedAnchorRegistry.shared,
                child: const Text('Departure help')),
          ]),
          RealUiGuideCoachmark(coordinator: guide),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    final overlay = tester
        .widget<GuidedCoachmarkOverlay>(find.byType(GuidedCoachmarkOverlay));
    expect(overlay.targetId, 'saved.summary');
    expect(overlay.progressLabel, '3/7 · 저장된 일정 확인');
  });

  testWidgets('missing saved ID retries actual repository and anchors row',
      (tester) async {
    final guide = _Guide();
    final repo = _Repo();
    await tester.pumpWidget(app(guide, calendar(repo)));
    await tester.pumpAndSettle();
    expect(anchor(), findsNothing);
    expect(find.text('\uB2E4\uC2DC \uD655\uC778'), findsOneWidget);
    repo.rows = [saved()];
    await tester.ensureVisible(find.text('\uB2E4\uC2DC \uD655\uC778'));
    await tester.tap(find.text('\uB2E4\uC2DC \uD655\uC778'));
    await tester.pumpAndSettle();
    expect(repo.reads, 2);
    expect(
        tester
            .getRect(find.byType(CalendarScreen))
            .contains(tester.getCenter(anchor())),
        isTrue);
    expect(anchor(), findsOneWidget);
    expect(
        find.descendant(of: anchor(), matching: find.text('Actual saved row')),
        findsOneWidget);
  });
  testWidgets('real midnight-spanning saved row is visible before earlier rows',
      (tester) async {
    final late = EventModel(
        id: 'saved',
        userId: 'u',
        title: 'Late saved row',
        isMultiDay: true,
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2030, 1, 2, 23, 30),
        // banned-ok: Fixed event fixture for the guide assertion.
        endAt: DateTime(2030, 1, 3, 0, 30));
    expect(late.isMultiDay, isTrue);
    final early = EventModel(
        id: 'early',
        userId: 'u',
        title: 'Earlier row',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2030, 1, 2, 8),
        // banned-ok: Fixed event fixture for the guide assertion.
        endAt: DateTime(2030, 1, 2, 9));
    final repo = _Repo()..rows = [early, late];
    await tester.pumpWidget(app(_Guide(), calendar(repo)));
    await tester.pumpAndSettle();
    expect(anchor(), findsOneWidget);
    expect(
        tester
            .getRect(find.byType(CalendarScreen))
            .contains(tester.getCenter(anchor())),
        isTrue);
    expect(
        tester.getTopLeft(anchor()).dy,
        lessThan(tester
            .getTopLeft(find.text('Earlier row', skipOffstage: false).first)
            .dy));
  });
  testWidgets('offstage copy cannot register saved anchor', (tester) async {
    final guide = _Guide();
    final repo = _Repo()..rows = [saved()];
    await tester.pumpWidget(app(
        guide,
        Stack(children: [
          Offstage(offstage: true, child: calendar(repo)),
          calendar(repo)
        ])));
    await tester.pumpAndSettle();
    expect(anchor(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('duplicate saved identities fail closed', (tester) async {
    final repo = _Repo()..rows = [saved(), saved()];
    await tester.pumpWidget(app(_Guide(), calendar(repo)));
    await tester.pumpAndSettle();
    expect(anchor(), findsNothing);
    expect(find.text('\uB2E4\uC2DC \uD655\uC778'), findsOneWidget);
  });
  testWidgets('covered route withdraws saved anchor', (tester) async {
    final repo = _Repo()..rows = [saved()];
    await tester.pumpWidget(app(_Guide(), calendar(repo)));
    await tester.pumpAndSettle();
    expect(anchor(), findsOneWidget);
    final context = tester.element(find.byType(CalendarScreen));
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covered'))));
    await tester.pumpAndSettle();
    expect(anchor(), findsNothing);
  });
}
