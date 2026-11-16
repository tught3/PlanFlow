import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_local_backend.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:planflow/widgets/planflow_voice_fab.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _uid = 'local-guide-widget-user';
const _legacyVersion = 'real_ui_v1';

void main() {
  testWidgets(
      'signed-in guide reaches the 1/7 home mic locally '
      'with a fresh store or a legacy completion', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Mount both stores within one widget clock because the local backend
    // serializes writes across provider containers in the same isolate.
    await _expectLocalStart(tester, legacyCompleted: false);
    await _expectLocalStart(tester, legacyCompleted: true);
  });
}

Future<void> _expectLocalStart(
  WidgetTester tester, {
  required bool legacyCompleted,
}) async {
  SharedPreferences.setMockInitialValues({});

  expect(() => Supabase.instance, throwsAssertionError);
  final auth = AuthProvider()..setUser(_uid);
  addTearDown(auth.dispose);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  expect(container.read(realUiGuideBackendProvider), isA<LocalGuideBackend>());
  final progress = container.read(realUiGuideProgressStoreProvider);
  if (legacyCompleted) {
    await progress.save(const GuideSnapshot(
      uid: _uid,
      version: _legacyVersion,
      revision: 9,
      serverRevision: 5,
      step: GuideStep.completed,
      run: GuideRun.terminal,
      sessionId: 'legacy-server-session',
    ));
  }

  final navigator = GlobalKey<NavigatorState>();
  var httpAttempts = 0;
  await HttpOverrides.runZoned(() async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => RootGuideScope(
          uid: auth.userId,
          isGuideQa: true,
          bindRuntime: (guide) => GuideQuotaRuntime.bind(guide, uid: _uid),
          unbindRuntime: GuideQuotaRuntime.unbind,
          child: child!,
        ),
        home: Scaffold(
          floatingActionButton: GuidedAnchor(
            id: 'home.mic',
            registry: realUiGuideAnchorRegistry,
            child: PlanFlowVoiceFab(onPressed: () {}),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final guide = container.read(realUiGuideCoordinatorProvider);
    expect(GuideQuotaRuntime.current(() => _uid), same(guide));
    expect(guide.state.value.step, GuideStep.intro);
    expect(guide.state.value.errorCode, isNull);
    expect(guide.state.value.sessionId, 'local-$_uid-$realUiGuideVersion');
    final tour = GuideAccountFeatureTourStore(
      uidProvider: () => auth.userId,
      progress: progress,
    );
    expect(await tour.shouldShow(), isTrue);
    final introClosed = navigator.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => LegacyIntroScreen(store: tour)),
    );
    await tester.pumpAndSettle();
    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    expect(find.text('1/7 · 음성으로 입력 시작'), findsNothing);

    final next = find.byKey(const ValueKey('legacy-intro-next-button'));
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('시작하기'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    await introClosed;
    expect(await tour.shouldShow(), isFalse);
    await guide.dispatch(IntroFinished(
      uid: _uid,
      expectedRevision: guide.state.value.revision,
    ));
    // The visible home coachmark pulses, so pump its layout pass directly.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(LegacyIntroScreen), findsNothing);
    expect(find.text('1/7 · 음성으로 입력 시작'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
    final overlay = tester.widget<GuidedCoachmarkOverlay>(
      find.byType(GuidedCoachmarkOverlay),
    );
    expect(overlay.targetId, 'home.mic');
    expect(
        overlay.registry.keyFor(overlay.targetId)?.currentContext, isNotNull);
    expect(guide.state.value.run, GuideRun.active);
    expect(guide.state.value.step, GuideStep.homeMic);
    final stored = await progress.load(uid: _uid, version: realUiGuideVersion);
    expect(stored?.step, GuideStep.homeMic);
    expect(stored?.sessionId, guide.state.value.sessionId);
    if (legacyCompleted) {
      final legacy = await progress.load(uid: _uid, version: _legacyVersion);
      expect(legacy?.step, GuideStep.completed);
      expect(legacy?.sessionId, 'legacy-server-session');
    }
    expect(() => Supabase.instance, throwsAssertionError);

    await tester.pumpWidget(const SizedBox.shrink());
    auth.setUser(null);
    await tester.pump();
    expect(GuideQuotaRuntime.current(() => _uid), isNull);
  }, createHttpClient: (_) {
    httpAttempts++;
    throw StateError('Guide startup attempted to create an HTTP client');
  });
  expect(httpAttempts, 0);
}
