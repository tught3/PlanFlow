import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';

/// Unit tests for [SupabaseRealUiGuideGrantService] (Module E2 backend
/// adapter).
///
/// Tests use the `forTesting(...)` factory with a fake [GuideRpcInvoker]
/// and a fake auth-UID getter so they NEVER touch the live Supabase
/// client or network. Every response shape is exercised end-to-end:
/// granted / denied / expired / retryLater / unavailable, the four RPCs
/// (begin / advance / authorize / finish), the V3 calendar-offset
/// refinement for `bind_created` and `edit_preview`, server-revision
/// CAS, and UID-before/after race results.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('late denial from a timed-out begin leaves retry wire intact',
      (tester) async {
    final stalled = Completer<Object?>();
    var begins = 0;
    var authorizes = 0;
    final service = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => 'uid-A',
      rpc: (name, _) async {
        if (name == kRpcBegin) {
          begins++;
          if (begins == 1) return stalled.future;
          return _beginFixture();
        }
        expect(name, kRpcAuthorize);
        authorizes++;
        return <String, Object?>{'status': 'denied', 'reason_code': 'probe'};
      },
    );
    Future<GuideBeginResult> begin() => service.begin(
        uid: 'uid-A', version: 'real_ui_v1', requestId: 'resume-request');

    final first = begin();
    await tester.pump(guideBeginTimeout);
    expect(await first, isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'timeout'));
    final retried = await begin();
    expect((retried as GuideBeginGranted).state.sessionId, 'sess');
    stalled.complete(<String, Object?>{'status': 'denied'});
    await tester.pump();

    await service.authorize(
      context: const GuideChargeContext(
        uid: 'uid-A',
        version: 'real_ui_v1',
        sessionId: 'sess',
        kind: GuideChargeKind.scheduleParse,
        operation: GuideOperation.createParse,
        phase: GuideStep.createSpeech,
        revision: 1,
        serverRevision: 1,
      ),
      operationId: 'check-wire-cache',
    );
    expect(begins, 2);
    expect(authorizes, 1);
  });

  group('GuideRpcInvoker is the only seam (no Supabase.instance in tests)', () {
    test('forTesting uses the injected invoker and currentUid seam', () async {
      final calls = <(String, Map<String, Object?>)>[];
      String? currentUid = 'uid-A';
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, params) async {
          calls.add((name, params));
          return <String, Object?>{
            'status': 'granted',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 60))
                .toIso8601String(),
            'session_id': 'sess-1',
            'phase': 'create',
            'revision': 1,
          };
        },
        currentUid: () => currentUid,
      );

      final result = await service.begin(
        uid: 'uid-A',
        version: 'real_ui_v1',
        requestId: 'req-1',
      );

      final state = (result as GuideBeginGranted).state;
      expect(state.sessionId, 'sess-1');
      expect(state.step, GuideStep.intro,
          reason: 'wire phase create must not acknowledge the local intro');
      expect(state.serverRevision, 1);
      expect(calls, hasLength(1));
      expect(calls.single.$1, kRpcBegin);
      expect(calls.single.$2['p_version'], 'real_ui_v1');
      expect(calls.single.$2['p_request_id'], 'req-1');
    });
  });

  test('late begin cannot replace a freshly restarted session', () async {
    final old = Completer<Object?>();
    final service = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => 'uid-A',
      rpc: (name, params) async {
        if (name == kRpcBegin) return old.future;
        expect(name, kRpcRestart);
        expect(params['p_previous_session_id'], 'sess');
        return {
          ..._beginFixture(),
          'session_id': 'replay',
          'revision': 0,
          'is_replay': true,
        };
      },
    );
    final late = service.begin(
        uid: 'uid-A', version: 'real_ui_v1', requestId: 'previous');
    final replay = await service.restart(
        uid: 'uid-A',
        version: 'real_ui_v1',
        previousSessionId: 'sess',
        requestId: 'restart:sess');
    old.complete(_beginFixture());
    expect(replay?.sessionId, 'replay');
    expect(replay?.isReplay, isTrue);
    expect(await late, isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'guide_session_changed'));
  });

  group('begin()', () {
    test('terminal checkpoint can restore Settings without a grant wire',
        () async {
      var rpcCalls = 0;
      final service = SupabaseRealUiGuideGrantService.forTesting(
        currentUid: () => 'uid-A',
        rpc: (name, _) async {
          rpcCalls++;
          expect(name, kRpcBegin);
          return {
            'status': 'denied',
            'reason_code': 'session_terminal',
            'session_id': 'sess',
            'phase': 'terminal',
            'revision': 8,
            'terminal_reason': 'completed',
            'is_replay': true,
          };
        },
      );
      final result = await service.begin(
          uid: 'uid-A', version: 'real_ui_v1', requestId: 'cold-start');
      expect(result, isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'terminal'));
      final state = (result as GuideBeginFailed).terminalPredecessor;
      expect(state?.step, GuideStep.completed);
      expect(state?.sessionId, 'sess');
      expect(state?.isReplay, isTrue);
      final access = await service.authorize(
        context: const GuideChargeContext(
          uid: 'uid-A',
          version: 'real_ui_v1',
          sessionId: 'sess',
          kind: GuideChargeKind.scheduleParse,
          operation: GuideOperation.createParse,
          phase: GuideStep.createSpeech,
          revision: 1,
          serverRevision: 8,
        ),
        operationId: 'check-terminal-wire',
      );
      expect(access.reasonCode, 'unknown_server_state');
      expect(rpcCalls, 1);
    });

    test('bound preview and updated begin replies decode an accepted UTC time',
        () async {
      for (final (phase, step) in [
        ('preview', GuideStep.editPreview),
        ('updated', GuideStep.updatedDetail),
      ]) {
        final service = SupabaseRealUiGuideGrantService.forTesting(
          rpc: (_, __) async => {
            ..._beginFixture(phase: phase),
            'event_id': 'bound',
            // banned-ok: Fixed offset-bearing reply fixture.
            'expected_start_at': '2026-11-16T17:00:00+09:00',
          },
          currentUid: () => 'uid-A',
        );
        final result =
            await service.begin(uid: 'uid-A', version: 'v', requestId: 'r');
        final state = (result as GuideBeginGranted).state;
        expect(state.step, step);
        expect(state.expectedStartAtReported, isTrue);
        // banned-ok: Fixed UTC equivalent of the reply fixture.
        expect(state.expectedStartAt, DateTime.utc(2026, 11, 16, 8));
      }
    });

    test('begin ignores unbound, wrong-phase, or invalid expected times', () {
      for (final (phase, id, timestamp, reported) in <(
        String,
        String?,
        String?,
        bool
      )>[
        // banned-ok: Fixed timestamps for positive-wire-field negative cases.
        ('preview', null, '2026-11-16T08:00:00Z', false),
        ('edit', 'bound', '2026-11-16T08:00:00Z', false),
        ('preview', 'bound', '2026-11-16T08:00:00', true),
        ('preview', 'bound', '2026-02-30T08:00:00Z', true),
        ('updated', 'bound', null, true),
      ]) {
        final state = GuideBackendJson.decodeBeginOrDeny({
          ..._beginFixture(phase: phase),
          'event_id': id,
          'expected_start_at': timestamp,
        });
        expect(state?.expectedStartAt, isNull);
        expect(state?.expectedStartAtReported, reported);
      }
      final legacy = GuideBackendJson.decodeBeginOrDeny({
        ..._beginFixture(phase: 'preview'),
        'event_id': 'bound',
      });
      expect(legacy?.expectedStartAtReported, isFalse);
    });

    test('returns malformed on empty uid / version / requestId without RPC',
        () async {
      var invocations = 0;
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async {
          invocations++;
          return null;
        },
        currentUid: () => 'uid-A',
      );

      expect(
        await service.begin(uid: '', version: 'v', requestId: 'r'),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'malformed'),
      );
      expect(
        await service.begin(uid: 'uid-A', version: '', requestId: 'r'),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'malformed'),
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: ''),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'malformed'),
      );
      expect(invocations, 0);
    });

    test('UID mismatch before await returns diagnostic without RPC', () async {
      var invocations = 0;
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async {
          invocations++;
          return <String, Object?>{'status': 'granted'};
        },
        currentUid: () => 'someone-else',
      );

      final state = await service.begin(
        uid: 'uid-A',
        version: 'real_ui_v1',
        requestId: 'req-1',
      );

      expect(state, isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'local_uid_mismatch'));
      expect(invocations, 0);
    });

    test('UID changes during RPC and the stale result is discarded', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async {
          await Future<void>.delayed(Duration.zero);
          return <String, Object?>{
            'status': 'granted',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 60))
                .toIso8601String(),
            'session_id': 'sess',
            'phase': 'create',
            'revision': 1,
          };
        },
        currentUid: () => _switchingUid,
      );
      // start as matching uid, then race-change before await resolves.
      _switchingUid = 'uid-A';
      final f = service.begin(uid: 'uid-A', version: 'v', requestId: 'r');
      _switchingUid = 'uid-B';
      final state = await f;
      expect(state, isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'local_uid_mismatch'));
    });

    test('expired status has a typed reason', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => <String, Object?>{
          'status': 'expired',
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 60))
              .toIso8601String(),
          'session_id': 'sess',
          'phase': 'create',
          'revision': 0,
        },
        currentUid: () => 'uid-A',
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: 'r'),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'expired'),
      );
    });

    test('unknown phase spelling denies', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => <String, Object?>{
          'status': 'granted',
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 60))
              .toIso8601String(),
          'session_id': 'sess',
          'phase': 'galaxy',
          'revision': 1,
        },
        currentUid: () => 'uid-A',
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: 'r'),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'malformed'),
      );
    });

    test('unknown RPC error becomes backend_unavailable', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => throw StateError('boom'),
        currentUid: () => 'uid-A',
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: 'r'),
        isA<GuideBeginFailed>().having((result) => result.failure.code, 'code', 'backend_unavailable'),
      );
    });
  });

  group('advance() — V3 offset refinement + server CAS', () {
    test('bind_created sends calendar_utc_offset_minutes from event.startAt',
        () async {
      final calls = <(String, Map<String, Object?>)>[];
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, params) async {
          calls.add((name, params));
          return <String, Object?>{
            'status': 'ok',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 60))
                .toIso8601String(),
            'session_id': 'sess',
            'phase': 'saved',
            'revision': 2,
          };
        },
        currentUid: () => 'uid-A',
      );

      final snapshot = _boundSnapshot(
        revision: 1,
        serverRevision: 1,
        sessionId: 'sess',
      );
      // Build a local event with a known offset (KST is +09:00 i.e. +540).
      // banned-ok: Pinned date for a timezone serialization assertion.
      final startLocal = DateTime(2026, 1, 15, 8, 0); // local 08:00
      final event = _stubEvent('uid-A', startLocal);

      await service.advance(
        snapshot: snapshot,
        action: GuideBackendAction.bindCreated,
        requestId: 'req-adv-1',
        event: event,
      );

      expect(calls.single.$2['p_action'], 'bind_created');
      expect(calls.single.$2['p_event_id'], event.id);
      final payload = calls.single.$2['p_payload']! as Map;
      expect(payload['calendar_utc_offset_minutes'],
          startLocal.timeZoneOffset.inMinutes);
    });

    test('edit_preview sends UTC ISO expected_start_at + offset', () async {
      final calls = <(String, Map<String, Object?>)>[];
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, params) async {
          calls.add((name, params));
          return <String, Object?>{
            'status': 'ok',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 60))
                .toIso8601String(),
            'session_id': 'sess',
            'phase': 'updated',
            'revision': 3,
          };
        },
        currentUid: () => 'uid-A',
      );

      final snapshot =
          _boundSnapshot(revision: 2, serverRevision: 2, sessionId: 'sess');
      // banned-ok: Pinned date for a timezone serialization assertion.
      final expectedLocal = DateTime(2026, 1, 15, 15, 0); // local 15:00
      final expectedUtc = expectedLocal.toUtc();

      await service.advance(
        snapshot: snapshot,
        action: GuideBackendAction.editPreview,
        requestId: 'req-edit-1',
        expectedStartLocal: expectedLocal,
      );

      final payload = calls.single.$2['p_payload']! as Map;
      expect(payload['expected_start_at'], expectedUtc.toIso8601String());
      expect(payload['calendar_utc_offset_minutes'],
          expectedLocal.timeZoneOffset.inMinutes);
    });

    test('serverRevision CAS uses serverRevision, never local revision',
        () async {
      final captured = <Map<String, Object?>>[];
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, params) async {
          captured.add(params);
          return <String, Object?>{
            'status': 'ok',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 60))
                .toIso8601String(),
            'session_id': 'sess',
            'phase': 'updated',
            'revision': 12,
          };
        },
        currentUid: () => 'uid-A',
      );

      final snapshot = GuideSnapshot(
        uid: 'uid-A',
        version: 'real_ui_v1',
        revision: 5, // local counter — must NOT be sent.
        serverRevision: 12,
        step: GuideStep.editPreview,
        run: GuideRun.active,
        sessionId: 'sess',
      );
      await service.advance(
        snapshot: snapshot,
        action: GuideBackendAction.updateVerified,
        requestId: 'req-upd-1',
        event: _stubEvent('uid-A', DateTime.utc(2026, 1, 15, 6, 0)),
      );

      expect(captured.single['p_expected_revision'], 12);
      expect(captured.single['p_expected_revision'], isNot(5));
    });

    test('decodeAdvanceOrDeny — malformed status throws', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => <String, Object?>{'status': 'huh'},
        currentUid: () => 'uid-A',
      );
      expect(
        () => service.advance(
          snapshot:
              _boundSnapshot(revision: 1, serverRevision: 1, sessionId: 'sess'),
          action: GuideBackendAction.detailAck,
          requestId: 'req',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('decodeAdvanceOrDeny — serverRevision regression is rejected',
        () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => <String, Object?>{
          'status': 'ok',
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 60))
              .toIso8601String(),
          'session_id': 'sess',
          'phase': 'saved',
          'revision': 0,
        },
        currentUid: () => 'uid-A',
      );
      expect(
        () => service.advance(
          snapshot:
              _boundSnapshot(revision: 1, serverRevision: 5, sessionId: 'sess'),
          action: GuideBackendAction.detailAck,
          requestId: 'req',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('authorize() — wire status mapping', () {
    Future<GuideAccess> runAuth(
        String status, Map<String, Object?> extra, Duration leaseOffset) async {
      final nowUtc = DateTime.now().toUtc().add(leaseOffset);
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, _) async => name == kRpcBegin
            ? _beginFixture()
            : <String, Object?>{
                'status': status,
                'grant_id': 'gid',
                'expires_at': nowUtc.toIso8601String(),
                ...extra,
              },
        currentUid: () => 'uid-A',
      );
      await service.begin(
          uid: 'uid-A', version: 'real_ui_v1', requestId: 'seed');
      return service.authorize(
        context: GuideChargeContext(
          uid: 'uid-A',
          version: 'real_ui_v1',
          sessionId: 'sess',
          kind: GuideChargeKind.scheduleParse,
          operation: GuideOperation.createParse,
          phase: GuideStep.createSpeech,
          revision: 1,
          serverRevision: 1,
        ),
        operationId: 'op-1',
      );
    }

    test('granted → returns a permit with the same kind/operation', () async {
      final access = await runAuth('granted', {}, const Duration(minutes: 1));
      expect(access.status, GuideAccessStatus.granted);
      expect(access.permit, isNotNull);
      expect(access.permit!.kind, GuideChargeKind.scheduleParse);
      expect(access.permit!.operation, GuideOperation.createParse);
      expect(access.permit!.uid, 'uid-A');
      expect(access.permit!.sessionId, 'sess');
      expect(access.permit!.operationId, 'op-1');
    });

    test('expired server status → expired status (no permit)', () async {
      final access = await runAuth('expired',
          {'reason_code': 'session_expired'}, const Duration(minutes: -10));
      expect(access.status, GuideAccessStatus.expired);
      expect(access.permit, isNull);
    });

    test('denied → denied (no permit)', () async {
      final access = await runAuth('denied', {'reason_code': 'wrong_phase'},
          const Duration(minutes: -10));
      expect(access.status, GuideAccessStatus.denied);
      expect(access.permit, isNull);
      expect(access.reasonCode, 'wrong_phase');
    });

    test('retryLater → retryLater', () async {
      final access = await runAuth('retryLater',
          {'reason_code': 'rate_limited'}, const Duration(minutes: -10));
      expect(access.status, GuideAccessStatus.retryLater);
    });

    test('unknown status → denied', () async {
      final access =
          await runAuth('whoknows', {}, const Duration(minutes: -10));
      expect(access.status, GuideAccessStatus.denied);
    });

    test('malformed payload (no grant_id or expires_at) → denied', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, _) async => name == kRpcBegin
            ? _beginFixture(phase: 'query')
            : <String, Object?>{'status': 'granted'},
        currentUid: () => 'uid-A',
      );
      await service.begin(
          uid: 'uid-A', version: 'real_ui_v1', requestId: 'seed');
      final access = await service.authorize(
        context: GuideChargeContext(
          uid: 'uid-A',
          version: 'real_ui_v1',
          sessionId: 'sess',
          kind: GuideChargeKind.voiceConversation,
          operation: GuideOperation.query,
          phase: GuideStep.querySpeech,
          revision: 1,
          serverRevision: 1,
        ),
        operationId: 'op-2',
      );
      expect(access.status, GuideAccessStatus.denied);
      expect(access.reasonCode, 'malformed_grant');
    });

    test('lease > 2x default → denied (lease out of bounds)', () async {
      final farFuture = DateTime.now().toUtc().add(const Duration(hours: 5));
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, _) async => name == kRpcBegin
            ? _beginFixture(phase: 'query')
            : <String, Object?>{
                'status': 'granted',
                'grant_id': 'gid',
                'expires_at': farFuture.toIso8601String(),
              },
        currentUid: () => 'uid-A',
      );
      await service.begin(
          uid: 'uid-A', version: 'real_ui_v1', requestId: 'seed');
      final access = await service.authorize(
        context: GuideChargeContext(
          uid: 'uid-A',
          version: 'real_ui_v1',
          sessionId: 'sess',
          kind: GuideChargeKind.voiceConversation,
          operation: GuideOperation.query,
          phase: GuideStep.querySpeech,
          revision: 1,
          serverRevision: 1,
        ),
        operationId: 'op-3',
      );
      expect(access.status, GuideAccessStatus.denied);
      expect(access.reasonCode, 'lease_out_of_bounds');
    });
  });

  group('finish()', () {
    test('non-empty session + matching UID invokes RPC', () async {
      var invoked = false;
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (name, params) async {
          invoked = true;
          expect(name, kRpcFinish);
          expect(params['p_session_id'], 'sess');
          expect(params['p_reason'], 'completed');
          return <String, Object?>{'status': 'ok', 'revision': 9};
        },
        currentUid: () => 'uid-A',
      );
      await service.finish(
        snapshot:
            _boundSnapshot(revision: 9, serverRevision: 9, sessionId: 'sess'),
        exit: GuideExit.completed,
        requestId: 'f-1',
      );
      expect(invoked, true);
    });

    test('stale UID → no-op', () async {
      var invoked = false;
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async {
          invoked = true;
          return null;
        },
        currentUid: () => 'someone-else',
      );
      await service.finish(
        snapshot:
            _boundSnapshot(revision: 9, serverRevision: 9, sessionId: 'sess'),
        exit: GuideExit.skip,
        requestId: 'f-1',
      );
      expect(invoked, false);
    });
  });

  group('Wire construction helpers (pure)', () {
    test('buildAuthorizeParams camelCases kind/operation and uses server rev',
        () {
      final params = buildAuthorizeParams(
        sessionId: 'sess',
        phase: GuideStep.querySpeech,
        revision: 9,
        kind: GuideChargeKind.voiceConversation,
        operation: GuideOperation.query,
        operationId: 'op',
      );
      expect(params['p_kind'], 'voiceConversation');
      expect(params['p_operation'], 'query');
      expect(params['p_phase'], 'query');
      expect(params['p_revision'], 9);
    });

    test('localCalendarOffsetMinutes reflects system timezone offset', () {
      // The wire V3 constraint is [-840, 840]; on a stock device that
      // is always satisfied, so we only verify the round-trip.
      // banned-ok: Pinned date for a timezone serialization assertion.
      final local = DateTime(2026, 1, 1, 12, 0);
      expect(localCalendarOffsetMinutes(local), local.timeZoneOffset.inMinutes);
    });
  });
}

