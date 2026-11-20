import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_local_backend.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'guide-user';
const _version = realUiGuideVersion;
const _eventId = 'guide-event';
const _createOp = 'create-operation';
final _startAt =
    DateTime.fromMillisecondsSinceEpoch(0).copyWith(hour: 12).toUtc();
final _updatedAt = _startAt.add(const Duration(hours: 3));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('actual provider starts locally without initializing Supabase',
      () async {
    final scope = ProviderContainer();
    addTearDown(scope.dispose);

    expect(scope.read(realUiGuideBackendProvider), isA<LocalGuideBackend>());
    final c = scope.read(realUiGuideCoordinatorProvider);
    final opened = await c.start(uid: _uid);
    expect(opened.version, realUiGuideVersion);
    expect(opened.step, GuideStep.intro);
    expect(opened.run, GuideRun.active);
  });

  test('full flow and cold resume preserve bound and local-only steps',
      () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);
    await flow.createSpeech();
    await flow.correctAndSave();
    await flow.saveObserved();
    await flow.reopen(GuideStep.savedDetail);
    expect(flow.state.createdEventId, _eventId);
    await flow.detailAcknowledged();
    await flow.queryMicTapped();
    await flow.reopen(GuideStep.querySpeech);
    await flow.queryObserved();
    await flow.reopen(GuideStep.changeSpeech);

    await flow.editPreview();
    await flow.reopen(GuideStep.editPreview);
    expect(flow.state.expectedUpdatedStartLocal, _updatedAt);
    expect(flow.state.createdEventId, _eventId);
    expect(flow.state.serverRevision, 4);
    flow.boundEvent = _event(startAt: _updatedAt);
    await flow.updateObserved();
    await flow.reopen(GuideStep.updatedDetail);
    expect(flow.state.expectedUpdatedStartLocal, _updatedAt);
    expect(flow.state.createdEventId, _eventId);
    expect(flow.state.serverRevision, 5);
    expect(flow.boundEventReads, List.filled(4, (_uid, _eventId)));

    await flow.dispatch(SyncChoicePresented(
      uid: _uid,
      sessionId: flow.state.sessionId,
      expectedRevision: flow.state.revision,
    ));
    expect(flow.state.step, GuideStep.syncChoice);
    await flow.reopen(GuideStep.syncChoice);
    await flow.dispatch(SyncChoiceClosed(
      uid: _uid,
      sessionId: flow.state.sessionId,
      expectedRevision: flow.state.revision,
    ));
    await flow.reopen(GuideStep.completed, run: GuideRun.terminal);
    final firstSession = flow.state.sessionId;
    final reply = await flow.backend.begin(
      uid: _uid,
      version: _version,
      requestId: 'read-completed',
    );
    expect(reply, isA<GuideBeginGranted>());
    expect((reply as GuideBeginGranted).state.step, GuideStep.completed);

    expect(await flow.coordinator.restartCompletedGuide(uid: _uid), isTrue);
    final firstReplay = flow.state.sessionId;
    expect(firstReplay, isNot(firstSession));
    expect(flow.state.isReplay, isTrue);
    await flow.reopen(GuideStep.homeMic);
    await flow.createSpeech();
    final replayAccess = await flow.backend.authorize(
      context: flow.context(),
      operationId: 'replay-parse',
    );
    expect(replayAccess.reasonCode, 'ordinary_quota_required');
    final replayEvent = _event().copyWith(title: 'Replay practice event');
    flow.boundEvent = replayEvent;
    await flow.correctAndSave();
    await flow.saveObserved(event: replayEvent);
    await flow.detailAcknowledged();
    await flow.queryMicTapped();
    await flow.queryObserved();
    await flow.reopen(GuideStep.changeSpeech);
    await flow.editPreview();
    expect(flow.state.step, GuideStep.editPreview);
    await flow.coordinator.terminate(GuideExit.skip);
    await flow.reopen(GuideStep.skipped, run: GuideRun.terminal);
    expect(await flow.coordinator.restartCompletedGuide(uid: _uid), isTrue);
    expect(flow.state.sessionId, isNot(firstSession));
    expect(flow.state.sessionId, isNot(firstReplay));
    expect(flow.state.isReplay, isTrue);
    expect(flow.state.step, GuideStep.homeMic);
  });

  test('two local runs save converted edit times without a cold resume',
      () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);

    Future<void> completeRun(EventModel event, Duration shift) async {
      flow.boundEvent = event;
      await flow.createSpeech();
      await flow.correctAndSave();
      await flow.saveObserved(event: event);
      await flow.detailAcknowledged(event: event);
      await flow.queryMicTapped();
      await flow.queryObserved(event: event);
      expect(flow.state.step, GuideStep.changeSpeech);

      final expected = event.startAt!.add(shift);
      final requested = planflowLocalDateTimeToUtc(planflowLocal(expected));
      final preview = await flow.editPreview(event: event, startAt: requested);
      expect(preview.run, GuideRun.active);
      expect(preview.step, GuideStep.editPreview);
      final previewStart = preview.expectedUpdatedStartLocal!;
      expect(previewStart == expected, isTrue);
      expect(expected == previewStart, isTrue);

      final confirmed = await flow.dispatch(EditConfirmed(
        uid: _uid,
        sessionId: preview.sessionId,
        expectedRevision: preview.revision,
        operationId: 'confirm-${event.id}',
        confirmedStartLocal: expected,
      ));
      expect(confirmed.step, GuideStep.editPreview);
      expect(confirmed.revision, preview.revision + 1);
      expect(confirmed.serverRevision, preview.serverRevision);

      final updated = event.copyWith(startAt: expected);
      flow.boundEvent = updated;
      await flow.updateObserved(event: updated);
      expect(flow.state.step, GuideStep.updatedDetail);
      await flow.dispatch(SyncChoicePresented(
        uid: _uid,
        sessionId: flow.state.sessionId,
        expectedRevision: flow.state.revision,
      ));
      await flow.dispatch(SyncChoiceClosed(
        uid: _uid,
        sessionId: flow.state.sessionId,
        expectedRevision: flow.state.revision,
      ));
      expect(flow.state.step, GuideStep.completed);
      expect(flow.state.run, GuideRun.terminal);
    }

    await completeRun(_event(), const Duration(hours: 1));
    final firstSessionId = flow.state.sessionId;
    expect(await flow.coordinator.restartCompletedGuide(uid: _uid), isTrue);
    expect(flow.state.step, GuideStep.homeMic);
    expect(flow.state.isReplay, isTrue);
    expect(flow.state.sessionId, isNot(firstSessionId));
    expect(flow.state.createdEventId, isNull);
    await completeRun(
      _event().copyWith(id: 'replay-event'),
      const Duration(hours: 3),
    );
  });

  for (final step in [GuideStep.createSpeech, GuideStep.correctAndSave]) {
    test('unbound ${step.name} resumes at the home mic', () async {
      final flow = _Flow();
      await flow.reopen(GuideStep.intro);
      await flow.createSpeech();
      if (step == GuideStep.correctAndSave) await flow.correctAndSave();
      expect(flow.state.step, step);
      final session = flow.state.sessionId;

      await flow.reopen(GuideStep.homeMic);
      expect(flow.state.sessionId, session);
      expect(flow.state.createdEventId, isNull);
    });
  }

  test('an intro marker gets a first local session and stays at the home mic',
      () async {
    final flow = _Flow();
    final intro = GuideAccountFeatureTourStore(
      uidProvider: () => _uid,
      progress: flow.progress,
    );
    await intro.markCompleted();
    final marker = await flow.progress.load(uid: _uid, version: _version);
    expect(marker?.sessionId, isNull);

    await flow.reopen(GuideStep.homeMic);

    expect(flow.state.sessionId, 'local-$_uid-$_version');
    expect(flow.state.serverRevision, 0);
  });

  test('resume reads the last advance after progress persistence fails',
      () async {
    final progress = _FailNextSave(LocalGuideProgressStore());
    final flow = _Flow(progress: progress);
    await flow.reopen(GuideStep.intro);
    await flow.createSpeech();
    await flow.correctAndSave();
    await flow.saveObserved();
    await flow.detailAcknowledged();
    await flow.queryMicTapped();
    await flow.queryObserved();

    progress.failNext = true;
    await flow.editPreview();
    expect(flow.state.run, GuideRun.blocked);
    expect(flow.state.step, GuideStep.changeSpeech);
    await flow.dispatch(ResumeRequested(
      uid: _uid,
      sessionId: flow.state.sessionId,
      expectedRevision: flow.state.revision,
    ));

    expect(flow.state.run, GuideRun.active);
    expect(flow.state.step, GuideStep.editPreview);
    expect(flow.state.createdEventId, _eventId);
    expect(flow.state.expectedUpdatedStartLocal, _updatedAt);
    expect(flow.state.serverRevision, 4);
  });

  for (final coldRestart in [false, true]) {
    test(
        'confirm rebinds a pending save using its existing event '
        '(cold restart: $coldRestart)', () async {
      final progress = _FailNextSave(LocalGuideProgressStore());
      final flow = _Flow(progress: progress);
      await flow.reopen(GuideStep.intro);
      await flow.createSpeech();
      await flow.correctAndSave();

      progress.failNext = true;
      await flow.saveObserved();
      expect(flow.state.run, GuideRun.blocked);
      expect(flow.state.errorCode, guideCreatedCheckpointPendingCode);
      expect(flow.state.createdEventId, _eventId);
      expect(flow.state.savedCreateOperationId, _createOp);
      if (coldRestart) {
        await flow.reopen(GuideStep.correctAndSave, run: GuideRun.blocked);
      }

      // Confirm's recovery dispatches SaveObserved using the stored event
      // and operation IDs. It doesn't issue another calendar write.
      final pending = flow.state;
      await flow.saveObserved(operationId: 'different-operation');
      expect(flow.state, same(pending));
      await flow.saveObserved(
        event: _event(id: 'different-event'),
        operationId: _createOp,
      );
      expect(flow.state, same(pending));

      await flow.saveObserved(operationId: pending.savedCreateOperationId!);
      expect(flow.state.step, GuideStep.savedDetail);
      expect(flow.state.run, GuideRun.active);
      expect(flow.state.createdEventId, _eventId);
      expect(flow.state.serverRevision, 1);
      await flow.detailAcknowledged();
      expect(flow.state.step, GuideStep.queryMic);
      expect(flow.state.errorCode, isNull);
    });
  }

  test('only a matching live context and legal operation receive a permit',
      () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);
    expect((await flow.authorize('intro')).reasonCode, 'wrong_phase');
    await flow.createSpeech();
    expect(
      (await flow.authorize(
        'wrong-kind',
        flow.context(kind: GuideChargeKind.voiceConversation),
      ))
          .reasonCode,
      'wrong_phase',
    );
    expect(
      (await flow.authorize('wrong-uid', flow.context(uid: 'other')))
          .reasonCode,
      'stale_context',
    );
    expect(
      (await flow.authorize(
        'wrong-session',
        flow.context(sessionId: 'other'),
      ))
          .reasonCode,
      'stale_context',
    );
    expect(
      (await flow.authorize(
        'wrong-version',
        flow.context(version: 'other'),
      ))
          .reasonCode,
      'stale_context',
    );

    final access = await flow.authorize('parse');
    expect(access.status, GuideAccessStatus.granted);
    expect(access.permit?.grantId, 'local:parse');
    expect(access.permit?.uid, _uid);
    expect(access.permit?.sessionId, flow.state.sessionId);
    expect(access.permit?.operationId, 'parse');
    expect(access.permit?.kind, GuideChargeKind.scheduleParse);
    expect(access.permit?.operation, GuideOperation.createParse);
    expect(
        access.permit?.expiresAtUtc, flow.now.add(const Duration(minutes: 2)));
    expect(flow.boundEventReads, isEmpty);

    await flow.correctAndSave();
    expect((await flow.authorize('parse')).permit?.expiresAtUtc,
        access.permit?.expiresAtUtc);
    await flow.saveObserved();
    await flow.detailAcknowledged();
    await flow.queryMicTapped();
    flow.boundEventReads.clear();

    final query = flow.context(
      operation: GuideOperation.query,
      kind: GuideChargeKind.voiceConversation,
    );
    expect((await flow.authorize('parse', query)).reasonCode,
        'operation_replay_mismatch');
    expect((await flow.authorize('query', query)).status,
        GuideAccessStatus.granted);
    expect(flow.boundEventReads, [(_uid, _eventId), (_uid, _eventId)]);
  });

  for (final operation in [GuideOperation.query, GuideOperation.changeTime]) {
    test('${operation.name} permits require a fresh eligible bound event',
        () async {
      final flow = _Flow();
      await flow.reopen(GuideStep.intro);
      await flow.createSpeech();
      await flow.correctAndSave();
      await flow.saveObserved();
      await flow.detailAcknowledged();
      await flow.queryMicTapped();
      if (operation == GuideOperation.changeTime) await flow.queryObserved();
      flow.boundEventReads.clear();
      final context = flow.context(
        operation: operation,
        kind: GuideChargeKind.voiceConversation,
      );
      expect((await flow.authorize('first', context)).status,
          GuideAccessStatus.granted);

      final ineligibleEvents = <EventModel?>[
        null,
        _event(id: 'different-event'),
        _event().copyWith(userId: 'other-user'),
        _event().copyWith(groupEventId: 'group-event'),
        _event().copyWith(parentEventId: 'parent-event'),
        _event().copyWith(recurrenceRule: 'FREQ=DAILY'),
        _event().copyWith(externalId: 'external-event'),
        _event().copyWith(source: 'google'),
      ];
      for (final event in ineligibleEvents) {
        flow.boundEvent = event;
        final denied = await flow.authorize('first', context);
        expect(denied.status, GuideAccessStatus.denied);
        expect(denied.reasonCode, 'target_not_eligible');
        expect(denied.permit, isNull);
      }

      flow.failBoundEventRead = true;
      final unavailable = await flow.authorize('first', context);
      expect(unavailable.status, GuideAccessStatus.unavailable);
      expect(unavailable.reasonCode, 'target_read_unavailable');
      expect(unavailable.permit, isNull);

      flow.failBoundEventRead = false;
      flow.boundEvent = _event().copyWith(source: 'voice');
      expect((await flow.authorize('first', context)).status,
          GuideAccessStatus.granted);
      expect(flow.boundEventReads,
          List.filled(ineligibleEvents.length + 3, (_uid, _eventId)));
    });
  }

  // banned-ok: Fixed instants on the same Korean date across UTC midnight.
  final lateMorning = DateTime.utc(2031, 6, 12, 0, 30);
  final earlyMorning = lateMorning.subtract(const Duration(hours: 1));
  const koreaOffset = Duration(hours: 9);
  test(
    'edit preview accepts 09:30 to 08:30 on the same Korean date',
    () async {
      final flow = _Flow();
      await flow.reopen(GuideStep.intro);
      final event = _event(startAt: lateMorning);
      flow.boundEvent = event;
      await flow.createSpeech();
      await flow.correctAndSave();
      await flow.saveObserved(event: event);
      await flow.detailAcknowledged(event: event);
      await flow.queryMicTapped();
      await flow.queryObserved(event: event);
      flow.boundEventReads.clear();

      final before = flow.state;
      final savedWallTime = lateMorning.toLocal();
      final earlyWallTime = earlyMorning.toLocal();
      expect(savedWallTime.hour, 9);
      expect(earlyWallTime.hour, 8);
      expect(savedWallTime.day, earlyWallTime.day);
      expect(earlyMorning.day, isNot(lateMorning.day));
      final requested = planflowSeoulDateTimeToUtc(earlyWallTime);
      final preview = await flow.backend.advance(
        snapshot: before,
        action: GuideBackendAction.editPreview,
        requestId: 'same-korean-date-preview',
        expectedStartLocal: requested,
      );

      expect(preview.step, GuideStep.editPreview);
      expect(preview.serverRevision, before.serverRevision + 1);
      expect(preview.expectedStartAt, earlyMorning);
      expect(flow.boundEventReads, [(_uid, _eventId)]);
    },
    skip: lateMorning.toLocal().timeZoneOffset == koreaOffset &&
            earlyMorning.toLocal().timeZoneOffset == koreaOffset
        ? false
        : 'Backend date checking uses the device local timezone.',
  );

  test('edit preview rejects a new calendar date before advancing', () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);
    await flow.createSpeech();
    await flow.correctAndSave();
    await flow.saveObserved();
    await flow.detailAcknowledged();
    await flow.queryMicTapped();
    await flow.queryObserved();
    flow.boundEventReads.clear();

    final before = flow.state;
    final original = _startAt.toLocal();
    final nextMidnight =
        DateTime(original.year, original.month, original.day + 1).toUtc();
    await expectLater(
      flow.backend.advance(
        snapshot: before,
        action: GuideBackendAction.editPreview,
        requestId: 'cross-date-preview',
        expectedStartLocal: nextMidnight,
      ),
      throwsStateError,
    );
    final reply = await flow.backend.begin(
      uid: _uid,
      version: _version,
      requestId: 'verify-no-advance',
    );
    final unchanged = (reply as GuideBeginGranted).state;
    expect(unchanged.step, GuideStep.changeSpeech);
    expect(unchanged.serverRevision, before.serverRevision);
    expect(unchanged.expectedStartAt, isNull);
    expect(flow.boundEventReads, isEmpty);

    await flow.editPreview();
    expect(flow.state.step, GuideStep.editPreview);
    expect(flow.state.expectedUpdatedStartLocal, _updatedAt);
    expect(flow.boundEventReads, [(_uid, _eventId)]);
  });

  for (final (action, nextStep) in [
    (GuideBackendAction.detailAck, GuideStep.queryMic),
    (GuideBackendAction.queryReady, GuideStep.changeSpeech),
    (GuideBackendAction.editPreview, GuideStep.editPreview),
    (GuideBackendAction.updateVerified, GuideStep.updatedDetail),
  ]) {
    test('${action.name} rechecks the saved event after resume', () async {
      final flow = _Flow();
      final original = _event().copyWith(location: 'Practice place');
      flow.boundEvent = original;
      await flow.reopen(GuideStep.intro);
      await flow.createSpeech();
      await flow.correctAndSave();
      await flow.saveObserved(event: original);
      if (action != GuideBackendAction.detailAck) {
        await flow.detailAcknowledged();
        await flow.queryMicTapped();
      }
      if (action == GuideBackendAction.editPreview ||
          action == GuideBackendAction.updateVerified) {
        await flow.queryObserved();
      }
      final update = action == GuideBackendAction.updateVerified;
      if (update) await flow.editPreview();
      await flow.reopen(flow.state.step);
      flow.boundEventReads.clear();

      final before = flow.state;
      final start = _startAt.toLocal();
      final nextDate = DateTime(start.year, start.month, start.day + 1, 12);
      final current = original.copyWith(
        startAt: update ? _updatedAt : _startAt.add(const Duration(hours: 1)),
      );
      final invalidEvents = <EventModel?>[
        null,
        current.copyWith(userId: 'other-user'),
        current.copyWith(recurrenceRule: 'FREQ=DAILY'),
        current.copyWith(startAt: nextDate.toUtc()),
        current.copyWith(title: 'Renamed elsewhere'),
        current.copyWith(clearLocation: true),
        if (update) original,
      ];
      for (final (index, event) in invalidEvents.indexed) {
        flow.boundEvent = event;
        await expectLater(
          flow.backend.advance(
            snapshot: before,
            action: action,
            requestId: 'invalid-bound-event-$index',
            expectedStartLocal: action == GuideBackendAction.editPreview
                ? _updatedAt
                : before.expectedUpdatedStartLocal,
          ),
          throwsStateError,
        );
        final reply = await flow.backend.begin(
          uid: _uid,
          version: _version,
          requestId: 'verify-drift-did-not-advance-$index',
        );
        final unchanged = (reply as GuideBeginGranted).state;
        expect(unchanged.step, before.step);
        expect(unchanged.serverRevision, before.serverRevision);
        expect(unchanged.expectedStartAt, before.expectedUpdatedStartLocal);
      }

      flow.boundEvent = current;
      await switch (action) {
        GuideBackendAction.detailAck => flow.detailAcknowledged(),
        GuideBackendAction.queryReady => flow.queryObserved(),
        GuideBackendAction.editPreview => flow.editPreview(),
        GuideBackendAction.updateVerified => flow.updateObserved(),
        GuideBackendAction.bindCreated => throw StateError('Already bound'),
      };
      expect(flow.state.step, nextStep);
      expect(flow.state.serverRevision, before.serverRevision + 1);
      expect(flow.boundEventReads,
          List.filled(invalidEvents.length + 1, (_uid, _eventId)));
    });
  }

  test('concurrent and repeated authorizations share a persistent 12-op cap',
      () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);
    await flow.createSpeech();
    final otherBackend = LocalGuideBackend(
      progress: flow.progress,
      fetchBoundEvent: flow.fetchBoundEvent,
      now: () => flow.now,
    );
    final context = flow.context();

    final results = await Future.wait([
      for (var i = 0; i < 12; i++) flow.authorize('grant-$i'),
      otherBackend.authorize(context: context, operationId: 'grant-0'),
      otherBackend.authorize(context: context, operationId: 'overflow'),
    ]);

    expect(results.take(13).map((a) => a.status),
        everyElement(GuideAccessStatus.granted));
    expect(results[12].permit?.grantId, results[0].permit?.grantId);
    expect(results[12].permit?.expiresAtUtc, results[0].permit?.expiresAtUtc);
    expect(results.last.reasonCode, 'guide_operation_limit');

    SharedPreferences.resetStatic();
    await flow.reopen(GuideStep.homeMic);
    await flow.createSpeech();
    expect((await flow.authorize('grant-0')).status, GuideAccessStatus.granted);
    expect((await flow.authorize('after-restart')).reasonCode,
        'guide_operation_limit');
  });

  test('grant expires after two minutes and session renewal keeps usage',
      () async {
    final flow = _Flow();
    await flow.reopen(GuideStep.intro);
    await flow.createSpeech();
    expect((await flow.authorize('initial')).status, GuideAccessStatus.granted);
    flow.now = flow.now.add(const Duration(minutes: 2));
    expect((await flow.authorize('initial')).reasonCode, 'grant_expired');

    flow.now = flow.now.add(const Duration(minutes: 57));
    final finalMinute = await flow.authorize('last-minute');
    expect(finalMinute.permit?.expiresAtUtc,
        flow.now.add(const Duration(minutes: 1)));
    flow.now = flow.now.add(const Duration(minutes: 1));
    expect((await flow.authorize('expired-session')).reasonCode,
        'session_expired');

    await flow.reopen(GuideStep.homeMic);
    await flow.createSpeech();
    expect((await flow.authorize('initial')).reasonCode, 'grant_expired');
    expect(
        (await flow.authorize('new-grant')).status, GuideAccessStatus.granted);
    flow.now = _startAt.add(const Duration(days: 7));
    final expired = await flow.backend.begin(
      uid: _uid,
      version: _version,
      requestId: 'after-hard-deadline',
    );
    expect(expired, isA<GuideBeginFailed>());
    expect(
        (expired as GuideBeginFailed).failure.kind, GuideFailureKind.expired);
  });
}

