// Actual-mount regression: the REAL EventEditScreen is mounted under a
// GuideScope bound at editPreview. initState must not touch the inherited
// GuideScope (no FlutterError), must seed the requested time, and must not
// dispatch, autosave, or write to any repository on mount.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/pre_action_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';

/// Compares editor wall fields independently of the runner's timezone.
bool _sameWallFields(DateTime a, DateTime b) {
  return a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute &&
      a.second == b.second &&
      a.millisecond == b.millisecond &&
      a.microsecond == b.microsecond;
}

class _FakeProgress implements GuideProgressStore {
  GuideSnapshot? value;
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      value?.uid == uid ? value : null;
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    value = snapshot;
  }
}

class _FakeBackend implements GuideBackendPort {
  int previewCalls = 0;
  int verifiedCalls = 0;
  // Captures the requested instant registered by the preview advance.
  DateTime? lastAdvanceExpectedStartLocal;
  // Last action seen on `advance`, so the Save-driven regression can
  // also confirm which action was actually dispatched.
  GuideBackendAction? lastAdvanceAction;
  GuideBackendState current = const GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.intro,
      createdEventId: 'created-1');
  @override
  Future<GuideBeginResult> begin(
          {required String uid,
          required String version,
          required String requestId}) async =>
      GuideBeginGranted(current);
  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    lastAdvanceExpectedStartLocal = expectedStartLocal;
    lastAdvanceAction = action;
    if (action == GuideBackendAction.editPreview) {
      previewCalls++;
      // The backend allows edit -> preview once. A second advance is a
      // phase mismatch, even if it contains the same requested start.
      if (current.step == GuideStep.editPreview) {
        throw StateError('phase_mismatch');
      }
    }
    if (action == GuideBackendAction.updateVerified) verifiedCalls++;
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: switch (action) {
          GuideBackendAction.editPreview => GuideStep.editPreview,
          GuideBackendAction.updateVerified => GuideStep.updatedDetail,
          _ => snapshot.step,
        },
        createdEventId: snapshot.createdEventId);
    return current;
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {}
}

Future<RealUiGuideCoordinator> _bootAtEditPreview(
    _FakeBackend backend, _FakeProgress progress, DateTime expected) async {
  backend.current = GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.intro,
      createdEventId: 'created-1');
  final c = RealUiGuideCoordinator(
      backend: backend, progress: progress, version: 'real_ui_v1');
  var s = await c.start(uid: 'u');
  s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
  s = await c.dispatch(
      HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await c.dispatch(
      CaptureStarted(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  // CaptureStarted is a recognizer-open no-op; SaveObserved is only honoured
  // from correctAndSave, so the fixture must confirm the parse first.
  s = await c.dispatch(ParseConfirmed(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      operationId: 'create-parse'));
  final saved = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'real',
      // banned-ok: Fixed appointment fixture for the editor mount assertion.
      startAt: DateTime.utc(2026, 10, 20, 4));
  s = await c.dispatch(SaveObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      persistedEvent: saved,
      operationId: 'create-op'));
  final loaded = saved;
  s = await c.dispatch(DetailObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      persistedEvent: loaded,
      preparationResolved: false,
      departureResolved: false,
      setupHelpAcknowledged: true));
  // Drive query → changeSpeech → editPreview using the contract transitions.
  s = await c.dispatch(
      QueryMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  // Provide a binding with the target first; this is what the conversation
  // screen would have produced.
  final binding = GuideResultOrder.bind(guide: s, results: [loaded]);
  s = await c.dispatch(QueryObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      binding: binding,
      operationId: 'query-op'));
  s = await c.dispatch(EditPreviewObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      targetEventId: 'created-1',
      requestedStartLocal: expected));
  return c;
}

class _EmptySmartPreparationAlarmService extends SmartPreparationAlarmService {
  const _EmptySmartPreparationAlarmService();

  @override
  Future<List<PreActionModel>> listForEvent({
    required String eventId,
    required String userId,
  }) async =>
      const <PreActionModel>[];
}

class _CountingRepo extends EventRepository {
  _CountingRepo([this.current]);

  EventModel? current;
  Future<EventModel?>? updatedReadback;
  int writes = 0;
  int reads = 0;
  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    reads++;
    final stored = current;
    if (stored?.id != eventId || stored?.userId != userId) return null;
    final readback = updatedReadback;
    if (writes > 0 && readback != null) return readback;
    return stored;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    reads++;
    return [];
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    writes++;
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    writes++;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    writes++;
    return current = event;
  }

  @override
  Future<EventModel?> updateEventTimeIfUnchanged({
    required EventModel original,
    required DateTime startAt,
    required DateTime? endAt,
  }) async {
    final stored = current;
    if (stored == null ||
        stored.id != original.id ||
        stored.userId != original.userId ||
        stored.startAt != original.startAt ||
        stored.endAt != original.endAt) return null;
    return updateEvent(stored.copyWith(
        startAt: startAt, endAt: endAt, clearEndAt: endAt == null));
  }
}

