// Run ONLY on parent's private audio-enabled AVD. Never calls main(), loads
// .env, mocks SDK channels, types a transcript, or dispatches a guide signal.
// Runtime JSON: runId, expectedUid, approvedBackendHost, anonKey, session,
// maxAiRequests:3, dedicatedTestAccount:true, nativeEgressRestrictedByParent:true.
// Parent writes runtime via secure adb stdin to PLANFLOW_GUIDE_QA_RUNTIME.
// Controls are one-use app-private files documented by environment.control().
// Native recognition receipts must come from parent PID/session-correlated logs,
// not microphone activation. Missing receipt = FAIL, never native PASS.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:planflow/app.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/stt_service.dart';
import 'support/real_ui_guide_native_environment.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bounded actual app native real guide', (tester) async {
    final env = await NativeGuideEnvironment.load();
    final scopeKey = GlobalKey();
    final nativeSessions = <int>{};
    Future<void> waitFor(bool Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!predicate()) {
        if (env.failed || DateTime.now().isAfter(deadline)) {
          throw StateError('Bounded native guide wait failed');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    Future<void> tap(Finder finder) async {
      await waitFor(() => finder.evaluate().length == 1);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 300));
    }
    Finder anchor(String id) {
      final key = realUiGuideAnchorRegistry.keyFor(id);
      if (key == null) return find.byKey(ValueKey('unmounted:$id'));
      return find.byKey(key);
    }
    Future<void> tapAnchor(String id) async {
      await waitFor(() => realUiGuideAnchorRegistry.keyFor(id)?.currentContext != null);
      await tap(anchor(id));
    }
    GuideSnapshot state() => ProviderScope.containerOf(scopeKey.currentContext!)
        .read(realUiGuideCoordinatorProvider).state.value;
    Future<void> step(GuideStep value) => waitFor(() => state().step == value);
    Future<void> liveReceipt(String phase, {bool tapHome = false}) async {
      env.phase = phase;
      await env.journal('ARM_LIVE_SPEECH');
      if (tapHome) await tapAnchor('home.mic');
      // STT is the app's real service; observe read-only public session ID only.
      await waitFor(() => SttService.debugActiveNativeSessionId != null);
      final session = SttService.debugActiveNativeSessionId!;
      if (!nativeSessions.add(session)) throw StateError('Reused native session');
      final receipt = await tester.runAsync(() => env.control(phase));
      if (receipt == null || receipt['nativeSessionId'] != session ||
          receipt['nativePid'] is! int || (receipt['nativePid'] as int) <= 0 ||
          receipt['recognizedResultCount'] is! int ||
          (receipt['recognizedResultCount'] as int) < 1 ||
          receipt['source'] != 'parent_native_pid_log' ||
          receipt['liveMicrophone'] != true || receipt.containsKey('transcript')) {
        throw StateError('Missing actual native recognition evidence');
      }
      // Parent controls STOP on the actual UI; no injected text/callback/PCM.
      if (phase == 'create') {
        final stop = find.byKey(const ValueKey('voice-primary-button'));
        if (stop.evaluate().isNotEmpty && SttService.debugHasActiveListen) {
          await tap(stop);
        }
      }
      await env.journal('NATIVE_RECEIPT_PARENT_CORRELATED');
    }
    Future<List<Object?>> quota() async {
      final result = <Object?>[];
      for (final rpc in NativeGuideEnvironment.peeks) {
        result.add(await Supabase.instance.client.rpc(rpc));
      }
      return result;
    }
    try {
      await env.run(() async {
        await env.bootstrap();
        final before = await quota();
        await tester.pumpWidget(ProviderScope(child: Builder(
          key: scopeKey, builder: (_) => PlanFlowApp.forGuideQa())));
        for (var i = 0; i < 3; i++) {
          await tap(find.byKey(const ValueKey('legacy-intro-next-button')));
        }
        await step(GuideStep.homeMic);
        if (state().uid != env.uid || state().sessionId == null ||
            state().errorCode != null) throw StateError('Guide grant unavailable');
        await liveReceipt('create', tapHome: true);
        await step(GuideStep.correctAndSave);
        final title = find.byKey(const Key('event-editor-title-field'));
        await waitFor(() => title.evaluate().length == 1);
        final existing = tester.widget<TextFormField>(title).controller!.text;
        if (existing.trim().isEmpty) throw StateError('Missing real parsed title');
        await tester.enterText(title, '${env.marker} $existing');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        env.phase = 'save';
        await tapAnchor('confirm.save');
        await step(GuideStep.savedDetail);
        if (env.createdId == null || state().createdEventId != env.createdId) {
          throw StateError('Missing created ID binding');
        }
        await tapAnchor('calendar.saved');
        await tap(find.text('준비·출발 안내 확인'));
        await step(GuideStep.queryMic);
        env.phase = 'query';
        await tapAnchor('query.mic');
        await liveReceipt('query');
        await step(GuideStep.queryResults);
        if (state().createdEventId != env.createdId ||
            anchor('query.results').evaluate().isEmpty) {
          throw StateError('Missing bound actual query result');
        }
        // UI continues listening for the change; no coordinator dispatch.
        await liveReceipt('change');
        await step(GuideStep.editPreview);
        final repo = EventRepository.supabase();
        final original = await repo.fetchEvent(env.createdId!, userId: env.uid);
        if (original == null || original.startAt == null ||
            state().expectedUpdatedStartLocal == null ||
            original.startAt == state().expectedUpdatedStartLocal) {
          throw StateError('Missing real edit preview or early mutation');
        }
        final expected = state().expectedUpdatedStartLocal!;
        env.phase = 'editSave';
        await tapAnchor('edit.save');
        await step(GuideStep.updatedDetail);
        final updated = await repo.fetchEvent(env.createdId!, userId: env.uid);
        if (updated == null || updated.id != original.id ||
            updated.startAt?.toUtc() != expected.toUtc()) {
          throw StateError('Same-ID update readback failed');
        }
        // Remaining actual detail acknowledgement and NoSync buttons are
        // parent-controlled UI taps. Never choose an external calendar.
        final control = await tester.runAsync(() => env.control('syncNoExternal'));
        if (control?['noExternalCalendarChosen'] != true) {
          throw StateError('NoSync receipt required');
        }
        await step(GuideStep.completed);
        final after = await quota();
        if (jsonEncode(before) != jsonEncode(after) || env.aiRequests != 3 ||
            env.failed) throw StateError('Quota/budget proof failed');
        await env.journal('UI_COMPLETE_PARENT_NATIVE_RECEIPTS_REQUIRED_FOR_FULL_PASS');
      });
    } catch (_) {
      env.failed = true;
      await env.journal('FAIL_NO_RETRY');
      // Do not expose service exceptions, HTTP bodies or credentials.
      throw StateError('Native guide probe failed; inspect sanitized journal');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.close();
    }
  }, timeout: const Timeout(Duration(minutes: 9)));
}
