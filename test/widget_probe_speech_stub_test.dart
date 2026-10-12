// Desktop unit test for the pinned speech_to_text protocol helper used
// by `integration_test/widget_launch_routing_native_probe.dart`.
//
// What this test proves (NOT just strings):
//
//   * The helper exposes the channel and method names that the pinned
//     `speech_to_text_platform_interface` 2.3.0 archive actually
//     invokes (channel: `plugin.csdcorp.com/speech_to_text`,
//     `has_permission`, `initialize`). Renaming any of those values in
//     the helper makes this test fail.
//   * The public `SpeechToText.hasPermission` getter and
//     `SpeechToText().initialize()` API surface from the existing
//     direct dependency `package:speech_to_text/speech_to_text.dart`
//     actually route through the helper's mock handler — proving the
//     pinned ABI, not just the helper's strings.
//   * Old wrong channel/method (`cjcodezonye.github.io/speech_to_text`,
//     `hasPermission`) is rejected by the helper as a mutation
//     negative control.
//   * warmUp-only init cannot prove any post-start guard: a run that
//     calls `initialize` but never observes the public
//     `[STT] phase=start` / `attempt=normal` trace must NOT report
//     `postStartBoundedRetry = true` or `postStartAvailability = true`.
//   * The finite-2 bounded-retry guard `postStartBoundedRetry` flips
//     to `true` only when two distinct start ordinals each observed
//     at least one post-start `initialize` handler call (the
//     per-attempt coverage model, not a `startAttempt == 1` proxy or
//     a `initCount >= 2` proxy).
//   * Two traces with the same `_activeListenGeneration` ordinal flag
//     `sameGenRepeated` and reject the bounded-retry guard. Three
//     traces flag `excessRetry` and reject the bounded-retry guard.
//     A pair of traces without any post-start init coverage flag
//     `missingPostCoverage` and reject the bounded-retry guard.
//   * Repeated unavailable initialize calls preserve the SDK public
//     contract: `false` is observed each time, no leak of listener
//     registration, no private state reset is required by callers.
//
// No online network, no `pub get`, no production code change, no
// microphone, no actual plugin recording, and no real SDK backend
// call are required to run this test.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../integration_test/support/widget_probe_speech_stub.dart';