EventModel _event({String id = _eventId, DateTime? startAt}) => EventModel(
      id: id,
      userId: _uid,
      title: 'Practice event',
      startAt: startAt ?? _startAt,
    );

class _FailNextSave implements GuideProgressStore {
  _FailNextSave(this.delegate);

  final GuideProgressStore delegate;
  bool failNext = false;

  @override
  Future<GuideSnapshot?> load({required String uid, required String version}) =>
      delegate.load(uid: uid, version: version);

  @override
  Future<void> save(GuideSnapshot snapshot) async {
    if (failNext) {
      failNext = false;
      throw StateError('Progress write failed');
    }
    await delegate.save(snapshot);
  }
}

class _Flow {
  _Flow({GuideProgressStore? progress})
      : progress = progress ?? LocalGuideProgressStore();

  final GuideProgressStore progress;
  final boundEventReads = <(String, String)>[];
  EventModel? boundEvent = _event();
  bool failBoundEventRead = false;
  DateTime now = _startAt;
  late LocalGuideBackend backend;
  late RealUiGuideCoordinator coordinator;

  GuideSnapshot get state => coordinator.state.value;

  Future<EventModel?> fetchBoundEvent(String uid, String id) async {
    boundEventReads.add((uid, id));
    if (failBoundEventRead) throw StateError('Event read failed');
    return boundEvent;
  }

