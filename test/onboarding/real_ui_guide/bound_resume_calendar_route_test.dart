import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

// H1 reproduction: the guide navigates to `/calendar?date=YYYY-MM-DD` from the
// saved detail. router.dart builds ShellScreen(initialCalendarDate) and
// shell_screen.dart builds CalendarScreen(initialDate: ...) WITHOUT
// suppressInitialDaySheet (default false), so CalendarScreen opens the
// day-events modal sheet after the first load. The sheet makes the main route
// non-current, which withdraws the `calendar.saved` anchor.
//
// Harness limits (reported, not hidden): ShellScreen itself needs Supabase/auth
// and is not instantiated. Instead the exact CalendarScreen constructor call
// that ShellScreen._buildTabChild makes (initialDate only, suppress default,
// briefingIsMorning null) is placed behind a real GoRouter `/calendar?date=`
// route that mirrors router.dart. Data comes from an injected fake repository.
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
  _Repo(this.rows);
  final List<EventModel> rows;
  @override
  Future<List<EventModel>> listEvents({String? userId}) async => rows;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EventModel _saved() => EventModel(
    id: 'saved',
    userId: 'u',
    title: 'Actual saved row',
    // banned-ok: Fixed event fixture for the guide assertion.
    startAt: DateTime(2030, 1, 2, 10),
    // banned-ok: Fixed event fixture for the guide assertion.
    endAt: DateTime(2030, 1, 2, 11));

Finder _sheet() =>
    find.byKey(const ValueKey('calendar-day-events-draggable-sheet'));
Finder _savedAnchor() => find.byWidgetPredicate(
    (w) => w is GuidedAnchor && w.id == 'calendar.saved',
    skipOffstage: false);
Finder _overlay() => find.byType(GuidedCoachmarkOverlay);
Finder _waitingPanel() => find.byKey(const ValueKey('guide-missing-target-skip'));

DateTime? _parse(String? raw) =>
    raw == null || raw.trim().isEmpty ? null : DateTime.tryParse(raw.trim());

/// Expected behavior: after the guide lands on the calendar day, either no day
/// sheet covers the calendar, or (if a sheet is shown) the `calendar.saved`
/// anchor is still current/visible in the registry and the coachmark renders.
void _expectGuideStillCoaches(WidgetTester tester, String label) {
  final sheetOpen = _sheet().evaluate().isNotEmpty;
  final anchorMounted = _savedAnchor().evaluate().isNotEmpty;
  final anchorContext =
      realUiGuideAnchorRegistry.keyFor('calendar.saved')?.currentContext;
  final anchorIsCurrent = anchorContext != null &&
      anchorContext.mounted &&
      ModalRoute.of(anchorContext)?.isCurrent == true;
  final overlayRendered = _overlay().evaluate().isNotEmpty;
  final waitingPanel = _waitingPanel().evaluate().isNotEmpty;
  // Not vacuous: the saved row must really be on screen (guards against a
  // load failure / empty screen passing), and the anchor must be mounted,
  // current, with the coachmark rendered and no "waiting" fallback panel,
  // whether or not a day sheet is open.
  expect(find.text('Actual saved row', skipOffstage: false), findsWidgets,
      reason: '$label: saved row is not on screen (load failed/empty screen)');
  expect(anchorMounted, isTrue,
      reason: '$label: calendar.saved anchor is not mounted '
          '(sheetOpen=$sheetOpen)');
  expect(anchorIsCurrent, isTrue,
      reason: '$label: calendar.saved anchor is not current/visible in the '
          'registry (sheetOpen=$sheetOpen, anchorMounted=$anchorMounted)');
  expect(overlayRendered, isTrue,
      reason: '$label: no GuidedCoachmarkOverlay is rendered '
          '(sheetOpen=$sheetOpen, waitingPanel=$waitingPanel)');
  expect(waitingPanel, isFalse,
      reason: '$label: guide fell back to the missing-target waiting panel');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EventPrefetchService().invalidate();
  });

  Widget hosted(_Guide guide, Widget? child) => Stack(fit: StackFit.expand, children: [
        if (child != null) child,
        RealUiGuideCoachmark(coordinator: guide),
      ]);

  testWidgets(
      'CalendarScreen(initialDate) with default suppressInitialDaySheet keeps '
      'the saved coachmark', (tester) async {
    final guide = _Guide();
    final repo = _Repo([_saved()]);
    try {
      await tester.pumpWidget(GuideScope(
          coordinator: guide,
          child: MaterialApp(
            builder: (context, child) => hosted(guide, child),
            home: CalendarScreen(
                // Same arguments ShellScreen passes: initialDate only.
                // banned-ok: Fixed event fixture for the guide assertion.
                initialDate: DateTime(2030, 1, 2),
                eventRepository: repo,
                userId: 'u'),
          )));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      _expectGuideStillCoaches(tester, 'direct');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
      'real GoRouter go(/calendar?date=) from saved detail keeps the saved '
      'coachmark', (tester) async {
    final guide = _Guide();
    final repo = _Repo([_saved()]);
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('saved detail placeholder'))),
      // Mirrors router.dart:166-172 + shell_screen.dart:1235-1242.
      GoRoute(
          path: '/calendar',
          builder: (context, state) => CalendarScreen(
                key: ValueKey<String>('calendar-${state.uri.query}'),
                initialDate: _parse(state.uri.queryParameters['date']),
                eventRepository: repo,
                userId: 'u',
              )),
    ]);
    try {
      await tester.pumpWidget(GuideScope(
          coordinator: guide,
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => hosted(guide, child),
          )));
      await tester.pumpAndSettle();
      router.go('/calendar?date=2030-01-02');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      _expectGuideStillCoaches(tester, 'router');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
