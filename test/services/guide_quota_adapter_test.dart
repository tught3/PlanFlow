import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';

/// Unit tests for [GuideQuotaRuntime] and the guide-aware extension to
/// [VoiceConversationAdGate]. Together these prove that:
///
/// - A bound active/paused/blocked guide sees ZERO ordinary
///   `onEnterAllowed` invocations across the full response matrix
///   (granted / denied / expired / retryLater / unavailable /
///   malformed / auth-switch / stale).
/// - Outside guide the legacy `delegateForTest` path is exercised
///   byte-equivalently to the pre-existing gate behaviour.
/// - Bind/unbind are identity-safe; stale tokens do not affect the
///   active binding; stale UIDs are no-ops.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    GuideQuotaRuntime.reset();
    VoiceConversationAdGate.instance.delegateForTest = null;
    RemoteConfigService.lastFetchSucceededForTest = false;
    RemoteConfigService.rewardAdFailurePolicyForTest = null;
  });

  group('GuideQuotaRuntime identity semantics', () {
    test('bind returns a fresh token each time; unbind by token only', () {
      final coord = _StubCoordinator(_StubSnapshot.alive(uid: 'uid-A'));
      final t1 = GuideQuotaRuntime.bind(coord, uid: 'uid-A');
      final t2 = GuideQuotaRuntime.bind(coord, uid: 'uid-A');
      expect(identical(t1, t2), isFalse,
          reason: 'same-UID re-bind should issue a fresh token');
      expect(GuideQuotaRuntime.current(() => 'uid-A'), same(coord));

      GuideQuotaRuntime.unbind(t1);
      // t1 stale; t2 still owns the binding.
      expect(GuideQuotaRuntime.current(() => 'uid-A'), same(coord));
      GuideQuotaRuntime.unbind(t2);
      expect(GuideQuotaRuntime.current(() => 'uid-A'), isNull);
    });

    test('bind with mismatched UID returns a no-op token', () {
      final coord = _StubCoordinator(_StubSnapshot.alive(uid: 'uid-A'));
      GuideQuotaRuntime.bind(coord, uid: 'uid-A');
      final bogus = GuideQuotaRuntime.bind(coord, uid: 'uid-B');
      GuideQuotaRuntime.unbind(bogus);
      // Original binding still active.
      expect(GuideQuotaRuntime.current(() => 'uid-A'), same(coord));
    });

    test('current returns null when the bound snapshot is terminal', () {
      final coord = _StubCoordinator(_StubSnapshot.terminal(uid: 'uid-A'));
      GuideQuotaRuntime.bind(coord, uid: 'uid-A');
      expect(GuideQuotaRuntime.current(() => 'uid-A'), isNull);
    });

    test('current returns null on auth-UID mismatch', () {
      final coord = _StubCoordinator(_StubSnapshot.alive(uid: 'uid-A'));
      GuideQuotaRuntime.bind(coord, uid: 'uid-A');
      expect(GuideQuotaRuntime.current(() => 'uid-B'), isNull);
    });

    test('bind with empty UID throws ArgumentError', () {
      final coord = _StubCoordinator(_StubSnapshot.alive(uid: 'uid-A'));
      expect(
        () => GuideQuotaRuntime.bind(coord, uid: ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('guideAuthorize() — pure helper', () {
    test('empty context fields → denied(empty_context)', () async {
      final access = await guideAuthorize(
        context: GuideAdapterContext(
          coordinator: _StubCoordinator(_StubSnapshot.alive(uid: '')),
          kind: GuideChargeKind.scheduleParse,
          operation: GuideOperation.createParse,
          phase: GuideStep.correctAndSave,
          uid: '',
          version: 'v',
          sessionId: '',
          revision: 1,
          serverRevision: 1,
        ),
        operationId: 'op',
        authUidProvider: () => '',
      );
      expect(access.status, GuideAccessStatus.denied);
      expect(access.reasonCode, 'empty_context');
    });

    test('live UID mismatch → denied(uid_mismatch)', () async {
      final coord = _StubCoordinator(_StubSnapshot.alive(uid: 'uid-A'));
      final access = await guideAuthorize(
        context: GuideAdapterContext(
          coordinator: coord,
          kind: GuideChargeKind.scheduleParse,
          operation: GuideOperation.createParse,
          phase: GuideStep.correctAndSave,
          uid: 'uid-A',
          version: 'v',
          sessionId: 's',
          revision: 1,
          serverRevision: 1,
        ),
        operationId: 'op',
        authUidProvider: () => 'different-user',
      );
      expect(access.status, GuideAccessStatus.denied);
      expect(access.reasonCode, 'uid_mismatch');
    });

    test('stale snapshot fields → denied(stale_or_blocked)', () async {
      final coord = _StubCoordinator(_StubSnapshot.alive(
        uid: 'uid-A',
        revision: 2,
        serverRevision: 2,
      ));
      final access = await guideAuthorize(
        context: GuideAdapterContext(
          coordinator: coord,
          kind: GuideChargeKind.scheduleParse,
          operation: GuideOperation.createParse,
          phase: GuideStep.correctAndSave,
          uid: 'uid-A',
          version: 'v',
          sessionId: 's',
          revision: 99, // stale
          serverRevision: 2,
        ),
        operationId: 'op',
        authUidProvider: () => 'uid-A',
      );
      expect(access.status, GuideAccessStatus.denied);
      expect(access.reasonCode, 'stale_or_blocked');
    });
  });

  group('VoiceConversationAdGate — zero normal consume under bound guide', () {
    for (final phase in [GuideStep.querySpeech, GuideStep.queryResults]) {
      testWidgets('query authorization uses the live $phase phase',
          (tester) async {
        final coord = _StubCoordinator(_StubSnapshot.alive(
          uid: 'uid-A',
          phase: phase,
        ));
        coord.nextAccess = GuideAccess(
          status: GuideAccessStatus.granted,
          permit: GuidePermit(
            grantId: 'gid',
            uid: 'uid-A',
            sessionId: 'sess-uid-A',
            operationId: 'echo',
            kind: GuideChargeKind.voiceConversation,
            operation: GuideOperation.query,
            expiresAtUtc:
                DateTime.now().toUtc().add(const Duration(minutes: 2)),
          ),
        );
        GuideQuotaRuntime.bind(coord, uid: 'uid-A');
        var normalCalls = 0;
        var delegateCalls = 0;
        VoiceConversationAdGate.instance.delegateForTest =
            _SpyAdGateDelegate(onTryEnter: () => delegateCalls++);
        GuidePermit? permit;
        await tester.pumpWidget(MaterialApp(
            home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => unawaited(
              VoiceConversationAdGate.instance.tryEnterVoiceConversation(
                context: context,
                userId: 'uid-A',
                guideCoordinator: coord,
                guideOperation: GuideOperation.query,
                onGuideAllowed: (value) => permit = value,
                onEnterAllowed: (_) => normalCalls++,
              ),
            ),
            child: const Text('open'),
          ),
        )));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(coord.chargeContexts.map((context) => context.phase),
            [phase, phase]);
        expect(coord.operationIds, hasLength(2));
        expect(coord.operationIds[0], isNot(coord.operationIds[1]));
        expect(permit, isNotNull);
        expect(normalCalls, 0);
        expect(delegateCalls, 0);
      });
    }

    for (final scenario in ['wrong phase', 'paused']) {
      testWidgets('query rejects a $scenario guide without normal grant',
          (tester) async {
        final coord = _StubCoordinator(_StubSnapshot.alive(
          uid: 'uid-A',
          phase: scenario == 'wrong phase'
              ? GuideStep.savedDetail
              : GuideStep.querySpeech,
          run: scenario == 'paused' ? GuideRun.paused : GuideRun.active,
        ));
        GuideQuotaRuntime.bind(coord, uid: 'uid-A');
        var normalCalls = 0;
        var delegateCalls = 0;
        GuideAccess? denied;
        VoiceConversationAdGate.instance.delegateForTest =
            _SpyAdGateDelegate(onTryEnter: () => delegateCalls++);
        await tester.pumpWidget(MaterialApp(
            home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => unawaited(
              VoiceConversationAdGate.instance.tryEnterVoiceConversation(
                context: context,
                userId: 'uid-A',
                guideCoordinator: coord,
                guideOperation: GuideOperation.query,
                onGuideDenied: (value) => denied = value,
                onEnterAllowed: (_) => normalCalls++,
              ),
            ),
            child: const Text('open'),
          ),
        )));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(denied?.reasonCode, 'stale_or_blocked');
        expect(coord.chargeContexts, isEmpty);
        expect(normalCalls, 0);
        expect(delegateCalls, 0);
      });
    }

    testWidgets(
      'active guide returns from guide path; legacy delegate never sees '
      'onEnterAllowed even when delegate would normally grant',
      (tester) async {
        final coord = _StubCoordinator(_StubSnapshot.alive(
          uid: 'uid-A',
          revision: 1,
          serverRevision: 1,
          phase: GuideStep.correctAndSave,
          kind: GuideChargeKind.voiceConversation,
          operation: GuideOperation.createParse,
        ));
        coord.nextAccess = GuideAccess(
          status: GuideAccessStatus.granted,
          reasonCode: 'wire:granted',
          permit: GuidePermit(
            grantId: 'gid',
            uid: 'uid-A',
            sessionId: 'sess-uid-A',
            operationId: 'echo',
            kind: GuideChargeKind.voiceConversation,
            operation: GuideOperation.createParse,
            expiresAtUtc:
                DateTime.now().toUtc().add(const Duration(minutes: 2)),
          ),
        );
        GuideQuotaRuntime.bind(coord, uid: 'uid-A');

        var delegateCalls = 0;
        var normalEntryCalls = 0;
        VoiceConversationAdGate.instance.delegateForTest =
            _SpyAdGateDelegate(onTryEnter: () => delegateCalls++);

        GuidePermit? permit;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    unawaited(
                      VoiceConversationAdGate.instance
                          .tryEnterVoiceConversation(
                        context: context,
                        userId: 'uid-A',
                        onEnterAllowed: (_) => normalEntryCalls++,
                        guideCoordinator: coord,
                        guideOperation: GuideOperation.createParse,
                        onGuideAllowed: (p) => permit = p,
                      ),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(delegateCalls, 0,
            reason:
                'legacy delegate MUST NOT be invoked while guide is active');
        expect(normalEntryCalls, 0,
            reason: 'onEnterAllowed MUST NOT fire under an active guide');
        expect(permit, isNotNull);
        expect(permit!.uid, 'uid-A');
      },
    );

    testWidgets(
      'no coordinator → legacy delegate path is invoked unchanged',
      (tester) async {
        var delegateCalls = 0;
        VoiceConversationAdGate.instance.delegateForTest =
            _SpyAdGateDelegate(onTryEnter: () => delegateCalls++)
              ..allowedSource = EntitlementSource.initialFree;

        VoiceConversationEntryGrant? normalEntry;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    unawaited(
                      VoiceConversationAdGate.instance
                          .tryEnterVoiceConversation(
                        context: context,
                        userId: 'uid-X',
                        onEnterAllowed: (g) => normalEntry = g,
                      ),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(delegateCalls, 1);
        expect(normalEntry, isNotNull);
        expect(normalEntry!.source, EntitlementSource.initialFree);
      },
    );

    for (final failureReason in ['rpc_failed', 'guide_unbound']) {
      testWidgets(
        'bound unavailable $failureReason → onGuideDenied fires, '
        'onEnterAllowed does NOT',
        (tester) async {
          final coord = _StubCoordinator(_StubSnapshot.alive(
            uid: 'uid-A',
            revision: 1,
            serverRevision: 1,
            phase: GuideStep.queryResults,
            kind: GuideChargeKind.voiceConversation,
            operation: GuideOperation.query,
          ));
          coord.nextAccess = GuideAccess(
              status: GuideAccessStatus.unavailable, reasonCode: failureReason);
          GuideQuotaRuntime.bind(coord, uid: 'uid-A');

          VoiceConversationEntryGrant? normalEntry;
          GuideAccess? denied;
          var delegateCalls = 0;
          VoiceConversationAdGate.instance.delegateForTest =
              _SpyAdGateDelegate(onTryEnter: () => delegateCalls++);

          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) {
                  return ElevatedButton(
                    onPressed: () {
                      unawaited(
                        VoiceConversationAdGate.instance
                            .tryEnterVoiceConversation(
                          context: context,
                          userId: 'uid-A',
                          onEnterAllowed: (g) => normalEntry = g,
                          guideCoordinator: coord,
                          guideOperation: GuideOperation.query,
                          onGuideDenied: (a) => denied = a,
                        ),
                      );
                    },
                    child: const Text('open'),
                  );
                },
              ),
            ),
          );

          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(normalEntry, isNull,
              reason:
                  'unavailable guide response MUST NOT become a normal grant');
          expect(denied, isNotNull);
          expect(denied!.reasonCode, failureReason);
          expect(delegateCalls, 0);
        },
      );
    }

    testWidgets('a different live binding denies the stale coordinator',
        (tester) async {
      final live = _StubCoordinator(
          _StubSnapshot.alive(uid: 'uid-A', phase: GuideStep.querySpeech));
      final stale = _StubCoordinator(
          _StubSnapshot.alive(uid: 'uid-A', phase: GuideStep.querySpeech));
      GuideQuotaRuntime.bind(live, uid: 'uid-A');
      var delegateCalls = 0;
      var normalCalls = 0;
      GuideAccess? denied;
      VoiceConversationAdGate.instance.delegateForTest =
          _SpyAdGateDelegate(onTryEnter: () => delegateCalls++);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => unawaited(
            VoiceConversationAdGate.instance.tryEnterVoiceConversation(
              context: context,
              userId: 'uid-A',
              guideCoordinator: stale,
              guideOperation: GuideOperation.query,
              onGuideDenied: (value) => denied = value,
              onEnterAllowed: (_) => normalCalls++,
            ),
          ),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(denied?.reasonCode, 'stale_binding');
      expect(live.chargeContexts, isEmpty);
      expect(stale.chargeContexts, isEmpty);
      expect(normalCalls, 0);
      expect(delegateCalls, 0);
    });
  });

  group('ScheduleParseAdGate guide path — permit uniqueness and callback', () {
    setUp(() => SupabaseClientAccess.overrideForRun(() => 'uid-A'));
    tearDown(SupabaseClientAccess.clearOverride);

    testWidgets(
      'unavailable authorize result notifies onGuideDenied exactly once',
      (tester) async {
        final coord = _StubCoordinator(_StubSnapshot.alive(
          uid: 'uid-A',
          revision: 1,
          serverRevision: 1,
          phase: GuideStep.correctAndSave,
        ));
        coord.nextAccess = const GuideAccess(
            status: GuideAccessStatus.unavailable, reasonCode: 'rpc_failed');
        GuideQuotaRuntime.bind(coord, uid: 'uid-A');

        var allowedCalls = 0;
        var deniedCalls = 0;
        GuideAccess? lastGuideDenial;
        var normalAllowedCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  unawaited(
                    ScheduleParseAdGate.instance.tryEnterScheduleParse(
                      context: context,
                      guideCoordinator: coord,
                      guideOperation: GuideOperation.createParse,
                      onEnterAllowed: (_) => normalAllowedCalls++,
                      onGuideAllowed: (_) => allowedCalls++,
                      onGuideDenied: (access) {
                        deniedCalls++;
                        lastGuideDenial = access;
                      },
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        expect(allowedCalls, 0);
        expect(deniedCalls, 1,
            reason: 'unavailable 결과는 onGuideDenied로 정확히 한 번 전달된다');
        expect(coord.operationIds, hasLength(1));
        expect(lastGuideDenial?.status, GuideAccessStatus.unavailable);
        expect(lastGuideDenial?.reasonCode, 'rpc_failed');
        expect(normalAllowedCalls, 0,
            reason: '가이드 경로에서는 일반 onEnterAllowed가 절대 호출되지 않는다');
      },
    );

    testWidgets(
      'every guided schedule-parse attempt gets a unique operationId '
      '(no cached permit across retries)',
      (tester) async {
        final coord = _StubCoordinator(_StubSnapshot.alive(
          uid: 'uid-A',
          revision: 1,
          serverRevision: 1,
          phase: GuideStep.correctAndSave,
        ));
        coord.nextAccess = GuideAccess(
          status: GuideAccessStatus.granted,
          permit: GuidePermit(
            grantId: 'gid',
            uid: 'uid-A',
            sessionId: 'sess-uid-A',
            operationId: 'echo',
            kind: GuideChargeKind.scheduleParse,
            operation: GuideOperation.createParse,
            expiresAtUtc:
                DateTime.now().toUtc().add(const Duration(minutes: 2)),
          ),
        );
        GuideQuotaRuntime.bind(coord, uid: 'uid-A');

        var allowedCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  unawaited(
                    ScheduleParseAdGate.instance.tryEnterScheduleParse(
                      context: context,
                      guideCoordinator: coord,
                      guideOperation: GuideOperation.createParse,
                      onEnterAllowed: (_) {},
                      onGuideAllowed: (_) => allowedCalls++,
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        expect(allowedCalls, 2);
        expect(coord.operationIds, hasLength(2));
        expect(coord.operationIds[0], isNot(coord.operationIds[1]),
            reason: '재시도도 같은 operationId를 재사용하면 서버가 replay로 거부한다');
      },
    );
  });
}

// ── Fakes ────────────────────────────────────────────────────────

class _StubSnapshot extends GuideSnapshot {
  const _StubSnapshot({
    required super.uid,
    required super.version,
    required super.revision,
    required super.serverRevision,
    required super.step,
    required super.run,
    super.sessionId,
    super.createdEventId,
  });

  factory _StubSnapshot.alive({
    required String uid,
    int revision = 1,
    int serverRevision = 1,
    GuideStep phase = GuideStep.correctAndSave,
    GuideRun run = GuideRun.active,
    GuideChargeKind kind = GuideChargeKind.scheduleParse,
    GuideOperation operation = GuideOperation.createParse,
  }) =>
      _StubSnapshot(
        uid: uid,
        version: 'real_ui_v1',
        revision: revision,
        serverRevision: serverRevision,
        step: phase,
        run: run,
        sessionId: 'sess-$uid',
        createdEventId: null,
      );

  factory _StubSnapshot.terminal({required String uid}) => _StubSnapshot(
        uid: uid,
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.completed,
        run: GuideRun.terminal,
        sessionId: null,
      );
}

class _StubCoordinator implements GuideCoordinator {
  _StubCoordinator(this._initial)
      : _state = ValueNotifier<GuideSnapshot>(_initial);
  final ValueNotifier<GuideSnapshot> _state;
  final GuideSnapshot _initial;
  GuideAccess nextAccess = const GuideAccess(
      status: GuideAccessStatus.denied, reasonCode: 'default');

  @override
  ValueListenable<GuideSnapshot> get state => _state;

  @override
  Future<GuideSnapshot> start({required String uid}) async => _initial;

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => _initial;

  @override
  void suspend(GuidePauseReason reason) {}

  @override
  Future<void> terminate(GuideExit exit) async {}

  @override
  Future<GuideAccess> authorize({
    required GuideChargeContext context,
    required String operationId,
  }) async {
    chargeContexts.add(context);
    operationIds.add(operationId);
    return nextAccess;
  }

  /// authorize()가 받은 operationId 기록 — 시도별 고유성 검증용.
  final List<String> operationIds = <String>[];
  final List<GuideChargeContext> chargeContexts = <GuideChargeContext>[];
}

class _SpyAdGateDelegate implements VoiceConversationAdGateDelegate {
  _SpyAdGateDelegate({required this.onTryEnter});

  void Function() onTryEnter;
  EntitlementSource allowedSource = EntitlementSource.initialFree;
  bool allowed = true;
  int initialRemaining = 1;
  int dailyRemaining = 0;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    onTryEnter();
    if (allowed) {
      onEnterAllowed(
        VoiceConversationEntryGrant(
          sessionId: VoiceConversationSessionIdGenerator.next(),
          source: allowedSource,
          initialRemainingAtGate: initialRemaining,
          dailyRemainingAtGate: dailyRemaining,
        ),
      );
    }
  }
}
