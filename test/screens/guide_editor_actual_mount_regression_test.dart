// Actual-mount regression: the REAL EventEditScreen is mounted under a
// GuideScope bound at editPreview. initState must not touch the inherited
// GuideScope (no FlutterError), must seed the requested time, and must not
// dispatch, autosave, or write to any repository on mount.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';

/// Wall-clock contract equality: the guide's `initialGuideStartLocal` is a
/// local wall-clock value whose year/month/day/hour/minute/[second/ms/us]
/// fields must be preserved verbatim into the editor. Comparing through
/// `DateTime.==` is unsafe because the isUtc flag and microsecond offset
/// shift the backing instant; this helper pins down the field-wise
/// invariant the wall-clock fix relies on.
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
  // Capture the most recent `expectedStartLocal` observed through
  // `advance` (any action). Additive single-line observation: lets the
  // Save-driven regression assert that the dispatched
  // `expectedStartLocal` matches the editor's region-local wall-clock
  // `_startAt`, without exposing the editor's private APIs.
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
  Future<GuideBackendState?> begin(
          {required String uid,
          required String version,
          required String requestId}) async =>
      current;
  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    lastAdvanceExpectedStartLocal = expectedStartLocal;
    lastAdvanceAction = action;
    if (action == GuideBackendAction.editPreview) previewCalls++;
    if (action == GuideBackendAction.updateVerified) verifiedCalls++;
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: action == GuideBackendAction.updateVerified
            ? GuideStep.updatedDetail
            : snapshot.step,
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
      uid: 'u', sessionId: 's', expectedRevision: s.revision,
      operationId: 'create-parse'));
  final saved = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'real',
      // banned-ok: Fixed appointment fixture for the editor mount assertion.
      startAt: DateTime(2026, 10, 20, 13));
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
class _CountingRepo extends EventRepository {
  int writes = 0;
  int reads = 0;
  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    reads++;
    return null;
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
    return event;
  }
}