void main() {
  // Resolve the workspace root from this test file's location. The
  // helper and pubspec.lock live in the same package root, and
  // reading the lock is purely a fixture check (no network).
  final Directory packageRoot = Directory.current;
  final File pubspecLock =
      File('${packageRoot.path}${Platform.pathSeparator}pubspec.lock');

  // --------------------------------------------------------------------
  // 1. Pinned protocol identity: pubspec.lock carries the exact SHA.
  // --------------------------------------------------------------------
  test(
    'pubspec.lock pins speech_to_text_platform_interface 2.3.0 '
    'with the documented SHA256',
    () {
      final String lock = pubspecLock.readAsStringSync();
      expect(
        lock.contains('speech_to_text_platform_interface'),
        isTrue,
        reason: 'pubspec.lock must list speech_to_text_platform_interface',
      );
      expect(
        lock.contains('version: "2.3.0"'),
        isTrue,
        reason: 'pubspec.lock must pin 2.3.0 exactly',
      );
      expect(
        lock.contains(
          'a1935847704e41ee468aad83181ddd2423d0833abe55d769c59afca07adb5114',
        ),
        isTrue,
        reason: 'pubspec.lock must carry the exact SHA256 captured from the '
            'pub.dev archive on 2026-10-12',
      );
      expect(
        lock.contains('speech_to_text'),
        isTrue,
        reason: 'pubspec.lock must list the speech_to_text package',
      );
    },
  );

  // --------------------------------------------------------------------
  // 2. Helper exposes the pinned protocol identity verbatim.
  // --------------------------------------------------------------------
  test('helper pinned channel name matches the plugin source', () {
    expect(
      WidgetProbeSpeechStub.pinnedChannelName,
      'plugin.csdcorp.com/speech_to_text',
      reason: 'pinned channel identity must match the value lifted from '
          'method_channel_speech_to_text.dart:9 of the 2.3.0 archive',
    );
    // Mutation negative: the regression-fixture wrong channel must NOT
    // be exposed as the pinned identity.
    expect(
      WidgetProbeSpeechStub.pinnedChannelName,
      isNot('cjcodezonye.github.io/speech_to_text'),
      reason: 'the legacy wrong channel name must never be accepted by the '
          'helper as the pinned identity',
    );
    // The public MethodChannel must wrap the same identity.
    expect(
      WidgetProbeSpeechStub.speechChannel.name,
      WidgetProbeSpeechStub.pinnedChannelName,
      reason: 'the public MethodChannel must wrap the same pinned name, so '
          'fixture and test cannot drift apart',
    );
  });

  test('helper pinned method names match the plugin source', () {
    expect(
      WidgetProbeSpeechStub.pinnedHasPermissionMethod,
      'has_permission',
      reason: 'pinned has_permission method name must match the value lifted '
          'from method_channel_speech_to_text.dart:28 of the 2.3.0 archive',
    );
    expect(
      WidgetProbeSpeechStub.pinnedInitializeMethod,
      'initialize',
      reason: 'pinned initialize method name must match the value lifted from '
          'method_channel_speech_to_text.dart:32-40 of the 2.3.0 archive',
    );
    // Mutation negatives: the legacy-fixture wrong names must NOT be
    // accepted.
    expect(
      WidgetProbeSpeechStub.pinnedHasPermissionMethod,
      isNot('hasPermission'),
      reason: 'the legacy wrong hasPermission (camelCase) name must never be '
          'accepted by the helper',
    );
    expect(
      WidgetProbeSpeechStub.pinnedInitializeMethod,
      isNot('Initialize'),
      reason: 'a capitalized Initialize variant must never be accepted by '
          'the helper',
    );
  });

  // --------------------------------------------------------------------
  // 3. Public SpeechToText API actually routes through the helper —
  //    this is the ABI proof, not just the string assertions above.
  // --------------------------------------------------------------------
  testWidgets(
    'SpeechToText().initialize() routes through the pinned channel '
    'and reports unavailable',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);

      final bool available =
          await SpeechToText().initialize(debugLogging: false);

      expect(
        available,
        isFalse,
        reason: 'the helper must report initialize() as unavailable so the '
            'production listen path aborts before calling listen',
      );
      expect(
        state.initCount,
        1,
        reason: 'exactly one initialize call must be observed',
      );
      expect(
        state.calls.length,
        1,
        reason: 'exactly one MethodCall must be recorded',
      );
      expect(
        state.calls.single.method,
        WidgetProbeSpeechStub.pinnedInitializeMethod,
        reason: 'the recorded method must be the pinned initialize name',
      );
      expect(
        state.postStartAvailability,
        isFalse,
        reason: 'a single initialize call (no autoStart trace observed) must '
            'not satisfy the post-start guard',
      );
    },
  );

  testWidgets(
    'SpeechToText.hasPermission routes through the pinned channel and '
    'preserves the regression-original bool',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);

      final bool hasPermission = await SpeechToText().hasPermission;

      expect(
        hasPermission,
        isTrue,
        reason: 'has_permission must preserve the regression-fixture-original '
            'value of true verbatim (no permission policy change)',
      );
      expect(
        state.calls.single.method,
        WidgetProbeSpeechStub.pinnedHasPermissionMethod,
        reason: 'the recorded method must be the pinned has_permission name '
            '(the legacy hasPermission camelCase must never be recorded)',
      );
      expect(
        state.initCount,
        0,
        reason: 'has_permission must not increment the initialize counter',
      );
    },
  );

  // --------------------------------------------------------------------
  // 4. Mutation negative: a wrong legacy channel is not intercepted by
  //    the helper, so the real plugin still routes through the pinned
  //    channel and reaches the helper's mock — proving the wrong
  //    channel is dead code.
  // --------------------------------------------------------------------
  testWidgets(
    'wrong legacy channel mock does not intercept the real plugin call',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);

      // Install a parallel mock on the LEGACY wrong channel name with
      // the LEGACY wrong hasPermission method. If either value had
      // been the pinned identity, the real plugin call would have
      // been intercepted by this parallel mock instead of by the
      // helper's pinned mock.
      const MethodChannel legacyChannel =
          MethodChannel('cjcodezonye.github.io/speech_to_text');
      final List<MethodCall> legacyCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        legacyChannel,
        (MethodCall call) async {
          legacyCalls.add(call);
          switch (call.method) {
            case 'hasPermission':
              return true;
            case 'initialize':
              return true;
            case 'listen':
              return null;
          }
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(legacyChannel, null);
      });

      final bool available =
          await SpeechToText().initialize(debugLogging: false);
      final bool hasPermission = await SpeechToText().hasPermission;

      expect(
        available,
        isFalse,
        reason: 'initialize() must reach the pinned mock (returning false); '
            'the legacy wrong-channel mock returning true must NOT have '
            'intercepted this call',
      );
      expect(
        hasPermission,
        isTrue,
        reason: 'has_permission must reach the pinned mock returning the '
            'regression-original true; the legacy wrong-channel mock '
            'must NOT have intercepted this call',
      );
      expect(
        legacyCalls,
        isEmpty,
        reason: 'the legacy wrong channel must NOT have intercepted any '
            'production call — the real plugin uses the pinned channel',
      );
      expect(
        state.initCount,
        1,
        reason: 'pinned mock observed exactly one initialize call',
      );
      expect(
        state.calls.length,
        2,
        reason: 'pinned mock observed exactly two calls in total',
      );
      expect(
        state.postStartAvailability,
        isFalse,
        reason: 'one initialize + one has_permission (no autoStart trace) '
            'must not satisfy the post-start guard',
      );
    },
  );

  // --------------------------------------------------------------------
  // 5. Finite-2 negative cases — each must reject `postStartBoundedRetry`.
  //
  // 5a. warmUp-only: one initialize before any start trace. The
  //     bounded-retry guard must remain `false` because there are
  //     zero observed starts.
  // 5b. warmUp + 1 start trace (gen=1) before any post-start init.
  //     Even with a matching trace, no initAfterStart coverage is
  //     recorded for the single ordinal, so the guard must remain
  //     `false`.
  // 5c. Two warmUp inits then unit-controlled gen=1 trace then
  //     gen=2 trace (no init after). The guard must remain `false`
  //     and `missingPostCoverage` must be `true`.
  // 5d. Same-gen doubling: gen=1 trace emitted twice (no fresh
  //     listen) plus one post-start init. `sameGenRepeated` must be
  //     `true` and the bounded-retry guard must remain `false`.
  // 5e. Three traces (gen=1, gen=2, gen=3) with corresponding
  //     post-start inits. `excessRetry` must be `true` and the
  //     bounded-retry guard must be `false` (more than the bounded
  //     budget).
  // --------------------------------------------------------------------
  testWidgets(
    'warmUp-only initialize cannot prove the post-start bounded-retry guard',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      // The Flutter test binding verifies that foundation debug
      // variables are restored before teardown runs, so the capture
      // must be restored inside the test body via try/finally rather
      // than via addTearDown. The helper's remove() is still safe via
      // addTearDown because the mock handler is not a foundation
      // variable.
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        final bool available =
            await SpeechToText().initialize(debugLogging: false);
        expect(available, isFalse);
        // No trace was emitted (warmUp does not call _logPhase('start')).
        expect(
          state.startAttempt,
          0,
          reason: 'no [STT] phase=start / attempt=normal trace may be observed '
              'from warmUp; warmUp-only init must NOT pass',
        );
        expect(
          state.initCount,
          1,
          reason: 'warmUp invoked initialize exactly once',
        );
        expect(
          state.startOrdinalsSeen,
          isEmpty,
          reason: 'no ordinals may be tracked without observed start traces',
        );
        expect(
          state.initAfterStartByOrdinal,
          isEmpty,
          reason: 'no per-ordinal init coverage may be tracked without '
              'observed start traces',
        );
        expect(
          state.postStartBoundedRetry,
          isFalse,
          reason: 'warmUp-only must remain `false` because `startAttempt` is '
              'below the bounded budget of 2',
        );
        expect(
          state.excessRetry,
          isFalse,
          reason: 'warmUp-only must not flag excess retry',
        );
        expect(
          state.missingPostCoverage,
          isFalse,
          reason: 'no ordinals means no per-ordinal coverage gap',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  testWidgets(
    'two warmUp initializes before any start cannot prove bounded retry',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        await SpeechToText().initialize(debugLogging: false);
        await SpeechToText().initialize(debugLogging: false);
        expect(state.initBeforeStart, 2);
        expect(state.initAfterStart, 0);
        expect(
          state.initAfterStartByOrdinal,
          isEmpty,
          reason: 'no trace observed yet, so no per-ordinal bucket',
        );
        expect(
          state.postStartBoundedRetry,
          isFalse,
          reason: 'two pre-start warmUp calls with no observed start trace '
              'must remain `false`',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  testWidgets(
    'two traces without post-start init coverage rejects bounded retry',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        // warmUp side: 1 init before any trace.
        await SpeechToText().initialize(debugLogging: false);
        // Two unit-controlled traces, NO initialize afterwards.
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        debugPrint(
          '[STT] phase=start gen=2 session=0 mode=dictation attempt=normal',
        );
        expect(state.startAttempt, 2);
        expect(
          state.startOrdinalsSeen.length,
          2,
          reason: 'two distinct ordinals must be observed',
        );
        expect(
          state.initAfterStart,
          0,
          reason: 'no init was observed after any of the traces',
        );
        expect(
          state.initAfterStartByOrdinal[1],
          isNull,
          reason: 'no init coverage for ordinal 1 must leave the bucket null',
        );
        expect(
          state.initAfterStartByOrdinal[2],
          isNull,
          reason: 'no init coverage for ordinal 2 must leave the bucket null',
        );
        expect(
          state.postStartBoundedRetry,
          isFalse,
          reason: 'a partial record without per-ordinal init coverage must '
              'not flip the bounded-retry guard to `true`',
        );
        expect(
          state.missingPostCoverage,
          isTrue,
          reason: 'both ordinals missing post-start init coverage must flip '
              'the rejection getter on',
        );
        expect(
          state.excessRetry,
          isFalse,
          reason: 'two traces must not by themselves flag excess retry',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  testWidgets(
    'same-gen doubling rejects bounded retry and flags sameGenRepeated',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        await SpeechToText().initialize(debugLogging: false);
        // Two unit-controlled traces with the SAME ordinal (gen=1),
        // simulating a counter doubling without a fresh listen call.
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        await SpeechToText().initialize(debugLogging: false);
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        await SpeechToText().initialize(debugLogging: false);
        expect(state.startAttempt, 2);
        expect(
          state.startOrdinalsSeen.length,
          1,
          reason: 'only one distinct ordinal was observed, both traces used '
              'gen=1',
        );
        expect(
          state.initAfterStartByOrdinal[1],
          2,
          reason: 'both post-start inits were bucketed under the same ordinal',
        );
        expect(
          state.sameGenRepeated,
          isTrue,
          reason: 'two traces observing a single ordinal must flag '
              'sameGenRepeated',
        );
        expect(
          state.postStartBoundedRetry,
          isFalse,
          reason: 'a same-gen doubling cannot satisfy the finite-2 distinct '
              'ordinals requirement',
        );
        expect(
          state.excessRetry,
          isFalse,
          reason: 'only two traces observed; budget not exceeded',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  testWidgets(
    'three traces reject bounded retry and flag excessRetry',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        await SpeechToText().initialize(debugLogging: false);
        // Three unit-controlled traces with distinct ordinals (gen=1,
        // 2, 3) and a post-start init after each one. The third
        // attempt exceeds the bounded budget of 2.
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        await SpeechToText().initialize(debugLogging: false);
        debugPrint(
          '[STT] phase=start gen=2 session=0 mode=dictation attempt=normal',
        );
        await SpeechToText().initialize(debugLogging: false);
        debugPrint(
          '[STT] phase=start gen=3 session=0 mode=dictation attempt=normal',
        );
        await SpeechToText().initialize(debugLogging: false);
        expect(state.startAttempt, 3);
        expect(state.startOrdinalsSeen.length, 3);
        expect(state.initAfterStart, 3);
        expect(
          state.excessRetry,
          isTrue,
          reason: 'three traces must exceed the bounded budget of 2',
        );
        expect(
          state.postStartBoundedRetry,
          isFalse,
          reason: 'three traces must NOT satisfy the finite-2 guard',
        );
        expect(
          state.missingPostCoverage,
          isFalse,
          reason: 'each ordinal has at least one post-start init, so coverage '
              'is complete (the rejection is on excess, not coverage)',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  // --------------------------------------------------------------------
  // 6. Positive case: TWO unit-controlled `[STT] phase=start`
  //    traces (gen=1 then gen=2) with one `initialize` AFTER each
  //    trace, mirroring the VoiceInputScreen bounded-retry policy
  //    under pinned-channel-unavailable. The bounded-retry guard
  //    must flip to `true`; the rejection getters must remain
  //    `false`.
  // --------------------------------------------------------------------
  testWidgets(
    'two distinct start traces with per-attempt post-start init flips '
    'postStartBoundedRetry to true',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        // warmUp side: 1 init before any trace.
        await SpeechToText().initialize(debugLogging: false);
        expect(
          state.initCount,
          1,
          reason: 'first initialize (warmUp) recorded',
        );

        // First unit-controlled fake trace emit (gen=1). Mirrors
        // what `SttService._logPhase('start', mode: dictation)`
        // emits in production — but emitted here only to prove the
        // capture contract, NOT to claim Native GREEN.
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        expect(
          state.startAttempt,
          1,
          reason: 'one matching trace was observed by the capture',
        );
        expect(
          state.startOrdinalsSeen,
          contains(1),
          reason: 'the captured gen=1 must be tracked as a distinct ordinal',
        );
        expect(
          state.currentStartOrdinal,
          1,
          reason: 'currentStartOrdinal must reflect the most-recent trace',
        );

        // Other debugPrint traffic must be forwarded (not captured)
        // and must not increment the counter.
        debugPrint('some unrelated log line');
        expect(
          state.startAttempt,
          1,
          reason: 'unrelated debugPrint traffic must NOT be counted',
        );

        // Other phase=start traces with attempt != normal must also
        // not increment the counter (Android warmup-retry style).
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation '
          'attempt=warmup-retry',
        );
        expect(
          state.startAttempt,
          1,
          reason: 'attempt!=normal phase=start traces must NOT be counted',
        );

        // First post-start init: simulates the first
        // `_listenWithSpeechToText` initialize after the first trace.
        await SpeechToText().initialize(debugLogging: false);
        expect(
          state.initAfterStartByOrdinal[1],
          1,
          reason: 'first post-start init must bucket under ordinal 1',
        );

        // Second unit-controlled fake trace emit (gen=2), modelling
        // the bounded 650 ms screen-level retry.
        debugPrint(
          '[STT] phase=start gen=2 session=0 mode=dictation attempt=normal',
        );
        expect(
          state.startAttempt,
          2,
          reason: 'second matching trace increments the bounded counter',
        );
        expect(
          state.startOrdinalsSeen,
          <int>{1, 2},
          reason: 'two distinct ordinals must be observed by the capture',
        );
        expect(
          state.currentStartOrdinal,
          2,
          reason: 'currentStartOrdinal must be updated to the second trace',
        );

        // Second post-start init: simulates the second listen
        // attempt's initialize handler call.
        await SpeechToText().initialize(debugLogging: false);
        expect(
          state.initAfterStartByOrdinal[2],
          1,
          reason: 'second post-start init must bucket under ordinal 2',
        );

        expect(
          state.initCount,
          3,
          reason: 'three initialize calls (warmUp + 2 listen attempts) '
              'were observed in total',
        );
        expect(
          state.initBeforeStart,
          1,
          reason: 'warmUp is the only pre-start init',
        );
        expect(
          state.initAfterStart,
          2,
          reason: 'two listen attempts each called initialize once',
        );
        expect(
          state.listenCount,
          0,
          reason: 'no native listen may be issued from QA',
        );
        expect(
          state.postStartBoundedRetry,
          isTrue,
          reason: 'finite-2: two distinct ordinals each with one post-start '
              'init must flip the bounded-retry guard to true',
        );
        expect(
          state.excessRetry,
          isFalse,
          reason: 'two traces remain within the bounded budget of 2',
        );
        expect(
          state.sameGenRepeated,
          isFalse,
          reason: 'distinct ordinals rule out a same-gen doubling',
        );
        expect(
          state.missingPostCoverage,
          isFalse,
          reason: 'each ordinal has at least one post-start init, so '
              'coverage is complete',
        );
        expect(
          state.receipt(),
          <String, int>{
            'init': 3,
            'listen': 0,
            'start_attempt': 2,
            'init_before_start': 1,
            'init_after_start': 2,
            'start_ordinals': 2,
          },
          reason: 'capped non-secret receipt must reflect the finite-2 counts '
              'for downstream diagnostic print lines',
        );
        expect(
          state.receiptBounded(),
          <String, Object>{
            'init': 3,
            'listen': 0,
            'start_attempt': 2,
            'init_before_start': 1,
            'init_after_start': 2,
            'start_ordinals': <int>[1, 2],
            'init_after_by_ordinal': <int, int>{1: 1, 2: 1},
            'excess_retry': false,
            'same_gen_repeated': false,
            'missing_post_coverage': false,
          },
          reason: 'per-ordinal receipt must show 1:1 and 2:1 coverage with '
              'no rejection flags flipped',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  // --------------------------------------------------------------------
  // 7. Repeated unavailable initialize preserves the public contract
  //    and does not require callers to reset private SDK state. The
  //    bounded-retry guard must remain `false` because no start trace
  //    is observed (initialize-only loops never log phase=start).
  // --------------------------------------------------------------------
  testWidgets(
    'repeated unavailable initialize preserves the public contract '
    'without private SDK state reset',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);

      // The fixture's contract is `false` every time, regardless of
      // how many times initialize() is called. The public SDK API
      // does not require any caller-side private state reset.
      for (int i = 0; i < 3; i++) {
        final bool available =
            await SpeechToText().initialize(debugLogging: false);
        expect(
          available,
          isFalse,
          reason: 'iteration $i: initialize() must report unavailable',
        );
      }
      expect(
        state.initCount,
        3,
        reason: 'three initialize calls were observed',
      );
      expect(
        state.calls.length,
        3,
        reason: 'three MethodCalls were recorded',
      );
      expect(
        state.listenCount,
        0,
        reason: 'no listen call must leak through, even on repeat',
      );

      // The production SDK re-uses the same channel handler across
      // calls; the helper does not own a private SpeechToText
      // singleton, and no listener cancel/stop mock is required
      // because initialize() returning false prevents the listen
      // path from registering a listener in the first place.
      expect(
        state.postStartAvailability,
        isFalse,
        reason: 'three initialize calls without an observed start trace must '
            'still not satisfy the post-start guard',
      );
      expect(
        state.postStartBoundedRetry,
        isFalse,
        reason: 'three initialize calls without observed start traces cannot '
            'satisfy the finite-2 guard either',
      );
      expect(
        state.excessRetry,
        isFalse,
        reason: 'no start traces means excessRetry must remain false',
      );
    },
  );

  // --------------------------------------------------------------------
  // 8. debugPrint capture is restored on tear-down, even if the test
  //    body throws. We simulate this by overriding debugPrint, then
  //    explicitly removing the capture and confirming the original is
  //    back. The Flutter test binding requires foundation debug
  //    variables to be restored before teardown runs, so the
  //    installation and removal both happen inside the test body.
  // --------------------------------------------------------------------
  testWidgets(
    'debugPrint capture is restored on removeDebugPrintCapture',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);

      final DebugPrintCallback originalDebugPrint = debugPrint;
      stub.installDebugPrintCapture(state);
      expect(
        identical(debugPrint, originalDebugPrint),
        isFalse,
        reason: 'debugPrint must be replaced while capture is active',
      );

      stub.removeDebugPrintCapture(state);
      expect(
        identical(debugPrint, originalDebugPrint),
        isTrue,
        reason: 'debugPrint must be restored to the previous implementation '
            'when removeDebugPrintCapture runs in a finally block, even '
            'after the surrounding test fails',
      );
    },
  );

  for (final String scenario in <String>[
    'two warm initializes then starts with no post coverage',
    'second attempt missing post coverage',
    'reversed generation order despite both post RPCs',
  ]) {
    testWidgets(scenario, (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      addTearDown(stub.remove);
      stub.installDebugPrintCapture(state);
      try {
        await SpeechToText().initialize(debugLogging: false);
        if (scenario.startsWith('two warm')) {
          await SpeechToText().initialize(debugLogging: false);
        }
        final bool reversed = scenario.startsWith('reversed');
        final List<int> generations = reversed ? <int>[2, 1] : <int>[1, 2];
        for (final int gen in generations) {
          debugPrint(
              '[STT] phase=start gen=$gen session=0 mode=dictation attempt=normal');
          if (reversed || (scenario.startsWith('second') && gen == 1)) {
            expect(
                await SpeechToText().initialize(debugLogging: false), isFalse);
          }
        }
        expect(state.startAttempt, 2);
        expect(state.startGenerationOrder, generations);
        expect(state.postStartBoundedRetry, isFalse);
        expect(state.listenCount, 0);
        expect(state.initAfterStart,
            reversed ? 2 : (scenario.startsWith('second') ? 1 : 0));
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    });
  }
}
