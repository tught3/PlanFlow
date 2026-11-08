import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/native_guide_budget_ledger.dart';
import '../../integration_test/support/real_ui_guide_native_environment.dart';

// Pure contract tests only: synthetic fixtures, not native QA or proof.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '11111111-1111-4111-8111-111111111111';
  const sid = 'synthetic-session';
  const opid = 'synthetic-operation';
  final expiry = DateTime.utc(2030).toIso8601String();
  Map<String, Object?> params() => {
        'p_session_id': sid,
        'p_phase': 'create',
        'p_revision': 4,
        'p_kind': 'scheduleParse',
        'p_operation': 'createParse',
        'p_operation_id': opid
      };
  Map<String, Object?> reply() =>
      {'status': 'granted', 'grant_id': 'grant-1', 'expires_at': expiry};
  NativeGuideGrantFence fence(DateTime now) =>
      NativeGuideGrantFence(expectedUid: uid, now: () => now);
  bool capture(NativeGuideGrantFence f,
          {String user = uid, Map<String, Object?>? r}) =>
      f.capture(
          params: params(),
          reply: r ?? reply(),
          actualUid: user,
          actualSessionId: sid,
          actualPhase: 'create',
          actualRevision: 4,
          actualKind: 'scheduleParse',
          actualOperation: 'createParse',
          actualOperationId: opid);
  bool spend(NativeGuideGrantFence f, {String user = uid, String id = sid}) =>
      f.permits(
          uid: user,
          sessionId: id,
          phase: 'create',
          revision: 4,
          kind: 'scheduleParse',
          operation: 'createParse',
          operationId: opid);
  test('matches captured grant once, then rejects replay', () {
    final f = fence(DateTime.utc(2029));
    expect(capture(f), isTrue);
    expect(spend(f), isTrue);
    expect(spend(f), isFalse);
  });
  test('denied, wrong uid, expired and mismatched session fail closed', () {
    final f = fence(DateTime.utc(2029));
    expect(capture(f, r: {...reply(), 'status': 'denied'}), isFalse);
    expect(capture(f, user: 'wrong'), isFalse);
    expect(capture(f), isTrue);
    expect(spend(f, id: 'other'), isFalse);
    final expired = fence(DateTime.utc(2031));
    expect(capture(expired), isFalse);
  });

  test('wire state rejects wrong uid/session/phase/revision/operation', () {
    final w =
        NativeGuideWirePermit(expectedUid: uid, now: () => DateTime.utc(2029));
    final state = <String, Object?>{
      'status': 'granted',
      'session_id': sid,
      'phase': 'create',
      'revision': 4,
      'expires_at': expiry
    };
    expect(w.observe('begin_real_ui_guide', {}, state, 'wrong', 'create'),
        isFalse);
    expect(w.observe('begin_real_ui_guide', {}, state, uid, 'create'), isTrue);
    for (final bad in <String, Object?>{
      'p_session_id': 'other',
      'p_phase': 'query',
      'p_revision': 5,
      'p_kind': 'voiceConversation',
      'p_operation': 'query'
    }.entries) {
      expect(w.matchesParams({...params(), bad.key: bad.value}, 'create'),
          isFalse);
    }
    expect(w.consume(uid, 'create'), isFalse);
    expect(
        w.observe('authorize_real_ui_guide_operation', params(), reply(), uid,
            'create'),
        isTrue);
    expect(w.consume(uid, 'query'), isFalse);
    expect(w.consume(uid, 'create'), isTrue);
    expect(w.consume(uid, 'create'), isTrue);
    expect(w.reservations, 2);
    // Replaying the same server grant through a second authorize RPC is denied.
    expect(
        w.observe('authorize_real_ui_guide_operation', params(), reply(), uid,
            'create'),
        isFalse);
    expect(w.consume(uid, 'create'), isFalse);
  });
  test('one authorized logical operation permits multiple AI requests', () {
    final w =
        NativeGuideWirePermit(expectedUid: uid, now: () => DateTime.utc(2029));
    expect(
        w.observe(
            'begin_real_ui_guide',
            {},
            {
              'status': 'granted',
              'session_id': sid,
              'phase': 'create',
              'revision': 4,
              'expires_at': expiry
            },
            uid,
            'create'),
        isTrue);
    expect(
        w.observe('authorize_real_ui_guide_operation', params(), reply(), uid,
            'create'),
        isTrue);

    // parseSchedule's primary completion and validateLocation revalidation
    // are both requests belonging to the same authorized operation.
    for (var request = 0; request < 3; request++) {
      expect(w.consume(uid, 'create'), isTrue);
    }
    expect(w.reservations, 3);
    expect(w.stages, {'create'});

    // The same grant identity cannot be recaptured as a new operation.
    expect(
        w.observe(
            'authorize_real_ui_guide_operation',
            {...params(), 'p_operation_id': 'new-operation'},
            {...reply(), 'grant_id': 'grant-2'},
            uid,
            'create'),
        isTrue);
    expect(w.consume(uid, 'create'), isTrue);
    expect(w.reservations, 4);
  });
  test('expiry after grant capture and stale revision reject spend', () {
    var clock = DateTime.utc(2029);
    final w = NativeGuideWirePermit(expectedUid: uid, now: () => clock);
    expect(
        w.observe(
            'begin_real_ui_guide',
            {},
            {
              'status': 'granted',
              'session_id': sid,
              'phase': 'create',
              'revision': 4,
              'expires_at': expiry
            },
            uid,
            'create'),
        isTrue);
    expect(
        w.observe('authorize_real_ui_guide_operation', params(), reply(), uid,
            'create'),
        isTrue);
    clock = DateTime.utc(2031);
    expect(w.consume(uid, 'create'), isFalse);
  });
  test('serialized pre-network persistence blocks overlap and survives errors',
      () async {
    final gate = NativeGuideSerialGate();
    final trace = <String>[];
    var count = 0;
    Future<void> attempt() => gate.run(() async {
          if (count >= 3) return;
          count++;
          trace.add('persist');
          await Future<void>.delayed(Duration.zero);
          trace.add('network');
        });
    await Future.wait(List.generate(10, (_) => attempt()));
    expect(count, 3);
    expect(trace,
        ['persist', 'network', 'persist', 'network', 'persist', 'network']);
    await expectLater(gate.run<void>(() async => throw StateError('uncertain')),
        throwsStateError);
    await gate.run(() async {
      trace.add('after');
    });
    expect(trace.last, 'after');
  });

  test('created ID must be returned, scoped and QA marked', () {
    const marker = '[QA:synthetic]';
    expect(NativeGuideEventIdentity.capture(null, uid, marker), isNull);
    expect(
        NativeGuideEventIdentity.capture(
            {'id': '', 'user_id': uid, 'title': marker}, uid, marker),
        isNull);
    expect(
        NativeGuideEventIdentity.capture(
            {'id': 'id', 'user_id': 'other', 'title': marker}, uid, marker),
        isNull);
    expect(
        NativeGuideEventIdentity.capture(
            {'id': 'id', 'user_id': uid, 'title': 'ordinary'}, uid, marker),
        isNull);
    expect(
        NativeGuideEventIdentity.capture(
            {'id': 'id', 'user_id': uid, 'title': marker}, uid, marker),
        'id');
  });

  test('each stage permits repeated requests only within its own operation',
      () {
    final w =
        NativeGuideWirePermit(expectedUid: uid, now: () => DateTime.utc(2029));
    expect(
        w.observe(
            'begin_real_ui_guide',
            {},
            {
              'status': 'granted',
              'session_id': sid,
              'phase': 'create',
              'revision': 0,
              'expires_at': expiry
            },
            uid,
            'create'),
        isTrue);
    var rev = 0;
    for (final stage in ['create', 'query', 'change']) {
      final x = NativeGuideWirePermit.expected(stage)!;
      if (stage != 'create') {
        expect(
            w.observe(
                'advance_real_ui_guide',
                {'p_session_id': sid, 'p_expected_revision': rev},
                {
                  'status': 'ok',
                  'session_id': sid,
                  'phase': x.$1,
                  'revision': rev + 1,
                  'expires_at': expiry
                },
                uid,
                stage),
            isTrue);
        rev++;
      }
      final p = <String, Object?>{
        'p_session_id': sid,
        'p_phase': x.$1,
        'p_revision': rev,
        'p_kind': x.$2,
        'p_operation': x.$3,
        'p_operation_id': stage
      };
      expect(
          w.observe(
              'authorize_real_ui_guide_operation',
              p,
              {'status': 'granted', 'grant_id': stage, 'expires_at': expiry},
              uid,
              stage),
          isTrue);
      expect(w.consume(uid, stage), isTrue);
      expect(w.consume(uid, stage), isTrue);
    }
    expect(w.reservations, 6);
    expect(w.consume(uid, 'create'), isFalse);
    expect(w.consume(uid, 'query'), isFalse);
    expect(w.consume(uid, 'change'), isTrue);
  });

