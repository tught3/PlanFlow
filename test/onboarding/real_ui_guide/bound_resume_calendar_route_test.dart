import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_route_recovery.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/home/home_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Guide implements GuideCoordinator {
  _Guide(EventModel saved)
      : state = ValueNotifier(GuideSnapshot(
          uid: 'u',
          revision: 1,
          serverRevision: 1,
          version: 'v',
          sessionId: 's',
          run: GuideRun.active,
          step: GuideStep.savedDetail,
          createdEventId: saved.id,
          savedLocalDate: saved.startAt,
        ));

  @override
  final ValueNotifier<GuideSnapshot> state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends EventRepository {
  _Repo(this.rows);

  final List<EventModel> rows;
  final reads = <(String?, String)>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => rows;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    reads.add((userId, eventId));
    return rows.singleWhere((event) => event.id == eventId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EventModel _event(String id, DateTime start) => EventModel(
      id: id,
      userId: 'u',
      title: 'Schedule $id',
      startAt: start,
      endAt: start.add(const Duration(hours: 1)),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://qa.example',
      anonKey: 'test-only-key',
      httpClient: MockClient(
          (request) async => http.Response('[]', 200, request: request)),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EventPrefetchService().invalidate();
  });

  for (final (beyondTopThree, recurring, duplicate) in [
    (false, false, false),
    (true, false, false),
    (false, true, false),
    (false, false, true),
  ]) {
    final position = beyondTopThree ? 'fourth upcoming' : 'listed today';
    final description = duplicate
        ? 'a hidden duplicate ID rules out the otherwise visible Home card'
        : recurring
            ? 'a recurring saved ID never receives the Home guide anchor'
            : 'saved detail reveals and opens the exact $position Home card';
    testWidgets(description, (tester) async {
      // banned-ok: Fixed clock for today and upcoming schedule fixtures.
      final now = DateTime(2030, 1, 2, 9);
      final soon = now.add(const Duration(hours: 1));
      final saved = _event(
        'saved',
        beyondTopThree ? soon.add(const Duration(days: 2)) : soon,
      ).copyWith(recurrenceRule: recurring ? 'FREQ=DAILY' : null);
      final repo = _Repo([
        ...List.generate(3, (i) {
          final lead = beyondTopThree ? 24 + i : 1 + i;
          return _event('other-$i', soon.add(Duration(hours: lead)));
        }),
        saved,
        if (duplicate)
          _event(saved.id, soon.subtract(const Duration(days: 45))),
      ]);
      final guide = _Guide(saved);
      addTearDown(guide.state.dispose);

      final router = GoRouter(initialLocation: AppRoutes.calendar, routes: [
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) => const Scaffold(body: Text('Calendar')),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => HomeScreen(
            eventRepository: repo,
            userIdOverride: 'u',
            loadHeaderSummary: false,
            nowProvider: () => now,
          ),
        ),
        GoRoute(
          path: '${AppRoutes.eventDetail}/:id',
          builder: (_, state) => Scaffold(
            body: Text('Detail ${state.pathParameters['id']}'),
          ),
        ),
      ]);
      addTearDown(router.dispose);

      await tester.pumpWidget(GuideScope(
        coordinator: guide,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => Stack(fit: StackFit.expand, children: [
            child!,
            RealUiGuideCoachmark(coordinator: guide),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      if (recurring || duplicate) {
        router.go(AppRoutes.home);
      } else {
        final recovery = await GuideRouteRecovery.load(
          coordinator: guide,
          currentUid: () => 'u',
          attachedToRoute: () => true,
          read: (_, __) async => [saved],
        );
        router.go(recovery!.location);
      }
      // The highlighted card pulses while the guide remains on this step.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(router.routeInformationProvider.value.uri.path, AppRoutes.home);
      expect(find.byType(HomeScreen), findsOneWidget);
      final anchor = find.byWidgetPredicate(
        (widget) => widget is GuidedAnchor && widget.id == 'home.saved',
      );
      if (recurring || duplicate) {
        expect(anchor, findsNothing);
        expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is GuidedAnchor && widget.id == 'home.saved.retry',
            ),
            findsOneWidget);
        expect(guide.state.value.step, GuideStep.savedDetail);
        expect(repo.reads, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      final anchoredTitle =
          find.descendant(of: anchor, matching: find.text(saved.title));
      expect(anchor, findsOneWidget);
      expect(anchoredTitle.hitTestable(), findsOneWidget);
      expect(find.text(saved.title), findsOneWidget);
      expect(
        tester
            .widget<GuidedCoachmarkOverlay>(
              find.byType(GuidedCoachmarkOverlay),
            )
            .targetId,
        'home.saved',
      );
      if (beyondTopThree) expect(repo.reads, [('u', saved.id)]);

      await tester.tap(anchoredTitle);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Detail saved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
