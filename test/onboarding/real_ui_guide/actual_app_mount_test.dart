import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import '../../support/real_ui_guide_actual_app_harness.dart';

void main() {
  testWidgets('actual intro to home guide skip to calendar sync choice',
      (tester) async {
    final h = RealUiGuideActualAppHarness();
    addTearDown(h.dispose);
    await h.install();
    for (var i = 0; i < 12 && !authProvider.hasResolvedInitialSession; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    h.assertReady(); // fail closed BEFORE mounting the app
    expect(authProvider.isSignedIn, isTrue);
    await tester.pumpWidget(h.buildApp());
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlanFlowApp), findsOneWidget);
    expect(find.byType(ShellScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LegacyIntroScreen), findsOneWidget);
    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);

    // Advance only through actual intro UI controls, observing every page.
    for (final title in ['말하면 일정이 정리돼요', 'AI 대화로 일정도 고쳐요']) {
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('legacy-intro-next-button')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('legacy-intro-next-button')));
    for (var i = 0;
        i < 15 && find.text('1/7 · 음성으로 입력 시작').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('외부 캘린더 동기화 안내'), findsNothing,
        reason: 'calendar sync choice must not precede real guide Skip');
    expect(find.text('1/7 · 음성으로 입력 시작'), findsOneWidget);
    expect(find.byType(RealUiGuideCoachmark), findsOneWidget);
    expect(find.text('음성으로 새 일정 추가하기'), findsOneWidget,
        reason: 'real home microphone anchor is mounted; do not tap it');
    expect(h.backend.begins, 1);
    expect(h.backend.advances, 0);
    expect(h.backend.authorizations, 0);
    expect(h.backend.finishes, 0);
    expect(h.requests.every((r) => r.contains('planflow-actual-mount.invalid')),
        isTrue);
    expect(h.requests.any((r) => r.contains('/auth/v1/')), isFalse);
    expect(h.requests.any((r) => r.contains('/functions/')), isFalse);
    // AuthProvider initial event and bootstrap each call actual ensureProfile.
    // Both writes MUST be rejected, never faked as successful or forwarded.
    const profileWrite = 'POST https://planflow-actual-mount.invalid/rest/v1/users?on_conflict=id';
    expect(h.denied, [profileWrite, profileWrite],
        reason: 'only the two source-backed bootstrap profile writes may be attempted, both denied');
    expect(h.nativeCalls, isEmpty, reason: 'native SDK calls remain fenced');

    // Explicitly skip the real coachmark from its UI, never entering its mic.
    await tester.tap(find.text('안내 건너뛰기'));
    await tester.pump(const Duration(milliseconds: 1));
    for (var i = 0;
        i < 15 && find.text('외부 캘린더 동기화 안내').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('외부 캘린더 동기화 안내'), findsOneWidget,
        reason: 'skip must proceed to the existing calendar sync choice modal');
    expect(h.backend.advances, 0);
    expect(h.backend.authorizations, 0);
    expect(h.backend.finishes, 1);
    expect(h.backend.exits, [GuideExit.skip]);
    expect(find.byType(RealUiGuideCoachmark), findsNothing);
    expect(h.denied, [profileWrite, profileWrite],
        reason: 'Skip must add no writes, AI, ordinary quota or unknown HTTP');
    expect(h.nativeCalls, isEmpty);
    debugPrint('QA shell counters: begin=${h.backend.begins}, advance=${h.backend.advances}, authorize=${h.backend.authorizations}, finish=${h.backend.finishes}; HTTP=${h.requests}; denied=${h.denied}; native=${h.nativeCalls}');
    // Resolve the existing dialog via its safe no-sync UI to release the
    // production stage timeout. Never open settings or start calendar sync.
    await tester.tap(find.text('동기화 안 함'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    // Deferred startup callbacks see an unmounted shell before their 1s delay.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(h.backend.finishes, 1);
    expect(h.backend.advances, 0);
    expect(h.backend.authorizations, 0);
    expect(h.denied, [profileWrite, profileWrite]);
    expect(h.nativeCalls, isEmpty);
    expect(tester.takeException(), isNull);
  },
      // Enable this host-only harness with --dart-define=PLANFLOW_GUIDE_QA=true.
      skip: !const bool.fromEnvironment('PLANFLOW_GUIDE_QA'));
}
