// Legacy voice-first intro screen tests.
//
// Covers the contract restored from the pre-WIP `feature_tour_screen.dart`
// (git 87256e3f): three ordered pages, no premature completion, final-page
// success path with a readback guard, retry on persistence failure, and
// double-tap protection. All persistence is mocked via [_FakeFeatureTourStore]
// — no real SharedPreferences, network, or platform channels are touched.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

/// In-memory [FeatureTourStore] for widget tests. Mirrors the public
/// contract of `SharedPreferencesFeatureTourStore` but stays entirely on
/// the test isolate — no SharedPreferences plugin is loaded.
class _FakeFeatureTourStore extends FeatureTourStore {
  int markCompletedCalls = 0;
  int shouldShowCalls = 0;
  bool shouldShowResult = false;
  Object? markCompletedError;
  Duration markCompletedDelay = Duration.zero;

  @override
  Future<void> markCompleted() async {
    markCompletedCalls++;
    if (markCompletedDelay > Duration.zero) {
      await Future<void>.delayed(markCompletedDelay);
    }
    final err = markCompletedError;
    if (err != null) {
      throw err;
    }
  }

  @override
  Future<bool> shouldShow() async {
    shouldShowCalls++;
    return shouldShowResult;
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => false;

  @override
  Future<void> markTipShown(String tipId) async {}
}

Widget _harness({
  required FeatureTourStore store,
  VoidCallback? onCompleted,
  bool requireFinalConfirmation = true,
  GuideCoordinator? guide,
  bool allowBackSkip = false,
  bool pushIntroRoute = false,
}) {
  final intro = LegacyIntroScreen(
    store: store,
    onCompleted: onCompleted,
    requireFinalConfirmation: requireFinalConfirmation,
  );
  final app = MaterialApp(
    home: !pushIntroRoute
        ? Scaffold(body: intro)
        : Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('open-intro-route'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(body: intro),
                    ),
                  ),
                  child: const Text('Previous screen'),
                ),
              ),
            ),
          ),
  );
  return guide == null
      ? app
      : GuideScope(
          coordinator: guide,
          allowBackSkip: allowBackSkip,
          child: app,
        );
}

class _BackGuide implements GuideCoordinator {
  _BackGuide(GuideRun run)
      : state = ValueNotifier(GuideSnapshot(
          uid: 'guide-user',
          version: 'real_ui_v1',
          sessionId: 'guide-session',
          revision: 1,
          serverRevision: 1,
          step: GuideStep.intro,
          run: run,
          pauseReason:
              run == GuideRun.paused ? GuidePauseReason.background : null,
        ));

  @override
  final ValueNotifier<GuideSnapshot> state;
  final exits = <GuideExit>[];

