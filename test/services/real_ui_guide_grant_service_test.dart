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

      final state = await service.begin(
        uid: 'uid-A',
        version: 'real_ui_v1',
        requestId: 'req-1',
      );

      expect(state, isNotNull);
      expect(state!.sessionId, 'sess-1');
      expect(state.step, GuideStep.intro,
          reason: 'wire phase create must not acknowledge the local intro');
      expect(state.serverRevision, 1);
      expect(calls, hasLength(1));
      expect(calls.single.$1, kRpcBegin);
      expect(calls.single.$2['p_version'], 'real_ui_v1');
      expect(calls.single.$2['p_request_id'], 'req-1');
    });
  });

  group('begin()', () {
    test('returns null on empty uid / version / requestId without RPC',
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
        isNull,
      );
      expect(
        await service.begin(uid: 'uid-A', version: '', requestId: 'r'),
        isNull,
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: ''),
        isNull,
      );
      expect(invocations, 0);
    });

    test('UID mismatch before await → null, no RPC', () async {
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

      expect(state, isNull);
      expect(invocations, 0);
    });

    test('UID changes during RPC → null (stale UID race)', () async {
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
      expect(state, isNull);
    });

    test('expired status maps to null', () async {
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
        isNull,
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
        isNull,
      );
    });

    test('RPC throws → null', () async {
      final service = SupabaseRealUiGuideGrantService.forTesting(
        rpc: (_, __) async => throw StateError('boom'),
        currentUid: () => 'uid-A',
      );
      expect(
        await service.begin(uid: 'uid-A', version: 'v', requestId: 'r'),
        isNull,
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
