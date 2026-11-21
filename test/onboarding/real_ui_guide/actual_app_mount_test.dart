import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import '../../support/real_ui_guide_actual_app_harness.dart';

void main() {
  // The hosted harness requires a compile-time QA fence; only a verified
  // device package can enable runtime QA behavior in the actual app.
  if (const bool.fromEnvironment('PLANFLOW_GUIDE_QA')) {
    testWidgets('actual app Home Back ends the guide and opens normal sync',
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
        await tester
            .tap(find.byKey(const ValueKey('legacy-intro-next-button')));
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
          reason: 'calendar sync choice follows the active guide');
      expect(find.text('1/7 · 음성으로 입력 시작'), findsOneWidget);
      expect(find.byType(RealUiGuideCoachmark), findsOneWidget);
      expect(find.text('음성으로 새 일정 추가하기'), findsOneWidget,
          reason: 'real home microphone anchor is mounted; do not tap it');
      expect(h.backend.begins, 1);
      expect(h.backend.advances, 0);
      expect(h.backend.authorizations, 0);
      expect(h.backend.finishes, 0);
      expect(
          h.requests.every((r) => r.contains('planflow-actual-mount.invalid')),
          isTrue);
      expect(h.requests.any((r) => r.contains('/auth/v1/')), isFalse);
      expect(h.requests.any((r) => r.contains('/functions/')), isFalse);
      // AuthProvider initial event and bootstrap each call actual ensureProfile.
      // Both writes MUST be rejected, never faked as successful or forwarded.
      const profileWrite =
          'POST https://planflow-actual-mount.invalid/rest/v1/users?on_conflict=id';
      expect(h.denied, [profileWrite, profileWrite],
          reason:
              'only the two source-backed bootstrap profile writes may be attempted, both denied');
      expect(h.nativeCalls, isEmpty, reason: 'native SDK calls remain fenced');

      expect(find.text('안내 건너뛰기'), findsNothing);
      expect(
          GuideScope.allowBackSkipOf(tester.element(find.byType(ShellScreen))),
          isTrue);
      expect(appRouter.canPop(), isFalse);
      await tester.binding.handlePopRoute();
      final sync = find.text('외부 캘린더 동기화 안내');
      for (var i = 0; i < 25 && sync.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('1/7 · 음성으로 입력 시작'), findsNothing);
      expect(sync, findsOneWidget);
      expect(currentAppRouterLocation(appRouter).path, AppRoutes.home);
      expect(h.backend.exits, [GuideExit.skip]);
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
    });
  }
}