String _switchingUid = 'uid-A';

GuideSnapshot _boundSnapshot({
  required int revision,
  required int serverRevision,
  required String sessionId,
}) {
  return GuideSnapshot(
    uid: 'uid-A',
    version: 'real_ui_v1',
    revision: revision,
    serverRevision: serverRevision,
    step: GuideStep.createSpeech,
    run: GuideRun.active,
    sessionId: sessionId,
  );
}

EventModel _stubEvent(String uid, DateTime startLocal) {
  return EventModel(
    id: 'evt-1',
    userId: uid,
    title: '제목',
    startAt: startLocal,
    endAt: startLocal.add(const Duration(hours: 1)),
    location: '장소',
    locationLat: 37.5,
    locationLng: 127.0,
    memo: null,
    supplies: const <String>[],
    suppliesChecked: const <String>[],
    participants: const <String>[],
    targets: const <String>[],
    isCritical: false,
    useStrongAlarm: false,
    recurrenceRule: null,
    isAllDay: false,
    isMultiDay: false,
    parentEventId: null,
    overriddenOccurrenceDate: null,
    deletedOccurrenceDates: const <DateTime>[],
    groupEventId: null,
    category: 'personal',
    source: 'manual',
    externalId: null,
    externalCalendarId: null,
    externalEtag: null,
    externalUpdatedAt: null,
    lastSyncedAt: null,
    createdAt: startLocal,
    updatedAt: startLocal,
  );
}

// Authorize requires validated server state, matching production's begin-first flow.
Map<String, Object?> _beginFixture({String phase = 'create'}) => {
      'status': 'granted',
      'session_id': 'sess',
      'phase': phase,
      'revision': 1,
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 60))
          .toIso8601String(),
      'event_id': null,
      'saved_local_date': null,
    };
