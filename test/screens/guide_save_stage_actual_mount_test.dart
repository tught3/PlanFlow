// Actual host + actual editor regression for the save-stage guide sequence.
//
// The synthetic three-target overlay test only proves that the overlay can
// move a hole between three anchor ids. It does NOT prove that
//   1) the REAL guide host (guide_host.dart) picks the right target for the
//      REAL editor controls,
//   2) the REAL editor advances the guide stage when the user taps the real
//      '중요한 일정으로 표시' / '강한 알림' switches, and
//   3) the cut-out (hole) is actually painted on the tapped control instead
//      of being left at a stale position.
//
// This fixture therefore mounts
//   - the REAL RealUiGuideCoachmark with a REAL RealUiGuideCoordinator that is
//     driven to GuideStep.correctAndSave, and
//   - the REAL CalendarStyleEventEditor with the REAL GuidedAnchors
//     ('confirm.critical' on the important checkbox, 'confirm.strong' on the
//     strong alarm switch, 'confirm.save' on the save button),
// and then taps the real controls in the order the guide asks for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_bubble_visibility.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:planflow/widgets/recurrence_selector.dart';

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
  _FakeBackend({this.grantPermits = false, this.createdEventId = 'created-1'});

  /// Save-stage-only fixture sometimes needs the pre-save snapshot, where no
  /// event has been created yet. Defaults to the historic value so the other
  /// save-stage tests are unchanged.
  final String? createdEventId;

  /// When true the backend approves guide quota requests, exactly like a
  /// live bound session does. The delayed-parse regression needs the real
  /// guide parse lane so the editor really stays blurred.
  final bool grantPermits;

  @override
  Future<GuideBackendState?> begin(
          {required String uid,
          required String version,
          required String requestId}) async =>
      GuideBackendState(
          sessionId: 's',
          serverRevision: 1,
          step: GuideStep.intro,
          createdEventId: createdEventId);
  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    return GuideBackendState(
        sessionId: 's',
        serverRevision: 2,
        step: action == GuideBackendAction.bindCreated
            ? GuideStep.savedDetail
            : snapshot.step,
        createdEventId: event?.id ?? snapshot.createdEventId);
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    if (!grantPermits) {
      return const GuideAccess(status: GuideAccessStatus.unavailable);
    }
    return GuideAccess(
        status: GuideAccessStatus.granted,
        permit: GuidePermit(
            grantId: 'grant-$operationId',
            uid: context.uid,
            sessionId: context.sessionId,
            operationId: operationId,
            kind: context.kind,
            operation: context.operation,
            expiresAtUtc:
                DateTime.now().toUtc().add(const Duration(minutes: 5))));
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {}
}

/// Drives the REAL coordinator to the save stage (`correctAndSave`), which is
/// the stage where the guide asks the user to press
/// important -> strong alarm -> save.
Future<RealUiGuideCoordinator> bootGuideAtCorrectAndSave({
  bool grantPermits = false,
  String? createdEventId = 'created-1',
}) async {
  final coordinator = RealUiGuideCoordinator(
      backend: _FakeBackend(
          grantPermits: grantPermits, createdEventId: createdEventId),
      progress: _FakeProgress(),
      version: 'real_ui_v1');
  var s = await coordinator.start(uid: 'u');
  s = await coordinator
      .dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
  s = await coordinator.dispatch(
      HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await coordinator.dispatch(
      CaptureStarted(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await coordinator.dispatch(ParseConfirmed(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      operationId: 'create-parse'));
  expect(s.step, GuideStep.correctAndSave);
  expect(s.run, GuideRun.active);
  return coordinator;
}

/// Binds the coordinator to the guide quota runtime, exactly like the app
/// does for a live session. The ad gates consult this binding before they
/// run their own quota path.
Object bindGuideRuntime(RealUiGuideCoordinator coordinator,
        {String uid = 'u'}) =>
    GuideQuotaRuntime.bind(coordinator, uid: uid);

/// Mirrors the real ConfirmScreen shell: the real editor, the real save
/// anchor, and the real guide host on top of it.
class _SaveStageHost extends StatefulWidget {
  const _SaveStageHost({super.key, required this.coordinator});

  final GuideCoordinator coordinator;

  @override
  State<_SaveStageHost> createState() => _SaveStageHostState();
}

class _SaveStageHostState extends State<_SaveStageHost> {
  final TextEditingController _titleController =
      TextEditingController(text: '팀장 동행방문');
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _memoController = TextEditingController();
  bool _isCritical = false;
  bool _useStrongAlarm = false;
  int saves = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          NotificationListener<ScrollNotification>(
            onNotification: guideHandleUserScrollNotification,
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Push the real editor below the fold so the guide has to
                    // scroll the real target into view, exactly like the app.
                    const SizedBox(height: 900),
                    CalendarStyleEventEditor(
                      titleController: _titleController,
                      locationController: _locationController,
                      memoController: _memoController,
                      // banned-ok: Fixed appointment fixture for the editor mount assertion.
                      startAt: DateTime(2026, 10, 20, 13),
                      // banned-ok: Fixed appointment fixture for the editor mount assertion.
                      endAt: DateTime(2026, 10, 20, 14),
                      category: '업무',
                      recurrence: const RecurrenceSelection(),
                      reminderOffset: const Duration(hours: 1),
                      isCritical: _isCritical,
                      useStrongAlarm: _useStrongAlarm,
                      initiallyExpandCriticalAlarm:
                          _isCritical || guideSaveStageActive.value,
                      onStartChanged: (_) {},
                      onEndChanged: (_) {},
                      onCategoryChanged: (_) {},
                      onRecurrenceChanged: (_) {},
                      onReminderChanged: (_) {},
                      onCriticalChanged: (value) {
                        setState(() {
                          _isCritical = value;
                          if (!value) _useStrongAlarm = false;
                        });
                      },
                      onStrongAlarmChanged: (value) {
                        setState(() => _useStrongAlarm = value);
                      },
                      onLocationPick: () {},
                      isSearchingLocation: false,
                    ),
                    const SizedBox(height: 12),
                    GuidedAnchor(
                      id: 'confirm.save',
                      registry: realUiGuideAnchorRegistry,
                      child: FilledButton(
                        onPressed: () => saves++,
                        child: const Text('일정 저장'),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ]),
            ),
          ),
          Positioned.fill(
            child: RealUiGuideCoachmark(
                coordinator: widget.coordinator, onSkip: () {}),
          ),
        ]),
      ),
    );
  }
}