  Future<void> reopen(GuideStep step, {GuideRun run = GuideRun.active}) async {
    backend = LocalGuideBackend(
      progress: progress,
      fetchBoundEvent: fetchBoundEvent,
      now: () => now,
    );
    coordinator = RealUiGuideCoordinator(
      backend: backend,
      progress: progress,
      version: _version,
    );
    await coordinator.start(uid: _uid);
    expect(state.step, step);
    expect(state.run, run);
  }

  Future<GuideSnapshot> dispatch(GuideSignal signal) =>
      coordinator.dispatch(signal);

  Future<void> createSpeech() async {
    if (state.step == GuideStep.intro) {
      await dispatch(
          IntroFinished(uid: _uid, expectedRevision: state.revision));
    }
    await dispatch(HomeMicTapped(
      uid: _uid,
      sessionId: state.sessionId,
      expectedRevision: state.revision,
    ));
    expect(state.step, GuideStep.createSpeech);
  }

  Future<void> correctAndSave() async {
    await dispatch(ParseConfirmed(
      uid: _uid,
      sessionId: state.sessionId,
      expectedRevision: state.revision,
      operationId: 'create-parse',
    ));
    expect(state.step, GuideStep.correctAndSave);
  }

  Future<GuideSnapshot> saveObserved({
    EventModel? event,
    String operationId = _createOp,
  }) =>
      dispatch(SaveObserved(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
        persistedEvent: event ?? _event(),
        operationId: operationId,
      ));