// ---------------------------------------------------------------------------
// Below: contract tests for the durable budget ledger, request-scope allowlist
// helpers, and the optional-background exception. Pure, no HTTP/DB.
// ---------------------------------------------------------------------------

  const ledgerUuid = '11111111-2222-3333-4444-555555555555';
  const ledgerBudgetId = 'planflow-guide-FRM9-20261021';

  Map<String, Object?> validLedgerJson() => <String, Object?>{
        'version': 1,
        'budgetId': ledgerBudgetId,
        'uid': ledgerUuid,
        'maxAiRequests': 3,
        'aiRequests': 0,
        'usedPhases': <String>[],
        'createAttempted': false,
        'createdId': null,
      };

  group('parseBudgetLedger schema', () {
    test('valid input roundtrips', () {
      final snap = parseBudgetLedger(jsonEncode(validLedgerJson()));
      expect(snap.budgetId, ledgerBudgetId);
      expect(snap.uid, ledgerUuid);
      expect(snap.aiRequests, 0);
      expect(snap.usedPhases, isEmpty);
      expect(snap.createAttempted, isFalse);
      expect(snap.createdId, isNull);
    });

    test('non-object root fails closed', () {
      expect(() => parseBudgetLedger('123'), throwsFormatException);
      expect(() => parseBudgetLedger('null'), throwsFormatException);
    });

    test('non-json fails closed', () {
      expect(() => parseBudgetLedger('not json'), throwsFormatException);
    });

    test('extra key fails closed', () {
      final j = validLedgerJson()..['rogue'] = 'no';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('missing required key fails closed', () {
      final j = validLedgerJson()..remove('createdId');
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('bad version fails closed', () {
      final j = validLedgerJson()..['version'] = 2;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('budgetId outside regex fails closed', () {
      final j = validLedgerJson()
        ..['budgetId'] = 'planflow-guide-OTHER-20261021';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('historical example budgetId accepted', () {
      final j = validLedgerJson()
        ..['budgetId'] = 'planflow-guide-FRM9-20261021';
      expect(parseBudgetLedger(jsonEncode(j)).budgetId,
          'planflow-guide-FRM9-20261021');
    });

    test('uid outside UUID regex fails closed', () {
      final j = validLedgerJson()..['uid'] = 'not-a-uuid';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('non-positive maxAiRequests fails closed', () {
      final j = validLedgerJson()..['maxAiRequests'] = 0;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
      final ok = validLedgerJson()..['maxAiRequests'] = 4;
      expect(parseBudgetLedger(jsonEncode(ok)).maxAiRequests, 4);
    });

    test('aiRequests out of range fails closed', () {
      final j = validLedgerJson()..['aiRequests'] = -1;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
      final j2 = validLedgerJson()..['aiRequests'] = 4;
      expect(() => parseBudgetLedger(jsonEncode(j2)), throwsFormatException);
    });

    test('usedPhases disallows unknown entries', () {
      final j = validLedgerJson()
        ..['usedPhases'] = <String>['misc']
        ..['aiRequests'] = 1;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('usedPhases length must equal aiRequests', () {
      final j = validLedgerJson()
        ..['usedPhases'] = <String>['create', 'query']
        ..['aiRequests'] = 1;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('usedPhases duplicates fail closed', () {
      final j = validLedgerJson()
        ..['usedPhases'] = <String>['create', 'create']
        ..['aiRequests'] = 2;
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('createAttempted non-bool fails closed', () {
      final j = validLedgerJson()..['createAttempted'] = 'true';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('non-uuid createdId fails closed', () {
      final j = validLedgerJson()
        ..['createAttempted'] = true
        ..['createdId'] = 'definitely-not-a-uuid';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });

    test('full consumption snapshot accepted', () {
      final j = validLedgerJson()
        ..['aiRequests'] = 3
        ..['usedPhases'] = <String>['create', 'query', 'change']
        ..['createAttempted'] = true
        ..['createdId'] = ledgerUuid;
      final snap = parseBudgetLedger(jsonEncode(j));
      expect(snap.aiRequests, 3);
      expect(snap.usedPhases, hasLength(3));
      expect(snap.createAttempted, isTrue);
      expect(snap.createdId, ledgerUuid);
    });

    test('createAttempted+null id is the documented fail-closed signal', () {
      final j = validLedgerJson()..['createAttempted'] = true;
      final snap = parseBudgetLedger(jsonEncode(j));
      expect(snap.createAttempted, isTrue);
      expect(snap.createdId, isNull);
      expect(reasonForReserveEventCreate(snap), isNotNull);
    });
  });

  group('loadBudgetLedger and atomic write round-trip', () {
    late Directory tmp;
    late File file;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('budget-ledger-test');
      file = File('${tmp.path}/native-guide-budget-$ledgerBudgetId.json');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('missing file fails closed', () {
      expect(
          () => loadBudgetLedger(
                file: file,
                expectedBudgetId: ledgerBudgetId,
                expectedUid: ledgerUuid,
              ),
          throwsFormatException);
    });

    test('mismatched expectedBudgetId fails closed', () async {
      await file.writeAsString(jsonEncode(validLedgerJson()));
      expect(
          () => loadBudgetLedger(
                file: file,
                expectedBudgetId: 'planflow-guide-FRM9-20999999',
                expectedUid: ledgerUuid,
              ),
          throwsFormatException);
    });

    test('mismatched expectedUid fails closed', () async {
      await file.writeAsString(jsonEncode(validLedgerJson()));
      expect(
          () => loadBudgetLedger(
                file: file,
                expectedBudgetId: ledgerBudgetId,
                expectedUid: '99999999-aaaa-bbbb-cccc-dddddddddddd',
              ),
          throwsFormatException);
    });

    test('round-trip write then load matches', () async {
      final snap0 = parseBudgetLedger(jsonEncode(validLedgerJson()));
      await writeBudgetLedgerAtomic(file: file, snapshot: snap0);
      final snap1 = await loadBudgetLedger(
        file: file,
        expectedBudgetId: ledgerBudgetId,
        expectedUid: ledgerUuid,
      );
      expect(snap1.budgetId, snap0.budgetId);
      expect(snap1.uid, snap0.uid);
      expect(snap1.aiRequests, snap0.aiRequests);
      expect(snap1.usedPhases, snap0.usedPhases);
      expect(snap1.createAttempted, snap0.createAttempted);
      expect(snap1.createdId, snap0.createdId);
    });

    test('oversize file (>8KB) fails closed', () async {
      await file.writeAsString('x' * 9000);
      expect(
          () => loadBudgetLedger(
                file: file,
                expectedBudgetId: ledgerBudgetId,
                expectedUid: ledgerUuid,
              ),
          throwsFormatException);
    });
  });

  group('durable repeat-phase reservation', () {
    test('two sequential same-phase reservations reload with count two',
        () async {
      final tmp = await Directory.systemTemp.createTemp('budget-ledger-repeat');
      try {
        final file =
            File('${tmp.path}/native-guide-budget-$ledgerBudgetId.json');
        await writeBudgetLedgerAtomic(
            file: file,
            snapshot: BudgetLedgerSnapshot.initial(
                    budgetId: ledgerBudgetId, uid: ledgerUuid)
                .copyWith(maxAiRequests: 3));
        for (var i = 0; i < 2; i++) {
          final loaded = await loadBudgetLedger(
              file: file,
              expectedBudgetId: ledgerBudgetId,
              expectedUid: ledgerUuid);
          await writeBudgetLedgerAtomic(
              file: file,
              snapshot: nextAiReservationSnapshot(loaded, 'create'));
        }
        final reloaded = await loadBudgetLedger(
            file: file,
            expectedBudgetId: ledgerBudgetId,
            expectedUid: ledgerUuid);
        expect(reloaded.aiRequests, 2);
        expect(reloaded.usedPhases, <String>['create']);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('durable restart cap (cross-run identity)', () {
    late Directory tmp;
    late File file;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('budget-ledger-cap');
      file = File('${tmp.path}/native-guide-budget-$ledgerBudgetId.json');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('cap is honored across a simulated restart', () async {
      var snap = BudgetLedgerSnapshot.initial(
        budgetId: ledgerBudgetId,
        uid: ledgerUuid,
      ).copyWith(maxAiRequests: 3);
      await writeBudgetLedgerAtomic(file: file, snapshot: snap);

      for (final phase in const ['create', 'query']) {
        snap = await loadBudgetLedger(
          file: file,
          expectedBudgetId: ledgerBudgetId,
          expectedUid: ledgerUuid,
        );
        expect(reasonForReserveAi(snap, phase), isNull,
            reason: 'fresh load should accept $phase');
        final next = snap.copyWith(
          aiRequests: snap.aiRequests + 1,
          usedPhases: <String>[...snap.usedPhases, phase],
        );
        await writeBudgetLedgerAtomic(file: file, snapshot: next);
      }

      snap = await loadBudgetLedger(
        file: file,
        expectedBudgetId: ledgerBudgetId,
        expectedUid: ledgerUuid,
      );
      expect(snap.aiRequests, 2);
      expect(snap.usedPhases, <String>['create', 'query']);
      expect(reasonForReserveAi(snap, 'change'), isNull);

      // Final consume inside the same simulated "process":
      final finalSnap = snap.copyWith(
        aiRequests: 3,
        usedPhases: <String>['create', 'query', 'change'],
      );
      await writeBudgetLedgerAtomic(file: file, snapshot: finalSnap);

      // Cold reload: 상한이 사실상 무제한이라 재시작 후에도 계속 허용된다.
      final fresh = await loadBudgetLedger(
        file: file,
        expectedBudgetId: ledgerBudgetId,
        expectedUid: ledgerUuid,
      );
      for (final p in const ['create', 'query', 'change']) {
        expect(reasonForReserveAi(fresh, p), isNotNull,
            reason: 'cap should reject any further $p');
      }
    });

    test('persistent createAttempted=true with unknown id forbids retry',
        () async {
      final persisted = parseBudgetLedger(jsonEncode(validLedgerJson()))
          .copyWith(createAttempted: true);
      await writeBudgetLedgerAtomic(file: file, snapshot: persisted);
      final reloaded = await loadBudgetLedger(
        file: file,
        expectedBudgetId: ledgerBudgetId,
        expectedUid: ledgerUuid,
      );
      expect(reloaded.createAttempted, isTrue);
      expect(reloaded.createdId, isNull);
      expect(reasonForReserveEventCreate(reloaded),
          'ledger createAttempted=true with unknown id; retry forbidden');
    });

    test('createAttempted=false permits reservation', () async {
      final snap = parseBudgetLedger(jsonEncode(validLedgerJson()));
      expect(reasonForReserveEventCreate(snap), isNull);
    });
  });

  group('reasonForReserveAi', () {
    test('rejects unknown phase', () {
      final snap = parseBudgetLedger(jsonEncode(validLedgerJson()));
      expect(reasonForReserveAi(snap, 'other'), isNotNull);
    });

    test('allows one repeat within the same phase until the cap', () {
      // The real app validates the extracted place with a second AI call right
      // after parsing, so a single repeat must stay possible.
      final snap = parseBudgetLedger(jsonEncode(validLedgerJson())).copyWith(
        aiRequests: 1,
        usedPhases: const <String>['create'],
      );
      expect(reasonForReserveAi(snap, 'create'), isNull);
      expect(reasonForReserveAi(snap.copyWith(aiRequests: 3), 'create'),
          isNotNull);
    });

    test('rejects when cap reached', () {
      final snap = parseBudgetLedger(jsonEncode(validLedgerJson())).copyWith(
        aiRequests: 3,
        usedPhases: const <String>['create', 'query', 'change'],
      );
      expect(reasonForReserveAi(snap, 'create'), isNotNull);
    });
  });

  group('native pre_actions detail read fence', () {
    const createdId = '3389cdce-c632-42e2-a510-87bccf57711c';
    Uri requestUri([String extra = '']) => Uri.parse(
        'https://qa.example/rest/v1/pre_actions?select=event_id&event_id=eq.$createdId&user_id=eq.$uid&source=eq.external_preparation$extra');
    String? reason({
      String method = 'GET',
      Uri? uri,
      String? eventId = createdId,
      bool verified = true,
    }) => NativeGuideEnvironment.preActionReadReason(
        method: method,
        uri: uri ?? requestUri(),
        uid: uid,
        createdId: eventId,
        verifiedUid: verified,
      );

    test('accepts the exact owned, freshly created event query', () {
      expect(reason(), isNull);
    });
    test('rejects writes, unbound reads, and unverified UID', () {
      expect(reason(method: 'POST'), isNotNull);
      expect(reason(eventId: null), isNotNull);
      expect(reason(verified: false), isNotNull);
    });
    test('rejects wrong event and wrong QA-user scope', () {
      expect(reason(uri: requestUri().replace(queryParameters: {
        ...requestUri().queryParameters,
        'event_id': 'eq.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      })), isNotNull);
      expect(reason(uri: requestUri().replace(queryParameters: {
        ...requestUri().queryParameters,
        'user_id': 'eq.22222222-2222-4222-8222-222222222222',
      })), isNotNull);
    });
    test('rejects OR/IN, duplicate, and extra scope filters', () {
      expect(reason(uri: requestUri('&or=(event_id.eq.$createdId)')), isNotNull);
      expect(reason(uri: requestUri('&event_id=in.($createdId)')), isNotNull);
      expect(reason(uri: Uri.parse(
          'https://qa.example/rest/v1/pre_actions?select=event_id&event_id=eq.$createdId&event_id=eq.$createdId&user_id=eq.$uid&source=eq.external_preparation')), isNotNull);
      expect(reason(uri: requestUri('&enabled=eq.true')), isNotNull);
    });
  });
  group('readTableReason (request scope for table reads)', () {
    final uid = ledgerUuid;

    test('events with explicit uid scope is allowed', () {
      expect(
          readTableReason(
              table: 'events',
              query: <String, String>{'user_id': 'eq.$uid'},
              uid: uid),
          isNull);
    });

    test('user_settings with explicit uid scope is allowed', () {
      expect(
          readTableReason(
              table: 'user_settings',
              query: <String, String>{'user_id': 'eq.$uid'},
              uid: uid),
          isNull);
    });

    test('users with explicit id scope is allowed', () {
      expect(
          readTableReason(
              table: 'users',
              query: <String, String>{'id': 'eq.$uid'},
              uid: uid),
          isNull);
    });

    test('events without uid scope is rejected', () {
      expect(
          readTableReason(table: 'events', query: <String, String>{}, uid: uid),
          isNotNull);
      expect(
          readTableReason(
              table: 'events',
              query: <String, String>{'user_id': 'eq.someone-else'},
              uid: uid),
          isNotNull);
    });

    test('groups is denied (no caller-scope proof)', () {
      expect(
          readTableReason(
              table: 'groups',
              query: <String, String>{'user_id': 'eq.$uid'},
              uid: uid),
          isNotNull);
    });

    test('unrelated tables are denied', () {
      expect(
          readTableReason(
              table: 'voice_logs',
              query: <String, String>{'user_id': 'eq.$uid'},
              uid: uid),
          isNotNull);
      expect(
          readTableReason(
              table: 'reminders',
              query: <String, String>{'user_id': 'eq.$uid'},
              uid: uid),
          isNotNull);
    });
  });

  group('weatherRequestReason (public weather scope)', () {
    test('forecast with numeric coords and allowed keys is accepted', () {
      final uri =
          Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
        'latitude': '37.5',
        'longitude': '127.0',
        'current': 'temperature_2m',
        'timezone': 'Asia/Seoul',
      });
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {}), isNull);
    });

    test('reverse geocoding with coords is accepted', () {
      final uri = Uri.https(
          'geocoding-api.open-meteo.com', '/v1/reverse', <String, String>{
        'latitude': '37.5',
        'longitude': '127.0',
        'count': '5',
        'language': 'ko',
      });
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {}), isNull);
    });

    test('non-allowlist path is rejected', () {
      final uri = Uri.https(
          'api.open-meteo.com', '/v1/not-allowed', <String, String>{});
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('non-allowlist host is rejected', () {
      final uri = Uri.https('example.com', '/v1/forecast', <String, String>{});
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('non-numeric coords are rejected', () {
      final uri =
          Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
        'latitude': 'north',
        'longitude': '127.0',
      });
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('extra unknown query keys are rejected', () {
      final uri =
          Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
        'latitude': '37.5',
        'longitude': '127.0',
        'apikey': 'leak',
      });
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('non-https scheme is rejected', () {
      final uri =
          Uri(scheme: 'http', host: 'api.open-meteo.com', path: '/v1/forecast');
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('non-443 port is rejected', () {
      final uri = Uri(
          scheme: 'https',
          host: 'api.open-meteo.com',
          port: 8443,
          path: '/v1/forecast');
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('userinfo in URL is rejected', () {
      final uri = Uri(
          scheme: 'https',
          userInfo: 'user:pass',
          host: 'api.open-meteo.com',
          path: '/v1/forecast');
      expect(weatherRequestReason(uri: uri, forwardedHeaders: const {}),
          isNotNull);
    });

    test('app/auth headers are never forwarded', () {
      final uri =
          Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
        'latitude': '37.5',
        'longitude': '127.0',
      });
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {
            'authorization': 'Bearer something',
          }),
          isNotNull);
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {
            'apikey': 'whatever',
          }),
          isNotNull);
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {
            'x-supabase-auth': 'x',
          }),
          isNotNull);
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {
            'cookie': 'session=abc',
          }),
          isNotNull);
      // Arbitrary non-minted headers are also rejected.
      expect(
          weatherRequestReason(uri: uri, forwardedHeaders: const {
            'x-trace-id': 'should-not-be-forwarded',
          }),
          isNotNull);
    });
  });

  group('optional-background RPC allowlist composition', () {
    test('only record_user_activity is in the optional-background set', () {
      expect(NativeGuideEnvironment.optionalBackgroundRpcs,
          <String>['record_user_activity']);
    });

    test('ensure_current_user_profile is not in any allowlist', () {
      expect(NativeGuideEnvironment.optionalBackgroundRpcs,
          isNot(contains('ensure_current_user_profile')));
      expect(NativeGuideEnvironment.peeks,
          isNot(contains('ensure_current_user_profile')));
      expect(NativeGuideEnvironment.guideRpcs,
          isNot(contains('ensure_current_user_profile')));
    });

    test('unknown RPCs cannot widen the allowlist by composition', () {
      // Only the explicit set may be optional-background. Adding any new rpc
      // requires an explicit code change to the constant list. This
      // snapshot test fixes the current composition; widening the allowlist
      // is a deliberate, code-reviewable act.
      expect(NativeGuideEnvironment.optionalBackgroundRpcs.length, 1);
      final allowedRpcs = <String>{
        ...NativeGuideEnvironment.peeks,
        ...NativeGuideEnvironment.guideRpcs,
        ...NativeGuideEnvironment.optionalBackgroundRpcs,
      };
      // ensure_current_user_profile and friends must remain outside.
      for (final forbidden in <String>[
        'ensure_current_user_profile',
        'record_login_activity',
        'record_event',
        'log_session_start',
      ]) {
        expect(allowedRpcs.contains(forbidden), isFalse,
            reason: '$forbidden must not be in any allowlist');
      }
    });
  });

  group('optional-background REST GETs (exact path only)', () {
    test('only exact listed GETs are optional background',
        () {
      expect(NativeGuideEnvironment.optionalBackgroundRestGetPaths,
          <String>[
            '/rest/v1/groups',
            '/rest/v1/group_backups',
            '/rest/v1/group_event_comments',
          ]);
      expect(
          NativeGuideEnvironment.isOptionalBackgroundRestGet(
              '/rest/v1/groups', 'GET'),
          isTrue);
      expect(
          NativeGuideEnvironment.isOptionalBackgroundRestGet(
              '/rest/v1/group_backups', 'GET'),
          isTrue);
      expect(
          NativeGuideEnvironment.isOptionalBackgroundRestGet(
              '/rest/v1/group_event_comments', 'GET'),
          isTrue);
      for (final path in <String>[
        '/rest/v1/group_backups?select=*',
        '/rest/v1/group_event_comments?select=*',
        '/rest/v1/group_backup',
        '/rest/v1/Group_backups',
        '/rest/v1/group_backups/other',
      ]) {
        expect(NativeGuideEnvironment.isOptionalBackgroundRestGet(path, 'GET'),
            isFalse,
            reason: 'Only exact background paths may be omitted');
      }
    });

    test('non-matching paths and methods are NOT optional-background', () {
      for (final path in <String>[
        '/rest/v1/groups',
        '/rest/v1/groups?select=*',
        '/rest/v1/group_backups',
        '/rest/v1/group_backups?select=*',
        '/rest/v1/group_event_comments',
        '/rest/v1/group',
        '/rest/v1/Groups',
        '/rest/v1/users',
        '/storage/v1/bucket/q',
      ]) {
        for (final method in <String>['POST', 'PATCH', 'PUT', 'DELETE']) {
          expect(
              NativeGuideEnvironment.isOptionalBackgroundRestGet(path, method),
              isFalse,
              reason: '$method $path must NOT be optional-background');
        }
      }
    });

    test('related-insert allowlist composition is the documented four tables',
        () {
      expect(kRelatedInsertTables, <String>{
        'pre_actions',
        'reminders',
        'voice_logs',
        'location_history',
      });
      for (final table in kRelatedInsertTables) {
        expect(kRelatedInsertKeys.containsKey(table), isTrue,
            reason: '$table must declare allowed insert keys');
        // User-supplied id is never allowed.
        expect(kRelatedInsertKeys[table]!.contains('id'), isFalse,
            reason: '$table must not allow a user-supplied id');
        expect(kRelatedInsertKeys[table]!.contains('user_id'), isTrue);
        expect(kRelatedInsertKeys[table]!.contains('event_id'), isTrue);
      }
    });
  });

  group('relatedInsertReason (strict _saveRelatedRecords fence)', () {
    const createdId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    BudgetLedgerSnapshot baseLedger() =>
        parseBudgetLedger(jsonEncode(validLedgerJson())).copyWith(
          createAttempted: true,
          createdId: createdId,
        );

    test('pre_actions happy path is allowed', () {
      final reason = relatedInsertReason(
        table: 'pre_actions',
        body: <Map<String, Object?>>[
          <String, Object?>{
            'event_id': createdId,
            'user_id': ledgerUuid,
            'title': 'pre',
            'notify_at': '2026-10-21T10:00:00Z',
            'is_done': false,
          },
        ],
        query: const <String, String>{},
        headers: const <String, String>{},
        ledger: baseLedger(),
        expectedUid: ledgerUuid,
        phase: 'save',
      );
      expect(reason, isNull);
    });

    test('reminders, voice_logs, location_history happy paths allowed', () {
      final headers = const <String, String>{'Prefer': 'return=representation'};
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'type': 'push',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_sent': false,
              },
            ],
            query: const <String, String>{},
            headers: headers,
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
      expect(
          relatedInsertReason(
            table: 'voice_logs',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'raw_text': '내일 3시에 회의',
                'parsed_json': <String, Object?>{'when': 'tomorrow'},
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
      expect(
          relatedInsertReason(
            table: 'location_history',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'location': 'Seoul',
                'supplies': <String>['pen'],
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
    });

    test('phase != save is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'editSave',
          ),
          isNotNull);
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'preview',
          ),
          isNotNull);
    });

    test('ledger without createAttempted is rejected', () {
      final empty = BudgetLedgerSnapshot.initial(
        budgetId: ledgerBudgetId,
        uid: ledgerUuid,
      );
      expect(
          relatedInsertReason(
            table: 'voice_logs',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: empty,
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('on_conflict query is rejected (no upsert)', () {
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: const <Object?>[],
            query: const <String, String>{'on_conflict': 'id'},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('Prefer: resolution=merge-duplicates is rejected (no upsert)', () {
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{
              'Prefer': 'return=representation,resolution=merge-duplicates',
            },
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{
              'Prefer': 'resolution=ignore-duplicates',
            },
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('Prefer: return=representation alone is allowed', () {
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{
              'Prefer': 'return=representation',
            },
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
    });

    test('batch > 20 rows is rejected', () {
      final rows = List<Map<String, Object?>>.generate(
          21,
          (_) => <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 't',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
              });
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: rows,
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('row with id key is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'user-supplied-id',
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('row with mismatched user_id is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': 'someone-else',
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('row with mismatched event_id is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': 'other-event-id',
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('extra unknown key in row is rejected', () {
      for (final table in <String>['pre_actions', 'reminders']) {
        final extra = table == 'pre_actions'
            ? <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': false,
                'sneaky': 'no',
              }
            : <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'type': 'push',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_sent': false,
                'channel': 'sms',
              };
        expect(
            relatedInsertReason(
              table: table,
              body: <Map<String, Object?>>[extra],
              query: const <String, String>{},
              headers: const <String, String>{},
              ledger: baseLedger(),
              expectedUid: ledgerUuid,
              phase: 'save',
            ),
            isNotNull,
            reason: '$table should reject extra key');
      }
    });

    test('pre_actions is_done=true is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_done': true,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
      // Missing the column entirely also rejected (must be exactly false).
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'title': 'pre',
                'notify_at': '2026-10-21T10:00:00Z',
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('reminders is_sent must be false', () {
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'type': 'push',
                'notify_at': '2026-10-21T10:00:00Z',
                'is_sent': false,
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
      // is_sent=true rejected.
      final sent = List<Map<String, Object?>>.from(<Map<String, Object?>>[
        <String, Object?>{
          'event_id': createdId,
          'user_id': ledgerUuid,
          'type': 'push',
          'notify_at': '2026-10-21T10:00:00Z',
          'is_sent': true,
        },
      ]);
      expect(
          relatedInsertReason(
            table: 'reminders',
            body: sent,
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('voice_logs and location_history have no boolean gate', () {
      // They have no is_done/is_sent column; a happy-path row should pass.
      expect(
          relatedInsertReason(
            table: 'voice_logs',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'raw_text': 'x',
                'parsed_json': <String, Object?>{},
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
      expect(
          relatedInsertReason(
            table: 'location_history',
            body: <Map<String, Object?>>[
              <String, Object?>{
                'event_id': createdId,
                'user_id': ledgerUuid,
                'location': 'Seoul',
                'supplies': <String>[],
              },
            ],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNull);
    });

    test('unrelated tables fail closed', () {
      expect(
          relatedInsertReason(
            table: 'user_settings',
            body: const <Object?>[],
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });

    test('non-list body is rejected', () {
      expect(
          relatedInsertReason(
            table: 'pre_actions',
            body: <String, Object?>{'event_id': createdId},
            query: const <String, String>{},
            headers: const <String, String>{},
            ledger: baseLedger(),
            expectedUid: ledgerUuid,
            phase: 'save',
          ),
          isNotNull);
    });
  });

  group('parse inconsistency: createdId set while createAttempted=false', () {
    test('inconsistent state fails closed', () {
      final j = validLedgerJson()
        ..['createAttempted'] = false
        ..['createdId'] = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      expect(() => parseBudgetLedger(jsonEncode(j)), throwsFormatException);
    });
  });

  group('voice correction rule read contract (R2 JX9aD8bqcYuRzpoQ)', () {
    // Drift-detection duplicates of the exact gateway wire in
    // lib/data/repositories/voice_correction_rule_repository.dart.
    const personalSelect = 'id, user_id, stage, field_name, from_text, '
        'to_text, context_before, context_after, confidence_count, '
        'reject_count, enabled, is_sensitive, created_at, updated_at';
    const commonSelect = 'id, stage, field_name, from_text, to_text, '
        'context_before, context_after, support_count, conflict_count, '
        'confidence_score, enabled, created_at, updated_at';
    Map<String, String> personal() => <String, String>{
          'select': personalSelect,
          'user_id': 'eq.$uid',
          'enabled': 'eq.true',
          'order': 'confidence_count.desc',
          'limit': '200',
        };
    Map<String, String> common() => <String, String>{
          'select': commonSelect,
          'enabled': 'eq.true',
          'support_count': 'gte.5',
          'conflict_count': 'eq.0',
          'confidence_score': 'gte.0.85',
          'order': 'confidence_score.desc',
          'limit': '100',
        };

    test('exact gateway personal read is allowed', () {
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: personal(), uid: uid),
          isNull);
    });

    test('exact gateway common read is allowed without user scoping', () {
      expect(
          readTableReason(
              table: kVoiceCommonRuleTable, query: common(), uid: uid),
          isNull);
    });

    test('wrong uid, cross uid and missing user_id are denied', () {
      final other = '22222222-2222-4222-8222-222222222222';
      final crossUid = personal()..['user_id'] = 'eq.$other';
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: crossUid, uid: uid),
          isNotNull);
      final noUid = personal()..remove('user_id');
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: noUid, uid: uid),
          isNotNull);
    });

    test('select * and projection drift are denied', () {
      final star = personal()..['select'] = '*';
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: star, uid: uid),
          isNotNull);
      final commonProjection = personal()..['select'] = commonSelect;
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable,
              query: commonProjection,
              uid: uid),
          isNotNull);
    });

    test('extra keys, wrong filters/order/limit are denied', () {
      final extra = personal()..['id'] = 'eq.1';
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: extra, uid: uid),
          isNotNull);
      for (final mutation in <Map<String, String> Function()>[
        () => personal()..['limit'] = '201',
        () => personal()..['limit'] = '100000',
        () => personal()..['order'] = 'confidence_count.asc',
        () => personal()..['enabled'] = 'eq.false',
        () => personal()..['enabled'] = 'is.null',
      ]) {
        expect(
            readTableReason(
                table: kVoicePersonalRuleTable, query: mutation(), uid: uid),
            isNotNull);
      }
    });

    test('common read with user_id or drifted filters is denied', () {
      final scoped = common()..['user_id'] = 'eq.$uid';
      expect(
          readTableReason(
              table: kVoiceCommonRuleTable, query: scoped, uid: uid),
          isNotNull);
      final drifted = common()..['support_count'] = 'gte.0';
      expect(
          readTableReason(
              table: kVoiceCommonRuleTable, query: drifted, uid: uid),
          isNotNull);
      final personalShape = common()
        ..['select'] = personalSelect
        ..['user_id'] = 'eq.$uid'
        ..remove('support_count')
        ..remove('conflict_count')
        ..remove('confidence_score')
        ..['order'] = 'confidence_count.desc'
        ..['limit'] = '200';
      expect(
          readTableReason(
              table: kVoiceCommonRuleTable, query: personalShape, uid: uid),
          isNotNull);
    });

    test('shared/other tables remain denied (groups, group_backups)', () {
      expect(
          readTableReason(table: 'groups', query: <String, String>{}, uid: uid),
          isNotNull);
      expect(
          readTableReason(
              table: 'group_backups', query: <String, String>{}, uid: uid),
          isNotNull);
    });

    test('valid reads never latch or consume the AI reserve chain', () {
      // Unit proof for the audit chain: peek 200 → GET voice_correction_rules
      // (allowed, non-fatal, no ledger consumption) → AI reserve reachable.
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: personal(), uid: uid),
          isNull);
      expect(
          readTableReason(
              table: kVoiceCommonRuleTable, query: common(), uid: uid),
          isNull);
      var snap = BudgetLedgerSnapshot.initial(
              budgetId: 'planflow-guide-FRM9-20261021', uid: uid)
          .copyWith(maxAiRequests: 3);
      for (final phase in <String>['create', 'query', 'change']) {
        expect(reasonForReserveAi(snap, phase), isNull,
            reason: 'AI reserve must stay reachable after valid rule reads');
        snap = snap.copyWith(
            aiRequests: snap.aiRequests + 1,
            usedPhases: <String>[...snap.usedPhases, phase]);
      }
      expect(snap.aiRequests, 3);
      expect(reasonForReserveAi(snap, 'create'), isNotNull);
      // Reads stay repeatable: they never latch validity or spend budget.
      expect(
          readTableReason(
              table: kVoicePersonalRuleTable, query: personal(), uid: uid),
          isNull);
    });

    test('source-level: writes stay fatal (voice tables GET-gated only)', () {
      final src = File('integration_test/support/'
              'real_ui_guide_native_environment.dart')
          .readAsStringSync();
      // The environment never special-cases voice tables outside the pure
      // read contract; POST/PATCH/DELETE on them fall through to deny().
      expect(src, isNot(contains('voice_correction_rules')));
      expect(src, isNot(contains('voice_common_correction_rules')));
      expect(src, contains("if (method == 'GET')"));
      expect(src, contains('readTableReason('));
    });
  });

  group('native HTTP response status contract', () {
    const host = 'xqvvfnvmytjlblcngipn.supabase.co';
    final proxy = Uri.https(host, '/functions/v1/naver-geocode');
    final transit = proxy.replace(queryParameters: <String, String>{
      'start': '126.98,37.56',
      'goal': '127.10,37.48',
      'mode': 'transit',
    });
    const minted = <String, String>{
      'accept': 'application/json',
      'apikey': 'anon-key',
      'authorization': 'Bearer session-jwt',
    };
    final expectedBody = utf8.encode(jsonEncode(<String, String>{
      'code': 'unsupported_transit',
      'error': 'Transit directions are not supported by this proxy.',
    }));
    bool allowed({
      int status = 501,
      String method = 'GET',
      Uri? request,
      Map<String, String>? headers,
      bool configured = true,
      List<int>? body,
    }) =>
        isNativeHttpResponseStatusAllowed(
          statusCode: status,
          method: method,
          uri: request ?? transit,
          headers: headers ?? minted,
          configuredProxy: configured ? proxy : null,
          backendHost: host,
          bodyBytes: body ?? expectedBody,
        );

    test('2xx retains the original success rule for non-map RPCs', () {
      for (final status in <int>[200, 201, 204, 299]) {
        expect(
            allowed(
                status: status,
                method: 'POST',
                request:
                    Uri.https(host, '/rest/v1/rpc/get_real_ui_guide_session'),
                configured: false,
                body: const <int>[]),
            isTrue);
      }
    });
    test('only explicit validated unsupported-transit 501 is nonfatal', () {
      expect(allowed(), isTrue);
    });
    test('auth/provider/other HTTP errors remain fatal', () {
      for (final status in <int>[
        199,
        300,
        400,
        401,
        403,
        404,
        429,
        500,
        502,
        503
      ]) {
        expect(allowed(status: status), isFalse, reason: 'status=$status');
      }
    });
    test('unsupported response cannot bypass origin, shape, or secret guards',
        () {
      expect(allowed(method: 'POST'), isFalse);
      expect(allowed(configured: false), isFalse);
      expect(allowed(request: transit.replace(host: 'maps.googleapis.com')),
          isFalse);
      expect(allowed(request: transit.replace(path: '/functions/v1/other')),
          isFalse);
      expect(allowed(request: proxy.replace(queryParameters: {'query': '강남역'})),
          isFalse);
      expect(
          allowed(
              request: transit.replace(queryParameters: {
            ...transit.queryParameters,
            'mode': 'car',
            'option': 'trafast',
          })),
          isFalse);
      expect(
          allowed(
              request: transit.replace(queryParameters: {
            ...transit.queryParameters,
            'option': 'trafast',
          })),
          isFalse);
      expect(allowed(headers: {...minted, 'appkey': 'forbidden'}), isFalse);
    });
    test('unknown, malformed, oversized, or lookalike 501 bodies stay fatal',
        () {
      final bodies = <List<int>>[
        const <int>[],
        const <int>[255],
        utf8.encode('not json'),
        utf8.encode(jsonEncode(['unsupported_transit'])),
        utf8.encode(jsonEncode({'error': 'unsupported_transit'})),
        utf8.encode(jsonEncode(
            {'code': 'unsupported_transit', 'error': 'provider failed'})),
        utf8.encode(jsonEncode({
          'code': 'unsupported_transit',
          'error': 'Transit directions are not supported by this proxy.',
          'extra': true
        })),
        List<int>.filled(1025, 32),
      ];
      for (final body in bodies) {
        expect(allowed(body: body), isFalse);
      }
    });
  });

  group('mapProxyRequestReason (backend map proxy contract)', () {
    const host = 'xqvvfnvmytjlblcngipn.supabase.co';
    final configured = Uri.parse('https://$host/functions/v1/naver-geocode');
    const minted = <String, String>{
      'accept': 'application/json',
      'apikey': 'anon-key',
      'authorization': 'Bearer session-jwt',
    };
    Uri geocode([Map<String, String>? extra]) => Uri.https(
        host,
        '/functions/v1/naver-geocode',
        <String, String>{'query': '강남역', ...?extra});
    Uri direction(String mode, {bool withOption = true}) =>
        Uri.https(host, '/functions/v1/naver-geocode', <String, String>{
          'start': '126.98,37.56',
          'goal': '127.10,37.48',
          'mode': mode,
          if (withOption) 'option': 'trafast',
        });
    String? reason(String method, Uri uri,
            {Map<String, String> headers = minted,
            Uri? proxy,
            bool useConfiguredProxy = true}) =>
        mapProxyRequestReason(
            method: method,
            uri: uri,
            headers: headers,
            configuredProxy: useConfiguredProxy ? (proxy ?? configured) : null,
            backendHost: host);

    test('geocode and direction shapes on the configured route are allowed',
        () {
      expect(reason('GET', geocode()), isNull);
      expect(reason('GET', direction('car')), isNull);
      expect(reason('GET', direction('transit', withOption: false)), isNull);
    });

    test('direct secret-bearing provider hosts are denied', () {
      expect(
          reason(
              'GET',
              Uri.parse('https://naveropenapi.apigw.ntruss.com'
                  '/map-geocode/v2/geocode?query=x')),
          isNotNull);
      expect(
          reason(
              'GET',
              Uri.parse('https://apis.openapi.sk.com'
                  '/tmap/pois?searchKeyword=x&count=10')),
          isNotNull);
      expect(
          reason(
              'GET',
              Uri.parse('https://maps.googleapis.com'
                  '/maps/api/geocode/json?address=x&key=k')),
          isNotNull);
    });

    test('unconfigured proxy denies every map request', () {
      expect(reason('GET', geocode(), useConfiguredProxy: false), isNotNull);
    });

    test('non-GET method and path drift are denied', () {
      expect(reason('POST', geocode()), isNotNull);
      expect(
          reason('GET', Uri.https(host, '/functions/v1/naver-userinfo-proxy')),
          isNotNull);
      expect(
          reason(
              'GET',
              Uri.https(host, '/functions/v1/naver-geocode-v2',
                  <String, String>{'query': 'x'})),
          isNotNull);
    });

    test('extra query keys and oversized/empty queries are denied', () {
      expect(
          reason('GET', geocode(<String, String>{'key': 'stolen'})), isNotNull);
      expect(
          reason('GET', geocode(<String, String>{'address': 'x'})), isNotNull);
      expect(
          reason(
              'GET',
              Uri.https(host, '/functions/v1/naver-geocode',
                  <String, String>{'query': 'x' * 500})),
          isNotNull);
      expect(reason('GET', Uri.https(host, '/functions/v1/naver-geocode')),
          isNotNull);
    });

    test('bad coords, mode and option are denied', () {
      expect(
          reason(
              'GET',
              Uri.https(host, '/functions/v1/naver-geocode', <String, String>{
                'start': 'abc',
                'goal': '127.10,37.48',
                'mode': 'car',
                'option': 'trafast',
              })),
          isNotNull);
      expect(
          reason(
              'GET',
              Uri.https(host, '/functions/v1/naver-geocode', <String, String>{
                'start': '126.98,37.56',
                'goal': '127.10,37.48',
                'mode': 'walking',
              })),
          isNotNull);
      expect(reason('GET', direction('car', withOption: false)), isNotNull);
      expect(reason('GET', direction('transit')), isNotNull);
    });

    test('secret-bearing or malformed headers are denied', () {
      expect(
          reason('GET', geocode(), headers: <String, String>{
            ...minted,
            'X-NCP-APIGW-API-KEY': 'naver-secret',
          }),
          isNotNull);
      expect(
          reason('GET', geocode(), headers: <String, String>{
            ...minted,
            'appkey': 'tmap-secret',
          }),
          isNotNull);
      expect(
          reason('GET', geocode(), headers: <String, String>{
            'accept': 'application/json',
            'authorization': 'Basic xyz',
          }),
          isNotNull);
    });

    test('finite per-run cap is pinned and static params cannot be tampered',
        () {
      expect(kMaxMapProxyCallsPerRun, 200);
      final withStatic =
          Uri.parse('https://$host/functions/v1/naver-geocode?channel=qa');
      expect(
          mapProxyRequestReason(
              method: 'GET',
              uri: Uri.https(host, '/functions/v1/naver-geocode',
                  <String, String>{'query': 'x', 'channel': 'qa'}),
              headers: minted,
              configuredProxy: withStatic,
              backendHost: host),
          isNull);
      expect(
          mapProxyRequestReason(
              method: 'GET',
              uri: Uri.https(host, '/functions/v1/naver-geocode',
                  <String, String>{'query': 'x', 'channel': 'evil'}),
              headers: minted,
              configuredProxy: withStatic,
              backendHost: host),
          isNotNull);
    });
  });
}