void main() {
  testWidgets('real EventEditScreen mounts under GuideScope at editPreview '
      'without dispatch/writes', (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final requested = DateTime(2026, 10, 20, 15);
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
        startAt: DateTime(2026, 10, 20, 13));

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
    // Direct contract assertions on the editor widget itself. The rendered
    // text checks above only prove the formatted output; this proves the
    // widget's backing fields without loosening the expectation to the
    // failing native actual (Oct 21 00:00). The wall-clock fields of the
    // requested input must reach the editor verbatim, with no second
    // instant→KST shift.
    final editorFinder = find.byType(CalendarStyleEventEditor);
    expect(editorFinder, findsOneWidget,
        reason: 'CalendarStyleEventEditor must mount under the guide anchor');
    final editor = tester.widget<CalendarStyleEventEditor>(editorFinder);
    expect(_sameWallFields(editor.startAt, requested), isTrue,
        reason:
            'editor.startAt must preserve requested wall fields '
            '(2026-10-20 15:00), without a second planflowLocal conversion');
    expect(editor.endAt, isNotNull,
        reason: 'editor.endAt must default to start+1h when no event end');
    expect(
        _sameWallFields(
            editor.endAt!, requested.add(const Duration(hours: 1))),
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
      'real EventEditScreen preserves wall fields when '
      'initialGuideStartLocal is DateTime.utc (no second planflowLocal shift)',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // Provider picks a `DateTime.utc` wall-clock value to prove the
    // contract holds even if callers hand in a UTC-flavoured instant.
    // The wall-clock fix must not convert the instant a second time.
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
        startAt: DateTime(2026, 10, 20, 13));

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
    final localRequested = DateTime(2026, 10, 20, 15);
    expect(_sameWallFields(editor.startAt, localRequested), isTrue,
        reason: 'editor.startAt wall fields must equal 2026-10-20 15:00 '
            'even when input was DateTime.utc; the fix must not run '
            'planflowLocal on an already-wall-clock contract value');
    expect(editor.endAt, isNotNull);
    expect(_sameWallFields(editor.endAt!, localRequested.add(const Duration(hours: 1))), isTrue,
        reason: 'editor.endAt wall fields must equal 2026-10-20 16:00');
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
    final requested = DateTime(2026, 10, 20, 15);
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
    expect(_sameWallFields(editor.startAt, requested), isTrue,
        reason: 'editor.startAt must equal guide wall 15:00');
    expect(editor.endAt, isNotNull,
        reason: 'editor.endAt must be reset to start+1h on a start change');
    expect(_sameWallFields(editor.endAt!, requested.add(const Duration(hours: 1))), isTrue,
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
    final bootRequested = DateTime(2026, 10, 20, 14);
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final editorSeed = DateTime(2026, 10, 20, 13);
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
    expect(_sameWallFields(editor.startAt, editorSeed), isTrue,
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

  // Save-driven regression. `_bootAtEditPreview` already routes one
  // `_FakeBackend.advance(action: editPreview, expectedStartLocal: 15)`
  // call through the coordinator's `EditPreviewObserved` case, so the
  // `lastAdvanceExpectedStartLocal` capture has the value 15 BEFORE
  // the Save tap. We therefore record the *counter* before the tap
  // (not the value) and assert the Save tap triggers exactly one
  // additional `advance` call. With denied fake-authorization and the
  // `AppEnv.isSupabaseReady == false` branch denying the *repo write*
  // path (the documented test-infra limit, see
  // `event_edit_screen_test.dart` around its line 1051–1056 comment),
  // the repo stays at zero writes even after Save.
  testWidgets(
      'real EventEditScreen Save dispatches exactly one new advance '
      'with expectedStartLocal wall fields = 15, repo.writes stays 0',
      (tester) async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed appointment fixture for the editor mount assertion.
    final requested = DateTime(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, requested);
    expect(c.state.value.step, GuideStep.editPreview);
    final before = c.state.value;
    final verifiedBefore = backend.verifiedCalls;
    var advances = 0;
    c.state.addListener(() => advances++);
    final repo = _CountingRepo();
    final owned = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed appointment fixture for the editor mount assertion.
        startAt: DateTime(2026, 10, 20, 13));

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
        reason: 'mount must not error on the Save-driven branch either');
    expect(find.byType(EventEditScreen), findsOneWidget);
    expect(find.text('저장'), findsOneWidget,
        reason: 'Save button labelled "저장" must be on screen');

    // Record the bootstrap counter BEFORE the Save tap (boot fired one
    // `advance(action: editPreview, expectedStartLocal: 15)` already).
    final previewBefore = backend.previewCalls;
    expect(previewBefore, greaterThanOrEqualTo(1),
        reason: 'sanity: boot must have dispatched at least one advance');
    // Also keep the prior wall-clock/contract checks intact:
    // - lastAdvanceExpectedStartLocal from the boot path already holds the
    //   value 15; asserting it *now* is not enough (the parent warned it
    //   would be a false pass), so we will assert the value AFTER the tap
    //   in combination with the counter delta.
    expect(_sameWallFields(backend.lastAdvanceExpectedStartLocal!,
        // banned-ok: Fixed appointment fixture for the editor mount assertion.
        DateTime(2026, 10, 20, 15)), isTrue,
        reason:
            'sanity: the boot\'s advance recorded the requested wall 15 ');

    // Tap the Save affordance. The handler path is:
    // _handleSave -> formState check -> guide policy check
    //   (GuideMutationPolicy.check on the now-fixed
    //    requestedStartLocal wall-field copy) -> _dispatchGuideEditConfirmed
    //    -> coordinator.dispatch(EditConfirmed) -> coordinator case at
    //    guide_coordinator.dart:309–316 -> _backend.advance(
    //    action: editPreview, expectedStartLocal: confirmedStartLocal).
    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 2));

    // Hard asserts — no passing the test if the counter didn't move.
    expect(tester.takeException(), isNull,
        reason: 'Save tap must not raise');
    expect(backend.previewCalls, previewBefore + 1,
        reason:
            'Save must dispatch exactly ONE additional `advance` (the one '
            'from `_dispatchGuideEditConfirmed` -> coordinator '
            '`EditConfirmed` -> `_backend.advance`). The pre-existing '
            '`previewBefore` was the bootstrap dispatch, recorded above.');
    expect(backend.lastAdvanceAction, GuideBackendAction.editPreview,
        reason: 'Save\'s advance must be `action: editPreview`');
    expect(backend.lastAdvanceExpectedStartLocal, isNotNull,
        reason: 'Save\'s advance must carry an expectedStartLocal');
    expect(
        _sameWallFields(backend.lastAdvanceExpectedStartLocal!,
            // banned-ok: Fixed appointment fixture for the editor mount assertion.
            DateTime(2026, 10, 20, 15)),
        isTrue,
        reason:
            'Save-advance expectedStartLocal wall fields must equal 15, '
            'matching the requested guide wall clock. With the pass-4 '
            '`_dispatchGuideEditConfirmed` wall-field copy and the '
            'pass-5 intent-field wall-field copy, the value flows to '
            '`_backend.advance` without an extra `planflowLocal` shift.');
    expect(advances, 1,
        reason: 'coordinator listener must fire exactly once: the '
            '`EditConfirmed` case at guide_coordinator.dart:309–316 '
            'advances `serverRevision` after `_backend.advance(...)`, '
            'which is precisely the Save-driven revision bump we want '
            'to observe');
    expect(backend.verifiedCalls, verifiedBefore,
        reason: '`updateVerified` must not fire on this Save branch');
    // Repo writes stay 0 because `_backend.authorize` is `unavailable`
    // AND the AppEnv/Supabase branch denies the post-dispatch write
    // block (documented infra limit at
    // `event_edit_screen_test.dart` line 1051–1056). The parent asked
    // for an explicit report if denial happens before Save — it does
    // for the WRITE side; the DISPATCH side (the line we care about for
    // this regression) is reached.
    expect(repo.writes, 0,
        reason:
            'denied fake-auth + non-Supabase env must keep repo writes at 0');

    // The full set of mount invariants (no-write, no-preview, no-revision,
    // same ID) still holds after the Save tap, with the one Save-driven
    // exception that's the contract: the coordinator revision must
    // bump by exactly one because `_FakeBackend.advance` returns an
    // incremented `serverRevision` and the `EditConfirmed` case at
    // guide_coordinator.dart:309–316 sets
    // `next = before.copyWith(serverRevision: r.serverRevision)`.
    final after = c.state.value;
    expect(after.revision, before.revision + 1,
        reason: 'Save-driven advance bumps `serverRevision` by exactly 1');
    expect(after.step, GuideStep.editPreview);
    expect(after.createdEventId, 'created-1');
    expect(after.expectedUpdatedStartLocal, requested);
  });
}