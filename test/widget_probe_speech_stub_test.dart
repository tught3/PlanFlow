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
//   * warmUp-only init cannot prove the autoStart guard: a run that
//     calls `initialize` but never observes the public
//     `[STT] phase=start` / `attempt=normal` trace must NOT report
//     `postStartAvailability = true`.
//   * After a unit-controlled fake trace emit + a second `initialize`
//     call (proving the iOS warmUp + autoStart pattern), the
//     post-start guard flips to `true`.
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
  // 5. warmUp-only init cannot prove autoStart.
  // --------------------------------------------------------------------
  testWidgets(
    'warmUp-only initialize cannot prove the post-start guard',
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
        // Simulate warmUp only: one initialize, no autoStart listen.
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
          state.postStartAvailability,
          isFalse,
          reason: 'the post-start guard requires at least one observed start '
              'trace plus initCount >= 2',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  testWidgets(
    'two warmUp initializes before start cannot prove post-start availability',
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
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        expect(state.startAttempt, 1);
        expect(
          state.postStartAvailability,
          isFalse,
          reason: 'two pre-start warmUp calls plus a start trace must not '
              'substitute for an initialize observed after start',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  // --------------------------------------------------------------------
  // 6. After a unit-controlled fake trace + a second public
  //    initialize, the post-start guard flips to true. The trace emit
  //    here is unit-controlled (not part of Native PASS) — proving the
  //    guard's contract without faking production behavior.
  // --------------------------------------------------------------------
  testWidgets(
    'observed phase=start trace + second initialize flips '
    'postStartAvailability to true',
    (WidgetTester tester) async {
      final WidgetProbeSpeechStub stub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState state = stub.install();
      stub.installDebugPrintCapture(state);
      addTearDown(stub.remove);
      try {
        // First initialize: simulates warmUp.
        await SpeechToText().initialize(debugLogging: false);
        expect(
          state.initCount,
          1,
          reason: 'first initialize (warmUp) recorded',
        );

        // Unit-controlled fake trace emit. Mirrors what
        // SttService._logPhase('start', mode: dictation) emits in
        // production — but emitted here only to prove the capture
        // contract, NOT to claim Native GREEN.
        debugPrint(
          '[STT] phase=start gen=1 session=0 mode=dictation attempt=normal',
        );
        expect(
          state.startAttempt,
          1,
          reason: 'one matching trace was observed by the capture',
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

        // Second initialize: simulates the post-frame autoStart
        // listen and must occur after the observed start trace.
        await SpeechToText().initialize(debugLogging: false);
        expect(state.initBeforeStart, 1);
        expect(state.initAfterStart, 1);
        expect(
          state.initCount,
          2,
          reason: 'second initialize (autoStart) recorded after start',
        );

        expect(
          state.listenCount,
          0,
          reason: 'no native listen may be issued from QA',
        );
        expect(
          state.postStartAvailability,
          isTrue,
          reason: 'post-start guard requires initCount >= 2 AND startAttempt '
              '>= 1, both of which are now satisfied',
        );
        expect(
          state.receipt(),
          <String, int>{
            'init': 2,
            'listen': 0,
            'start_attempt': 1,
            'init_before_start': 1,
            'init_after_start': 1
          },
          reason: 'capped non-secret receipt must reflect the bounded counts '
              'for downstream diagnostic print lines',
        );
      } finally {
        stub.removeDebugPrintCapture(state);
      }
    },
  );

  // --------------------------------------------------------------------
  // 7. Repeated unavailable initialize preserves the public contract
  //    and does not require callers to reset private SDK state.
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
}