  @override
  Future<void> terminate(GuideExit exit) async {
    exits.add(exit);
    state.value = state.value.copyWith(
      run: GuideRun.terminal,
      step: GuideStep.skipped,
      revision: state.value.revision + 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _openIntroRoute(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.tap(find.byKey(const ValueKey('open-intro-route')));
  await tester.pumpAndSettle();
}

Future<void> _advanceToLastPage(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.tap(
      find.byKey(const ValueKey('legacy-intro-next-button')),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  group('LegacyIntroScreen', () {
    testWidgets('Back skips an active guide and exits the required intro',
        (tester) async {
      final store = _FakeFeatureTourStore();
      final guide = _BackGuide(GuideRun.active);
      await _openIntroRoute(
        tester,
        _harness(
          store: store,
          guide: guide,
          allowBackSkip: true,
          pushIntroRoute: true,
        ),
      );

      expect(find.byType(LegacyIntroScreen), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(LegacyIntroScreen), findsNothing);
      expect(find.text('Previous screen'), findsOneWidget);
      expect(guide.exits, [GuideExit.skip]);
      expect(store.markCompletedCalls, 0);
    });

    testWidgets('QA mode blocks Back from skipping the required intro',
        (tester) async {
      final store = _FakeFeatureTourStore();
      final guide = _BackGuide(GuideRun.active);
      await _openIntroRoute(
        tester,
        _harness(
          store: store,
          guide: guide,
          allowBackSkip: false,
          pushIntroRoute: true,
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(LegacyIntroScreen), findsOneWidget);
      expect(find.text('Previous screen'), findsNothing);
      expect(guide.exits, isEmpty);
      expect(store.markCompletedCalls, 0);
    });

    testWidgets(
        'Back exits intro after root Back already skipped a paused guide',
        (tester) async {
      final store = _FakeFeatureTourStore();
      final guide = _BackGuide(GuideRun.paused);
      await _openIntroRoute(
        tester,
        _harness(
          store: store,
          guide: guide,
          allowBackSkip: true,
          pushIntroRoute: true,
        ),
      );

      // RootGuideScope consumes the first Back while dismissing its recovery
      // overlay and leaves this intro route underneath in terminal/skipped.
      await guide.terminate(GuideExit.skip);
      await tester.pump();
      expect(guide.state.value.run, GuideRun.terminal);
      expect(guide.state.value.step, GuideStep.skipped);
      expect(find.byType(LegacyIntroScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(LegacyIntroScreen), findsNothing);
      expect(find.text('Previous screen'), findsOneWidget);
      expect(guide.exits, [GuideExit.skip]);
      expect(store.markCompletedCalls, 0);
    });

    testWidgets(
      'renders the three original pages in order with 시작하기 on the last',
      (tester) async {
        final store = _FakeFeatureTourStore();
        await tester.pumpWidget(_harness(store: store));

        // Page 1.
        expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
        expect(find.text('AI 대화로 일정도 고쳐요'), findsNothing);
        expect(find.text('출발과 브리핑을 챙겨드려요'), findsNothing);
        expect(find.text('다음'), findsOneWidget);
        expect(find.text('시작하기'), findsNothing);

        // Swipe to page 2.
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(find.text('말하면 일정이 정리돼요'), findsNothing);
        expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
        expect(find.text('출발과 브리핑을 챙겨드려요'), findsNothing);

        // Swipe to page 3.
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
        expect(
          find.text(
              '장소가 확인된 일정은 예상 이동 시간과 준비·출발 시점을 알려드려요. 하루 일정은 브리핑으로 정리해드려요.'),
          findsOneWidget,
        );
        expect(find.text('장소를 확인한 일정은 출발 알림으로, 하루 일정은 브리핑으로 알려드려요.'),
            findsNothing);
        expect(find.text('시작하기'), findsOneWidget);
        expect(find.text('다음'), findsNothing);
      },
    );

    testWidgets(
      'next on first or middle page never persists or completes',
      (tester) async {
        final store = _FakeFeatureTourStore();
        await tester.pumpWidget(_harness(store: store));

        // Page 1 → next.
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();
        expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
        expect(store.markCompletedCalls, 0);
        expect(store.shouldShowCalls, 0);

        // Page 2 → next.
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();
        expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
        expect(store.markCompletedCalls, 0);
        expect(store.shouldShowCalls, 0);
      },
    );

    testWidgets(
      'start on last page persists, readback returns false, then onCompleted',
      (tester) async {
        final store = _FakeFeatureTourStore()..shouldShowResult = false;
        var onCompletedCalls = 0;
        await tester.pumpWidget(_harness(
          store: store,
          onCompleted: () => onCompletedCalls++,
        ));

        await _advanceToLastPage(tester);

        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();

        expect(store.markCompletedCalls, 1);
        expect(store.shouldShowCalls, 1);
        expect(onCompletedCalls, 1);
        expect(
          find.byKey(const ValueKey('legacy-intro-error-message')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'readback true keeps the page, shows retry, and a retry re-invokes store',
      (tester) async {
        final store = _FakeFeatureTourStore()..shouldShowResult = true;
        var onCompletedCalls = 0;
        await tester.pumpWidget(_harness(
          store: store,
          onCompleted: () => onCompletedCalls++,
        ));

        await _advanceToLastPage(tester);

        // First attempt: shouldShow still true → no completion.
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();
        expect(store.markCompletedCalls, 1);
        expect(store.shouldShowCalls, 1);
        expect(onCompletedCalls, 0);
        expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('legacy-intro-error-message')),
          findsOneWidget,
        );

        // Flip the fake to simulate eventual persistence; retry must drive
        // a second round-trip without leaving the page.
        store.shouldShowResult = false;
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();
        expect(store.markCompletedCalls, 2);
        expect(store.shouldShowCalls, 2);
        expect(onCompletedCalls, 1);
        expect(
          find.byKey(const ValueKey('legacy-intro-error-message')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'double-tap on last page only persists and completes once',
      (tester) async {
        final store = _FakeFeatureTourStore()
          ..markCompletedDelay = const Duration(milliseconds: 80);
        var onCompletedCalls = 0;
        await tester.pumpWidget(_harness(
          store: store,
          onCompleted: () => onCompletedCalls++,
        ));

        await _advanceToLastPage(tester);

        // First tap: kicks off the async persistence; _isCompleting flips
        // synchronously to true so the second tap must short-circuit.
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        // Don't pumpAndSettle — the in-flight delay is what we're racing.
        await tester.tap(
          find.byKey(const ValueKey('legacy-intro-next-button')),
        );
        await tester.pumpAndSettle();

        expect(store.markCompletedCalls, 1);
        expect(store.shouldShowCalls, 1);
        expect(onCompletedCalls, 1);
      },
    );
  });
}