  Future<GuideSnapshot> detailAcknowledged({EventModel? event}) =>
      dispatch(DetailObserved(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
        persistedEvent: event ?? _event(),
        preparationResolved: false,
        departureResolved: false,
        setupHelpAcknowledged: true,
      ));

  Future<GuideSnapshot> queryMicTapped() => dispatch(QueryMicTapped(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
      ));

  Future<GuideSnapshot> queryObserved({EventModel? event}) =>
      dispatch(QueryObserved(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
        operationId: 'query-result',
        binding: GuideVisibleBinding(
          ordered: [event ?? _event()],
          targetEventId: event?.id ?? _eventId,
          firstIsTarget: true,
          guideRevision: state.revision,
          missingTarget: false,
          duplicateTarget: false,
          identityIssue: false,
        ),
      ));

  Future<GuideSnapshot> editPreview({EventModel? event, DateTime? startAt}) =>
      dispatch(EditPreviewObserved(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
        targetEventId: event?.id ?? _eventId,
        requestedStartLocal: startAt ?? _updatedAt,
      ));

  Future<GuideSnapshot> updateObserved({EventModel? event}) =>
      dispatch(UpdateObserved(
        uid: _uid,
        sessionId: state.sessionId,
        expectedRevision: state.revision,
        operationId: 'update-event',
        persistedEvent: event ?? _event(startAt: _updatedAt),
      ));

  GuideChargeContext context({
    String uid = _uid,
    String version = _version,
    String? sessionId,
    GuideChargeKind kind = GuideChargeKind.scheduleParse,
    GuideOperation operation = GuideOperation.createParse,
  }) =>
      GuideChargeContext(
        uid: uid,
        version: version,
        sessionId: sessionId ?? state.sessionId!,
        kind: kind,
        operation: operation,
        phase: state.step,
        revision: state.revision,
        serverRevision: state.serverRevision,
        createdEventId: state.createdEventId,
      );

  Future<GuideAccess> authorize(String id, [GuideChargeContext? charge]) =>
      backend.authorize(context: charge ?? context(), operationId: id);
}