/// Advances the fake clock enough for the guide host poll (100 ms) and the
/// editor reveal scroll (220 + 260 ms).
Future<void> _pumpGuide(WidgetTester tester,
    {int steps = 14, Duration step = const Duration(milliseconds: 120)}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(step);
  }
}

/// Scrolls the list down the way a user does: a real drag with several move
/// events. The guide must never scroll the list on its own, so the spotlight
/// may only appear after this happened.
Future<void> _userScrollDown(WidgetTester tester, Finder scrollable,
    {double distance = 120, int steps = 8}) async {
  final gesture = await tester.startGesture(tester.getCenter(scrollable));
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, -distance / steps));
    await tester.pump(const Duration(milliseconds: 32));
  }
  // Let the pointer rest before lifting it so the gesture does not turn into
  // a fling that would scroll past the real target.
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Scrolls with real user drags until the anchor really sits in the viewport.
Future<void> _scrollUntilAnchorVisible(
    WidgetTester tester, Finder scrollable, String anchorId) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    final viewport = tester.renderObject<RenderBox>(scrollable);
    if (realUiGuideAnchorRegistry.rectFor(anchorId, root: viewport) != null) {
      return;
    }
    await _userScrollDown(tester, scrollable);
  }
}

String _overlayTarget(WidgetTester tester) => tester
    .widget<GuidedCoachmarkOverlay>(find.byType(GuidedCoachmarkOverlay))
    .targetId;

/// The dim layer is only painted when the overlay actually has a hole, so its
/// presence proves that a cut-out was produced.
bool _dimLayerPainted(WidgetTester tester) => find
    .byWidgetPredicate((widget) =>
        widget is ColoredBox && widget.color == const Color(0x55000000))
    .evaluate()
    .isNotEmpty;

/// The hole itself: the dim path must NOT cover the target (it is cut out)
/// while it must still cover the rest of the screen.
void _expectHoleOn(WidgetTester tester, String anchorId) {
  final clipper = tester
      .widget<ClipPath>(find.descendant(
          of: find.byType(GuidedCoachmarkOverlay),
          matching: find.byType(ClipPath)))
      .clipper;
  expect(clipper, isNotNull);
  final overlayRoot =
      tester.element(find.byType(GuidedCoachmarkOverlay)).findRenderObject();
  expect(overlayRoot, isA<RenderBox>());
  final root = overlayRoot as RenderBox;
  final rect = realUiGuideAnchorRegistry.rectFor(anchorId, root: root);
  expect(rect, isNotNull, reason: 'anchor $anchorId must be registered');
  expect(rect!.isEmpty, isFalse);
  final path = clipper!.getClip(root.size);
  final center = rect.center;
  expect(
    path.contains(center),
    isFalse,
    reason: 'the cut-out must sit on $anchorId (center $center)',
  );
  expect(
    path.contains(Offset(4, 4)),
    isTrue,
    reason: 'the rest of the screen must stay dimmed',
  );
}

/// The same real editor without the guide host, used to prove that ordinary
/// editing never moves the guide stage.
class _PlainEditorHost extends StatefulWidget {
  const _PlainEditorHost();

  @override
  State<_PlainEditorHost> createState() => _PlainEditorHostState();
}