void main() {
  testWidgets(
      'real EventEditScreen mounts under GuideScope at editPreview '
      'without dispatch/writes', (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final requested = DateTime.utc(2026, 10, 20, 6);
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final expectedWallTime = DateTime(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, requested);
    expect(c.state.value.step, GuideStep.editPreview);
    final before = c.state.value;
    final previewBefore = backend.previewCalls;
    final verifiedBefore = backend.verifiedCalls;
    var advances = 0;
    c.state.addListener(() => advances++);
    final repo = _CountingRepo();
    final owned = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed appointment fixture for the editor mount assertion.
        startAt: DateTime.utc(2026, 10, 20, 4));

    await tester.pumpWidget(MaterialApp(
      home: GuideScope(
        coordinator: c,
        child: EventEditScreen(
          event: owned,
          eventId: 'created-1',
          eventRepository: repo,
          initialGuideStartLocal: requested,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.byType(EventEditScreen), findsOneWidget);
    // Seeded requested time (15:00 shown), same event id retained.
    expect(owned.id, 'created-1');
    expect(find.text('오후 3:00'), findsOneWidget);
    expect(find.text('오후 4:00'), findsOneWidget);
    // Assert both rendered text and the editor's PlanFlow wall fields.
    final editorFinder = find.byType(CalendarStyleEventEditor);
    expect(editorFinder, findsOneWidget,
        reason: 'CalendarStyleEventEditor must mount under the guide anchor');
    final editor = tester.widget<CalendarStyleEventEditor>(editorFinder);
    expect(_sameWallFields(editor.startAt, expectedWallTime), isTrue);
    expect(editor.endAt, isNotNull,
        reason: 'editor.endAt must default to start+1h when no event end');
    expect(
        _sameWallFields(
            editor.endAt!, expectedWallTime.add(const Duration(hours: 1))),
        isTrue,
        reason: 'editor.endAt must equal requested + 1h by wall fields '
            '(2026-10-20 16:00)');
    final after = c.state.value;
    expect(after.revision, before.revision);
    expect(after.step, GuideStep.editPreview);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, requested);
    expect(advances, 0);
    expect(backend.previewCalls, previewBefore);
    expect(backend.verifiedCalls, verifiedBefore);
    expect(repo.writes, 0);
  });

  testWidgets(
      'real EventEditScreen converts a UTC preview across the PlanFlow day boundary',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    final requestedUtc = DateTime.utc(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, requestedUtc);
    expect(c.state.value.step, GuideStep.editPreview);
    final before = c.state.value;
    final previewBefore = backend.previewCalls;
    final verifiedBefore = backend.verifiedCalls;
    var advances = 0;
    c.state.addListener(() => advances++);
    final repo = _CountingRepo();
    final owned = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed appointment fixture for the editor mount assertion.
        startAt: DateTime.utc(2026, 10, 20, 4));

    await tester.pumpWidget(MaterialApp(
      home: GuideScope(
        coordinator: c,
        child: EventEditScreen(
          event: owned,
          eventId: 'created-1',
          eventRepository: repo,
          initialGuideStartLocal: requestedUtc,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull,
        reason: 'initState must not throw when guideStart is DateTime.utc');
    expect(find.byType(EventEditScreen), findsOneWidget);
    expect(owned.id, 'created-1',
        reason: 'same event id retained (no write/replace)');
    final editorFinder = find.byType(CalendarStyleEventEditor);
    expect(editorFinder, findsOneWidget);
    final editor = tester.widget<CalendarStyleEventEditor>(editorFinder);
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final localRequested = DateTime(2026, 10, 21);
    expect(_sameWallFields(editor.startAt, localRequested), isTrue,
        reason: '15:00 UTC is the following day at 00:00 in Korea');
    expect(editor.endAt, isNotNull);
    expect(
        _sameWallFields(
            editor.endAt!, localRequested.add(const Duration(hours: 1))),
        isTrue,
        reason: 'editor.endAt wall fields must equal 2026-10-21 01:00');
    final after = c.state.value;
    expect(after.revision, before.revision,
        reason: 'coordinator revision must not change on mount');
    expect(after.step, GuideStep.editPreview);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, requestedUtc,
        reason: 'coordinator contract preserves the input as-given');
    expect(advances, 0, reason: 'no listener should fire on mount');
    expect(backend.previewCalls, previewBefore,
        reason: 'mount must not dispatch editPreview');
    expect(backend.verifiedCalls, verifiedBefore,
        reason: 'mount must not dispatch updateVerified');
    expect(repo.writes, 0, reason: 'mount must not write the repository');
  });

  // Case A: canonical event stored as UTC instants; initState converts
  // them through `planflowLocal` to KST 13/14; the guide seed at 15:00
  // is treated as an ordinary start edit and resets the end to start+1h
  // (16:00 KST). Without this the editor would surface end 14 below the
  // new start 15 on mount.
  testWidgets(
      'real EventEditScreen resets end to start+1h when canonical UTC '
      'event is guide-seeded to a new start (15:00 over 13–14 KST)',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final requested = DateTime.utc(2026, 10, 20, 6);
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final expectedWallTime = DateTime(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, requested);
    expect(c.state.value.step, GuideStep.editPreview);
    final before = c.state.value;
    final previewBefore = backend.previewCalls;
    final verifiedBefore = backend.verifiedCalls;
    var advances = 0;
    c.state.addListener(() => advances++);
    final repo = _CountingRepo();
    // Canonical event kept as UTC instants — KST 13:00 / 14:00 are the
    // resulting wall-clock values after initState calls planflowLocal.
    final owned = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        startAt: DateTime.utc(2026, 10, 20, 4),
        endAt: DateTime.utc(2026, 10, 20, 5));

    await tester.pumpWidget(MaterialApp(
      home: GuideScope(
        coordinator: c,
        child: EventEditScreen(
          event: owned,
          eventId: 'created-1',
          eventRepository: repo,
          initialGuideStartLocal: requested,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull,
        reason: 'initState must accept canonical UTC inputs without error');
    expect(find.byType(EventEditScreen), findsOneWidget);
    expect(owned.id, 'created-1');
    final editorFinder = find.byType(CalendarStyleEventEditor);
    expect(editorFinder, findsOneWidget);
    final editor = tester.widget<CalendarStyleEventEditor>(editorFinder);
    // Guide wall is 15:00; helper treats the 13→15 change as an ordinary
    // start edit, so end is reset to 16:00 (NOT the stale KST 14 from the
    // canonical event endAt).
    expect(_sameWallFields(editor.startAt, expectedWallTime), isTrue,
        reason: 'editor.startAt must equal guide wall 15:00');
    expect(editor.endAt, isNotNull,
        reason: 'editor.endAt must be reset to start+1h on a start change');
    expect(
        _sameWallFields(
            editor.endAt!, expectedWallTime.add(const Duration(hours: 1))),
        isTrue,
        reason: 'editor.endAt must equal 16:00 KST (15+1h), not the stale '
            'canonical 14:00 — the same end-prefill fix as onStartChanged');
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    expect(_sameWallFields(editor.endAt!, DateTime(2026, 10, 20, 14)), isFalse,
        reason: 'editor.endAt must NOT equal the stale canonical 14:00');
    final after = c.state.value;
    expect(after.revision, before.revision);
    expect(after.step, GuideStep.editPreview);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, requested);
    expect(advances, 0);
    expect(backend.previewCalls, previewBefore);
    expect(backend.verifiedCalls, verifiedBefore);
    expect(repo.writes, 0);
  });

  // Case B: same-start prefill retains the valid original end unchanged.
  // initState converts canonical UTC 04 → KST 13:00; the editor seed we
  // pass into `initialGuideStartLocal` is the same wall-clock 13:00, so
  // inside `_applyGuideInitialStartIfAny` previousStart == newStart and
  // the helper returns currentEnd untouched (KST 15:00 here). The boot
  // helper is driven with a *different* guide-requested start (14:00) so
  // the coordinator's `requestedStartLocal != originalStartLocal` gate is
  // satisfied — it is purely an artefact of the dispatch contract, the
  // editor seed itself stays at the unchanged canonical start.
  testWidgets(
      'real EventEditScreen retains valid original end when guide seed '
      'matches the canonical start (13:00 KST, end 15:00 preserved)',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final bootRequested = DateTime.utc(2026, 10, 20, 5);
    final editorSeed = DateTime.utc(2026, 10, 20, 4);
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final expectedWallTime = DateTime(2026, 10, 20, 13);
    final c = await _bootAtEditPreview(backend, progress, bootRequested);
    expect(c.state.value.step, GuideStep.editPreview);
    final before = c.state.value;
    final previewBefore = backend.previewCalls;
    final verifiedBefore = backend.verifiedCalls;
    var advances = 0;
    c.state.addListener(() => advances++);
    final repo = _CountingRepo();
    // Canonical UTC start/end: KST 13:00 / 15:00 after initState.
    final owned = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        startAt: DateTime.utc(2026, 10, 20, 4),
        endAt: DateTime.utc(2026, 10, 20, 6));

    await tester.pumpWidget(MaterialApp(
      home: GuideScope(
        coordinator: c,
        child: EventEditScreen(
          event: owned,
          eventId: 'created-1',
          eventRepository: repo,
          initialGuideStartLocal: editorSeed,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.byType(EventEditScreen), findsOneWidget);
    expect(owned.id, 'created-1');
    final editorFinder = find.byType(CalendarStyleEventEditor);
    expect(editorFinder, findsOneWidget);
    final editor = tester.widget<CalendarStyleEventEditor>(editorFinder);
    // same-start prefill → end is preserved exactly (KST 15:00, NOT 14:00).
    expect(_sameWallFields(editor.startAt, expectedWallTime), isTrue,
        reason: 'editor.startAt must equal the unchanged guide seed 13:00 KST; '
            'previousStart (initState-set KST 13) == newStart (editorSeed)');
    expect(editor.endAt, isNotNull,
        reason: 'editor.endAt must retain the valid original end');
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    expect(_sameWallFields(editor.endAt!, DateTime(2026, 10, 20, 15)), isTrue,
        reason: 'editor.endAt must keep the canonical 15:00 exactly; helper '
            'returns currentEnd when previousStart == newStart');
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    expect(_sameWallFields(editor.endAt!, DateTime(2026, 10, 20, 14)), isFalse,
        reason: 'editor.endAt must NOT have been reset to start+1h on '
            'same-start prefill');
    final after = c.state.value;
    expect(after.revision, before.revision);
    expect(after.step, GuideStep.editPreview);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, bootRequested,
        reason: 'coordinator stores the bootRequested value used at dispatch, '
            'which differs from the editor seed by design');
    expect(advances, 0);
    expect(backend.previewCalls, previewBefore);
    expect(backend.verifiedCalls, verifiedBefore);
    expect(repo.writes, 0);
  });

  testWidgets('Save writes once and advances only after detail readback',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    final requested = DateTime.utc(2026, 10, 20, 6);
    final c = await _bootAtEditPreview(backend, progress, requested);
    final before = c.state.value;
    expect(before.step, GuideStep.editPreview);
    final previewBefore = backend.previewCalls;
    final verifiedBefore = backend.verifiedCalls;
    expect(previewBefore, 1);
    expect(backend.lastAdvanceAction, GuideBackendAction.editPreview);
    expect(backend.lastAdvanceExpectedStartLocal, requested);
    var advances = 0;
    c.state.addListener(() => advances++);
    final owned = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'real',
      startAt: DateTime.utc(2026, 10, 20, 4),
    );
    final detailReadback = Completer<EventModel?>();
    final repo = _CountingRepo(owned)..updatedReadback = detailReadback.future;
    authProvider.setUser('u');
    addTearDown(() => authProvider.setUser(null));
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/edit',
          builder: (_, __) => EventEditScreen(
            event: owned,
            eventId: owned.id,
            eventRepository: repo,
            initialGuideStartLocal: requested,
          ),
        ),
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, state) => EventDetailScreen(
            event: state.extra as EventModel,
            eventId: state.pathParameters['eventId'],
            eventRepository: repo,
            smartPreparationAlarmService:
                const _EmptySmartPreparationAlarmService(),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(GuideScope(
      coordinator: c,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(EventEditScreen), findsOneWidget);
    expect(repo.writes, 0);
    expect(advances, 0);

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(EventDetailScreen), findsOneWidget);
    expect(find.text('변경된 시간 확인'), findsNothing);
    expect(backend.previewCalls, previewBefore);
    expect(backend.lastAdvanceAction, GuideBackendAction.editPreview);
    expect(backend.lastAdvanceExpectedStartLocal, requested);
    expect(backend.verifiedCalls, verifiedBefore);
    expect(advances, 1);
    expect(repo.writes, 1);
    expect(repo.current?.id, 'created-1');
    expect(repo.current?.startAt, requested);
    expect(repo.current?.endAt, requested.add(const Duration(hours: 1)));

    final awaitingReadback = c.state.value;
    expect(awaitingReadback.revision, before.revision + 1);
    expect(awaitingReadback.serverRevision, before.serverRevision);
    expect(awaitingReadback.step, GuideStep.editPreview);
    expect(awaitingReadback.createdEventId, 'created-1');
    expect(awaitingReadback.expectedUpdatedStartLocal, requested);

    detailReadback.complete(repo.current);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('변경된 시간 확인'), findsOneWidget);
    expect(backend.previewCalls, previewBefore);
    expect(backend.verifiedCalls, verifiedBefore + 1);
    expect(backend.lastAdvanceAction, GuideBackendAction.updateVerified);
    expect(advances, 2);
    expect(repo.writes, 1);
    final after = c.state.value;
    expect(after.revision, before.revision + 2);
    expect(after.serverRevision, before.serverRevision! + 1);
    expect(after.step, GuideStep.updatedDetail);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, requested);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