class _PlainEditorHostState extends State<_PlainEditorHost> {
  final TextEditingController _titleController =
      TextEditingController(text: '제목');
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _memoController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 900),
            CalendarStyleEventEditor(
              titleController: _titleController,
              locationController: _locationController,
              memoController: _memoController,
              // banned-ok: Fixed appointment fixture for the editor mount assertion.
              startAt: DateTime(2026, 10, 20, 13),
              // banned-ok: Fixed appointment fixture for the editor mount assertion.
              endAt: DateTime(2026, 10, 20, 14),
              category: '업무',
              recurrence: const RecurrenceSelection(),
              reminderOffset: const Duration(hours: 1),
              isCritical: false,
              useStrongAlarm: false,
              initiallyExpandCriticalAlarm: true,
              onStartChanged: (_) {},
              onEndChanged: (_) {},
              onCategoryChanged: (_) {},
              onRecurrenceChanged: (_) {},
              onReminderChanged: (_) {},
              onCriticalChanged: (_) {},
              onStrongAlarmChanged: (_) {},
              onLocationPick: () {},
              isSearchingLocation: false,
            ),
          ]),
        ),
      ),
    );
  }
}

void main() {
  setUp(() {
    guideSaveStage.value = GuideSaveStage.important;
    guideSaveStageActive.value = false;
    // The real ConfirmScreen flips this when the AI parse finished. This
    // fixture mounts the real host and the real editor only, so it starts
    // from the parsed state.
    guideConfirmReady.value = true;
    guideConfirmUserScrolled.value = false;
  });

  tearDown(() {
    guideConfirmReady.value = false;
    guideConfirmUserScrolled.value = false;
    GuideQuotaRuntime.reset();
    SupabaseClientAccess.clearOverride();
  });

  testWidgets(
      'real host + real editor: important -> strong alarm -> save are '
      'spotlighted in order and each hole follows the real control',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final coordinator = await bootGuideAtCorrectAndSave();
    await tester.pumpWidget(_SaveStageHost(coordinator: coordinator));
    await _pumpGuide(tester);

    expect(tester.takeException(), isNull);

    // --- Nothing is spotlighted before the user scrolls -----------------
    // The guide must never scroll the screen for the user, so the spotlight
    // stays away until the list is scrolled down by hand.
    expect(find.byType(GuidedCoachmarkOverlay), findsNothing,
        reason: 'the guide must not reveal a target before the user scrolls');
    expect(find.text('2/7 · 중요한 일정'), findsNothing);
    expect(_dimLayerPainted(tester), isFalse);

    final scrollable = find.byType(SingleChildScrollView);
    await _scrollUntilAnchorVisible(tester, scrollable, 'confirm.critical');
    await _pumpGuide(tester);

    // --- Stage 1: the important checkbox -------------------------------
    expect(_overlayTarget(tester), 'confirm.critical',
        reason: 'the first guide target must be the real important switch');
    expect(find.text('2/7 · 중요한 일정'), findsOneWidget,
        reason: 'the host banner must announce the important step');
    expect(find.text('중요한 일정으로 표시'), findsOneWidget);
    expect(_dimLayerPainted(tester), isTrue,
        reason: 'a hole must be painted on the important switch');
    _expectHoleOn(tester, 'confirm.critical');

    // The user presses the REAL important switch.
    await tester.tap(find.text('중요한 일정으로 표시'));
    await _pumpGuide(tester);

    expect(tester.takeException(), isNull);
    expect(guideSaveStage.value, GuideSaveStage.strong,
        reason: 'pressing the real important switch must advance the guide');
    expect(_overlayTarget(tester), 'confirm.strong',
        reason: 'the second guide target must be the real strong alarm switch');
    expect(find.text('2/7 · 강한 알람'), findsOneWidget);
    expect(find.text('강한 알람'), findsOneWidget);
    expect(_dimLayerPainted(tester), isTrue);
    _expectHoleOn(tester, 'confirm.strong');

    // The user presses the REAL strong alarm switch.
    await tester.tap(find.text('강한 알람'));
    await _pumpGuide(tester);

    expect(tester.takeException(), isNull);
    expect(guideSaveStage.value, GuideSaveStage.save,
        reason: 'pressing the real strong alarm switch must advance the guide');
    expect(_overlayTarget(tester), 'confirm.save',
        reason: 'the third guide target must be the real save button');
    expect(find.text('2/7 · 저장하기'), findsOneWidget);
    expect(_dimLayerPainted(tester), isTrue);
    _expectHoleOn(tester, 'confirm.save');

    // The user presses the REAL save button.
    await tester.tap(find.text('일정 저장'));
    await tester.pump();
    final host = tester.state<_SaveStageHostState>(find.byType(_SaveStageHost));
    expect(host.saves, 1,
        reason: 'the real save button must still be pressable');

    // Tear the tree down so the guide host poll timer does not leak.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'real editor does not advance the guide stage outside the save guide',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // No guide host is mounted, so the guide save stage is not active.
    await tester.pumpWidget(const _PlainEditorHost());
    await tester.pump();

    await tester.ensureVisible(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(guideSaveStage.value, GuideSaveStage.important,
        reason: 'ordinary editing must not move the guide stage');
  });
}
