import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/safe_prefs.dart';
import '../../core/startup_route_gate.dart';
import '../../widgets/guided_coachmark_overlay.dart';
import '../../widgets/guided_anchor.dart';
import 'guide_bubble_visibility.dart';
import 'guide_contract.dart';
import 'voice_correction_example.dart';
import 'guide_providers.dart';
import 'guide_scope.dart';
import 'guide_route_recovery.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';
import '../../data/repositories/event_repository.dart';
import '../../screens/voice/voice_input_screen.dart';
import '../../screens/voice/voice_conversation_screen.dart';
import 'package:go_router/go_router.dart';

/// The scope must wrap the root navigator, not an individual Shell route.
/// Backend and quota-runtime bindings are injected by the application owner.
class RootGuideScope extends ConsumerStatefulWidget {
  const RootGuideScope(
      {super.key,
      required this.uid,
      required this.child,
      required this.bindRuntime,
      required this.unbindRuntime});
  final String? uid;
  final Widget child;
  final Object Function(GuideCoordinator) bindRuntime;
  final void Function(Object) unbindRuntime;
  @override
  ConsumerState<RootGuideScope> createState() => _RootGuideScopeState();
}

class _RootGuideScopeState extends ConsumerState<RootGuideScope>
    with WidgetsBindingObserver {
  GuideCoordinator? _coordinator;
  Object? _token;
  Object _epoch = Object();
  String? _error;
  bool _sessionOnlyRecovery = false;
  _SessionOnlyGuideProgressStore? _recoveryProgress;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    guideListeningBubbleHidden.addListener(_onListeningBubbleChanged);
    guideConfirmUserScrolled.addListener(_onListeningBubbleChanged);
    guideConfirmReady.addListener(_onListeningBubbleChanged);
    _start();
  }

  /// 말하는 동안에는 음성 원문이 보이도록 안내 말풍선을 숨긴다.
  void _onListeningBubbleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RootGuideScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _start();
  }

  void _start() {
    _epoch = Object();
    final epoch = _epoch;
    final retryFactory = _coordinator == null && _error != null;
    final wasRecovery = _sessionOnlyRecovery;
    final old = _coordinator;
    if (old != null) old.suspend(GuidePauseReason.interrupted);
    if (_token case final Object token) widget.unbindRuntime(token);
    _token = null;
    _coordinator = null;
    _error = null;
    _sessionOnlyRecovery = false;
    _recoveryProgress = null;
    final uid = widget.uid;
    if (uid == null || uid.isEmpty) return;
    startupRouteGate.beginGuideChoice(uid);
    // Bind synchronously before descendants can expose chargeable controls.
    try {
      // Reuse a live coordinator so start() invalidates older same-UID work.
      if (retryFactory || wasRecovery) {
        ref.invalidate(realUiGuideCoordinatorProvider);
      }
      final coordinator = ref.read(realUiGuideCoordinatorProvider);
      _coordinator = coordinator;
      // banned-ok: Stores the guide binding handle.
      _token = widget.bindRuntime(coordinator);
    } catch (_) {
      _error = '안내를 불러오지 못했습니다.';
    }
    Future<void>(() async {
      try {
        final coordinator = _coordinator;
        if (!identical(epoch, _epoch) ||
            coordinator == null ||
            _error != null) {
          return;
        }
        await coordinator.start(uid: uid);
        if (!identical(epoch, _epoch) || !mounted) return;
        if (coordinator.state.value.run == GuideRun.terminal &&
            await GuideSyncChoiceStore().isClosed(uid)) {
          if (!identical(epoch, _epoch) || !mounted) return;
          startupRouteGate.closeGuideChoice(uid);
        }
      } catch (_) {
        if (identical(epoch, _epoch)) _error = '안내를 불러오지 못했습니다.';
      }
      if (mounted && identical(epoch, _epoch)) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a real background transition may pause the guide. Android emits
    // `inactive` while a permission dialog is on top of a still-visible,
    // still-interactive app, so pausing there would strand an active ASR run.
    // `resumed` stays a no-op: recovery is always an explicit user action.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _coordinator?.suspend(GuidePauseReason.background);
    }
  }

  @override
  void dispose() {
    _epoch = Object();
    guideListeningBubbleHidden.removeListener(_onListeningBubbleChanged);
    guideConfirmUserScrolled.removeListener(_onListeningBubbleChanged);
    guideConfirmReady.removeListener(_onListeningBubbleChanged);
    WidgetsBinding.instance.removeObserver(this);
    _coordinator?.suspend(GuidePauseReason.routeLost);
    if (_token case final Object token) widget.unbindRuntime(token);
    super.dispose();
  }

  void _skipThisSession() {
    final uid = widget.uid;
    if (uid == null || uid.isEmpty) return;
    // This explicit escape does not claim a durable completion or a free grant.
    _epoch = Object();
    _coordinator?.suspend(GuidePauseReason.interrupted);
    if (_token case final Object token) {
      try {
        widget.unbindRuntime(token);
      } catch (_) {
        setState(() => _error = '안내 연결을 정리하지 못했어요. 다시 시도해주세요.');
        return;
      }
    }
    _token = null;
    final fallback = _SessionOnlySkippedGuideCoordinator(uid);
    startupRouteGate.beginGuideChoice(uid);
    setState(() {
      _coordinator = fallback;
      _recoveryProgress = _SessionOnlyGuideProgressStore(fallback.state.value);
      _sessionOnlyRecovery = true;
      _error = null;
    });
  }

  Future<void> _retryGuide() async {
    final coordinator = _coordinator;
    if (coordinator == null || _error != null) {
      setState(_start);
      return;
    }
    final epoch = _epoch;
    final uid = widget.uid;
    if (uid == null) return;
    try {
      final current = coordinator.state.value;
      if (current.uid != uid || current.sessionId == null) {
        await coordinator.start(uid: uid);
      } else {
        await coordinator.dispatch(ResumeRequested(
            uid: uid,
            sessionId: current.sessionId!,
            expectedRevision: current.revision));
      }
    } catch (_) {
      if (mounted && identical(epoch, _epoch)) {
        setState(() => _error = '안내를 다시 시작하지 못했어요.');
      }
    }
  }

  Future<void> _skipGuide() async {
    final coordinator = _coordinator;
    if (coordinator == null ||
        _error != null ||
        coordinator.state.value.uid != widget.uid) {
      _skipThisSession();
      return;
    }
    final epoch = _epoch;
    try {
      await coordinator.terminate(GuideExit.skip);
    } catch (_) {
      if (mounted && identical(epoch, _epoch)) {
        setState(() => _error = '건너뛰기를 저장하지 못했어요. 이번만 건너뛸 수 있어요.');
      }
    }
  }

  Widget _loadingNotice() => const Positioned.fill(
      child: ColoredBox(
          key: ValueKey('guide-loading-barrier'),
          color: Color(0x55000000),
          child: Center(child: CircularProgressIndicator())));

  Widget _recoveryNotice({required bool fatal}) => Positioned.fill(
          child: Stack(fit: StackFit.expand, children: [
        const ModalBarrier(dismissible: false, color: Color(0x55000000)),
        SafeArea(
            child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Material(
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(fatal
                                      ? '안내를 불러오지 못했어요. 무료 횟수를 쓰지 않고 다시 시도하거나 이번만 안내를 건너뛸 수 있어요.'
                                      : '안내가 잠시 멈췄어요. 다시 시도하거나 건너뛸 수 있어요.'),
                                  Wrap(children: [
                                    TextButton(
                                        key: const ValueKey('guide-retry'),
                                        onPressed: _retryGuide,
                                        child: const Text('다시 시도')),
                                    TextButton(
                                        key: ValueKey(fatal
                                            ? 'guide-session-skip'
                                            : 'guide-skip'),
                                        onPressed: fatal
                                            ? _skipThisSession
                                            : _skipGuide,
                                        child: Text(
                                            fatal ? '이번만 안내 건너뛰기' : '안내 건너뛰기')),
                                  ])
                                ]))))))
      ]));

  @override
  Widget build(BuildContext context) {
    final coordinator = _coordinator;
    if (widget.uid == null || widget.uid!.isEmpty) return widget.child;
    Widget content;
    if (coordinator == null) {
      content = Stack(fit: StackFit.expand, children: [
        IgnorePointer(child: ExcludeFocus(child: widget.child)),
        if (_error == null) _loadingNotice() else _recoveryNotice(fatal: true),
      ]);
    } else {
      content = GuideScope(
          coordinator: coordinator,
          child: ValueListenableBuilder<GuideSnapshot>(
              valueListenable: coordinator.state,
              builder: (context, s, _) {
                final waiting = s.uid != widget.uid && _error == null;
                final recovery = _error != null ||
                    (s.run != GuideRun.terminal &&
                        (s.run != GuideRun.active || s.errorCode != null));
                final blocked = waiting || recovery;
                final coaching = !blocked &&
                    s.run == GuideRun.active &&
                    s.step != GuideStep.intro &&
                    s.step != GuideStep.syncChoice;
                return Stack(fit: StackFit.expand, children: [
                  IgnorePointer(
                      ignoring: blocked,
                      child: ExcludeFocus(
                          excluding: blocked, child: widget.child)),
                  if (coaching)
                    RealUiGuideCoachmark(
                        key: ObjectKey(coordinator),
                        coordinator: coordinator,
                        onSkip: () {
                          unawaited(_skipGuide());
                        }),
                  if (waiting) _loadingNotice(),
                  if (!waiting && recovery)
                    _recoveryNotice(fatal: _error != null),
                ]);
              }));
    }
    final progress = _recoveryProgress;
    if (_sessionOnlyRecovery && coordinator != null && progress != null) {
      return ProviderScope(overrides: [
        realUiGuideCoordinatorProvider.overrideWithValue(coordinator),
        realUiGuideProgressStoreProvider.overrideWithValue(progress),
      ], child: content);
    }
    return content;
  }
}

/// Explicit, in-memory recovery only. It never grants an exempt operation.
class _SessionOnlySkippedGuideCoordinator implements GuideCoordinator {
  _SessionOnlySkippedGuideCoordinator(String uid)
      : _state = ValueNotifier(GuideSnapshot(
            uid: uid,
            version: 'real_ui_v1',
            revision: 0,
            serverRevision: 0,
            step: GuideStep.skipped,
            run: GuideRun.terminal,
            calendarSyncHeld: true));
  final ValueNotifier<GuideSnapshot> _state;
  @override
  ValueListenable<GuideSnapshot> get state => _state;
  @override
  Future<GuideSnapshot> start({required String uid}) async {
    if (uid != _state.value.uid) throw StateError('Recovery UID changed');
    return _state.value;
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => _state.value;
  @override
  void suspend(GuidePauseReason reason) {}
  @override
  Future<void> terminate(GuideExit exit) async {}
  @override
  Future<GuideAccess> authorize(
          {required GuideChargeContext context,
          required String operationId}) async =>
      const GuideAccess(
          status: GuideAccessStatus.denied,
          reasonCode: 'guide_session_skipped');
}

class _SessionOnlyGuideProgressStore implements GuideProgressStore {
  _SessionOnlyGuideProgressStore(this._snapshot);
  GuideSnapshot _snapshot;
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      uid == _snapshot.uid && version == _snapshot.version ? _snapshot : null;
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    if (snapshot.uid != _snapshot.uid ||
        snapshot.version != _snapshot.version) {
      throw StateError('Recovery progress scope changed');
    }
    _snapshot = snapshot;
  }
}

class GuideSyncChoiceStore {
  String key(String uid) => 'guide_sync_choice:real_ui_v1:$uid';
  Future<bool> isClosed(String uid) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) throw StateError('Sync choice storage unavailable');
    return prefs.getBool(key(uid)) == true;
  }

  Future<void> close(String uid) async {
    final prefs = await tryGetPrefs();
    if (prefs == null ||
        !await prefs.setBool(key(uid), true) ||
        prefs.getBool(key(uid)) != true) {
      throw StateError('Sync choice readback failed');
    }
  }
}

/// Mount inside the root navigator's overlay. No blind Next action is offered.
/// ModalRoute/current-target checks hide coachmarks under dialogs and pickers.
class RealUiGuideCoachmark extends StatefulWidget {
  const RealUiGuideCoachmark(
      {super.key, required this.coordinator, this.onSkip});
  final GuideCoordinator coordinator;
  final VoidCallback? onSkip;

  /// Upper bound for reading the saved event when resuming the guide. A normal
  /// single-row fetch finishes in well under a second; 15s tolerates a slow
  /// mobile connection while keeping the retry button from staying disabled.
  /// Tests may shorten it.
  @visibleForTesting
  static Duration boundReadTimeout = const Duration(seconds: 15);
  @override
  State<RealUiGuideCoachmark> createState() => _RealUiGuideCoachmarkState();
}

class _RealUiGuideCoachmarkState extends State<RealUiGuideCoachmark> {
  GuideCoordinator get coordinator => widget.coordinator;
  Timer? _routeCheck;
  bool _recoveringRoute = false;
  String? _routeRecoveryError;

  bool _atHome() {
    if (!mounted) return false;
    final home = _resolveAnchor('home.mic').context;
    return _targetIsCurrent(home);
  }

  Future<void> _continueBoundGuide() async {
    if (_recoveringRoute || !_atHome()) return;
    final capturedCoordinator = coordinator;
    setState(() {
      _recoveringRoute = true;
      _routeRecoveryError = null;
    });
    try {
      final recovery = await GuideRouteRecovery.load(
          coordinator: capturedCoordinator,
          currentUid: () => authProvider.userId,
          attachedToRoute: () =>
              mounted &&
              identical(coordinator, capturedCoordinator) &&
              _atHome(),
          read: (uid, id) async {
            final event = await EventRepository.supabase()
                .fetchEvent(id, userId: uid)
                .timeout(RealUiGuideCoachmark.boundReadTimeout);
            return event == null ? [] : [event];
          });
      if (!mounted || !_atHome()) return;
      if (recovery == null ||
          !recovery.isCurrent(coordinator, authProvider.userId)) {
        // Still on home but nothing was resumed: say so and keep retry open.
        setState(() => _routeRecoveryError =
            '안내를 이어가지 못했어요. 저장한 일정은 그대로예요. 다시 시도해주세요.');
        return;
      }
      final routeContext = _resolveAnchor('home.mic').context!;
      if (!routeContext.mounted) {
        return;
      }
      if (recovery.snapshot.step == GuideStep.queryMic ||
          recovery.snapshot.step == GuideStep.querySpeech) {
        // Explicit false bypasses the user's normal auto-start preference.
        unawaited(Navigator.of(routeContext).push(MaterialPageRoute<void>(
            settings: const RouteSettings(name: AppRoutes.voice),
            builder: (_) => const VoiceInputScreen(autoStartOverride: false))));
      } else if (recovery.restoresResults) {
        unawaited(Navigator.of(routeContext).push(MaterialPageRoute<void>(
            settings: const RouteSettings(name: AppRoutes.voiceConversation),
            builder: (_) =>
                VoiceConversationScreen(guideRouteRecovery: recovery))));
      } else if (recovery.snapshot.step == GuideStep.savedDetail) {
        routeContext.go(recovery.location);
      } else {
        unawaited(routeContext.push(recovery.location,
            extra: recovery.snapshot.step == GuideStep.editPreview
                ? <String, dynamic>{
                    'event': recovery.event,
                    'initialGuideStartLocal':
                        recovery.snapshot.expectedUpdatedStartLocal
                  }
                : recovery.event));
      }
    } catch (_) {
      if (mounted && _atHome()) {
        setState(() => _routeRecoveryError =
            coordinator.state.value.step == GuideStep.editPreview &&
                    coordinator.state.value.expectedUpdatedStartLocal == null
                ? '변경할 시간 정보가 남아 있지 않아요. 같은 단계의 미리보기 복구가 필요해요. 저장하지 않았어요.'
                : '저장한 일정을 안전하게 확인하지 못했어요. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _recoveringRoute = false);
    }
  }

  Object? _lastTarget;
  String? _lastId;
  bool? _lastCurrent;
  bool? _lastVisible;
  Rect? _lastRect;
  // 저장 단계에 들어올 때마다 '중요한 일정'부터 다시 시작한다. 화면이
  // 이전 안내 단계에 머물러 있어도 새 안내가 저장 단계의 첫 컷아웃을
  // 건너뛰지 않게 한다.
  bool _saveStageResetDone = false;
  @override
  void initState() {
    super.initState();
    final initial = coordinator.state.value;
    _saveStageResetDone = initial.run == GuideRun.active &&
        initial.step == GuideStep.correctAndSave;
    if (_saveStageResetDone) {
      guideSaveStage.value = GuideSaveStage.important;
    }
    // 저장 단계(중요한 일정 → 강한 알람 → 저장)는 사용자가 실제 화면을
    // 누를 때마다 대상이 바뀌므로, 그때마다 다시 그려야 구멍이 이동한다.
    guideSaveStage.addListener(_onSaveStageChanged);
    // 저장 화면의 파싱 완료/사용자 스크롤 신호는 안내를 다시 그려야 한다.
    guideConfirmReady.addListener(_onConfirmGateChanged);
    guideConfirmUserScrolled.addListener(_onConfirmGateChanged);
    coordinator.state.addListener(_onGuideStateForSaveStage);
    // Registry mounting and Navigator popup changes do not emit guide signals.
    _routeCheck = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final snapshot = coordinator.state.value;
      // correctAndSave 단계에는 일반 대상 ID가 없으므로 저장 단계 대상을
      // 따로 본다. '중요한 일정' → '강한 알림'으로 넘어가면 앵커가 나중에
      // 등록되므로, 여기서 다시 그리지 않으면 구멍이 옛 자리에 남는다.
      final id = _targetId(snapshot) ?? _saveStageTargetId(snapshot);
      final target = id == null ? null : _resolveAnchor(id).context;
      final current = _targetIsCurrent(target);
      final visible = current && _targetIsVisible(target);
      // 앵커가 같은 화면에 있어도 스크롤로 위치가 바뀌면 구멍이 옛 자리에
      // 남는다. 대상 영역이 실제로 움직였는지도 함께 지켜본다.
      final rect = id == null ? null : _targetRectInHost(id);
      if (!identical(target, _lastTarget) ||
          current != _lastCurrent ||
          visible != _lastVisible ||
          rect != _lastRect ||
          id != _lastId) {
        _lastTarget = target;
        _lastId = id;
        _lastCurrent = current;
        _lastVisible = visible;
        _lastRect = rect;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _routeCheck?.cancel();
    coordinator.state.removeListener(_onGuideStateForSaveStage);
    guideSaveStage.removeListener(_onSaveStageChanged);
    guideConfirmReady.removeListener(_onConfirmGateChanged);
    guideConfirmUserScrolled.removeListener(_onConfirmGateChanged);
    super.dispose();
  }

  void _onSaveStageChanged() {
    if (mounted) setState(() {});
  }

  /// 파싱 완료·사용자 스크롤 상태가 바뀌면 스포트라이트를 다시 그린다.
  void _onConfirmGateChanged() {
    if (mounted) setState(() {});
  }

  /// 안내가 저장 단계에 새로 진입할 때만 단계를 초기화한다. 같은 저장
  /// 화면에서 사용자가 토글을 누르는 동안에는 되돌리지 않는다.
  void _onGuideStateForSaveStage() {
    if (!mounted) return;
    final s = coordinator.state.value;
    final active =
        s.run == GuideRun.active && s.step == GuideStep.correctAndSave;
    if (!active) {
      _saveStageResetDone = false;
      return;
    }
    if (_saveStageResetDone) return;
    _saveStageResetDone = true;
    guideSaveStage.value = GuideSaveStage.important;
  }

  /// 저장 단계에서 강조할 실제 화면 대상(앵커 ID).
  String? _saveStageTargetId(GuideSnapshot s) {
    if (s.run != GuideRun.active || s.step != GuideStep.correctAndSave) {
      return null;
    }
    return switch (guideSaveStage.value) {
      GuideSaveStage.important => 'confirm.critical',
      GuideSaveStage.strong => 'confirm.strong',
      GuideSaveStage.save => 'confirm.save',
    };
  }

  /// 앵커가 지금 화면 어디에 있는지(호스트 좌표). 스크롤로 움직였는지
  /// 확인하기 위해 사용한다.
  Rect? _targetRectInHost(String id) {
    final root = context.findRenderObject();
    if (root is! RenderBox || !root.attached || !root.hasSize) return null;
    try {
      return _resolveAnchor(id).registry.rectFor(id, root: root);
    } on FlutterError {
      return null;
    }
  }

  /// 실제 화면 앵커를 찾는다.
  ///
  /// 앵커는 화면마다 등록 레지스트리가 다를 수 있다(안내 전용 레지스트리/
  /// 기본 공용 레지스트리). 안내가 화면을 놓치지 않도록 두 곳을 모두 확인하고,
  /// 실제로 앵커가 등록된 레지스트리를 함께 돌려준다(구멍을 그릴 때 같은
  /// 레지스트리가 필요하기 때문).
  ({GuidedAnchorRegistry registry, BuildContext? context}) _resolveAnchor(
      String id) {
    final guided = realUiGuideAnchorRegistry.keyFor(id)?.currentContext;
    if (guided != null) {
      return (registry: realUiGuideAnchorRegistry, context: guided);
    }
    final shared = GuidedAnchorRegistry.shared.keyFor(id)?.currentContext;
    if (shared != null) {
      return (registry: GuidedAnchorRegistry.shared, context: shared);
    }
    return (registry: realUiGuideAnchorRegistry, context: null);
  }

  bool _targetIsCurrent(BuildContext? target) {
    if (target == null ||
        !target.mounted ||
        ModalRoute.of(target)?.isCurrent != true ||
        !TickerMode.valuesOf(target).enabled) {
      return false;
    }
    var offstage = false;
    target.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) {
        offstage = true;
        return false;
      }
      return true;
    });
    return !offstage;
  }

  bool _targetIsVisible(BuildContext? target) {
    if (target == null || !target.mounted) return false;
    final root = context.findRenderObject();
    final object = target.findRenderObject();
    if (root is! RenderBox ||
        object is! RenderBox ||
        !root.attached ||
        !root.hasSize ||
        !object.attached ||
        !object.hasSize ||
        object.size.isEmpty) {
      return false;
    }
    try {
      var visible = MatrixUtils.transformRect(
          object.getTransformTo(root), Offset.zero & object.size);
      visible = visible.intersect(Offset.zero & root.size);
      for (RenderObject? node = object.parent;
          node != null;
          node = node.parent) {
        if (node is RenderAbstractViewport) {
          final viewport = node as RenderBox;
          if (!viewport.attached || !viewport.hasSize) return false;
          final viewportRect = MatrixUtils.transformRect(
              viewport.getTransformTo(root), Offset.zero & viewport.size);
          visible = visible.intersect(viewportRect);
        }
        if (identical(node, root)) break;
      }
      return visible.isFinite && visible.width >= 40 && visible.height >= 40;
    } on FlutterError {
      return false;
    }
  }

  String? _targetId(GuideSnapshot s) {
    if (s.step == GuideStep.savedDetail) {
      // Start on the saved event summary. The prep/departure card is farther
      // down and may be absent until its own data is available.
      final summary = _resolveAnchor('saved.summary').context;
      if (_targetIsCurrent(summary)) return 'saved.summary';
      final detail = _resolveAnchor('saved.departure').context;
      if (_targetIsCurrent(detail)) return 'saved.departure';
      final row = _resolveAnchor('calendar.saved').context;
      if (_targetIsCurrent(row)) return 'calendar.saved';
      final retry = _resolveAnchor('calendar.retry').context;
      return _targetIsCurrent(retry) ? 'calendar.retry' : 'calendar.saved';
    }
    if (s.step == GuideStep.querySpeech) {
      final input = _resolveAnchor('voice.review').context;
      return _targetIsCurrent(input) ? 'voice.review' : 'query.results';
    }
    return switch (s.step) {
      GuideStep.homeMic => 'home.mic',
      // Only the microphone button is lit: it is the control that actually
      // starts recognition. The transcript card and the disabled
      // "현재 내용으로 입력" button stay dimmed.
      GuideStep.createSpeech => 'voice.start',
      // correctAndSave shows an always-visible top banner instead of an
      // anchored bubble, so the AI-classification guide appears immediately
      // without scrolling (user request).
      GuideStep.queryMic => 'query.mic',
      GuideStep.queryResults || GuideStep.changeSpeech => 'query.results',
      GuideStep.editPreview => 'edit.save',
      GuideStep.updatedDetail => 'updated.detail',
      _ => null,
    };
  }

  (String, String) _copy(GuideSnapshot s, String id) {
    return switch (s.step) {
      GuideStep.homeMic => ('1/7 · 음성으로 입력 시작', '버튼을 눌러 음성으로 일정을 입력해보세요.'),
      GuideStep.createSpeech => ('1/7', ''),
      GuideStep.correctAndSave => (
          '2/7 · AI가 분류·저장',
          'AI가 시간·제목·장소를 알아서 분류했어요. 틀리면 직접 고칠 수 있어요.\n아래로 내려가 ‘중요한 일정으로 표시’와 ‘강한 알람’을 눌러보고, ‘일정 저장’을 눌러주세요.'
        ),
      GuideStep.savedDetail => (
          '3/7 · 저장된 일정 확인',
          id == 'calendar.saved'
              ? '실제로 저장됐어요. 일정 탭에서 방금 저장한 일정을 눌러주세요.'
              : id == 'calendar.retry'
                  ? '저장한 일정을 찾지 못했어요. ‘다시 확인’으로 기존 목록만 새로 불러와요. 새 일정은 만들지 않아요.'
                  : id == 'saved.summary'
                      ? '저장한 일정과 장소를 확인해 주세요. 준비를 시작할 시간과 늦지 않게 출발할 시간을 알려드려요.'
                      : '저장한 일정과 장소를 확인해 주세요. 준비를 시작할 시간과 늦지 않게 출발할 시간을 알려드려요. 이제 음성으로 일정 수정도 할 수 있어요. 다시 음성 입력 버튼을 눌러주세요.'
        ),
      GuideStep.queryMic || GuideStep.querySpeech => (
          '4/7 · 음성으로 조회',
          '마이크를 누르고 “내일 일정 보여줘”라고 말해주세요.'
        ),
      GuideStep.queryResults || GuideStep.changeSpeech => (
          '5/7 · 음성으로 변경',
          '방금 저장한 일정이 첫 번째로 보여요. “첫 번째 일정 오후 3시로 변경해줘” 또는 “장소를 서울역으로 바꿔줘”라고 말해보세요.'
        ),
      GuideStep.editPreview => (
          '6/7 · 변경 내용 확인·저장',
          '바꿀 시간을 확인하세요. 틀리면 글자로 고친 뒤 실제 저장 버튼을 눌러요. 저장 전에는 일정이 바뀌지 않아요.'
        ),
      GuideStep.updatedDetail => (
          '7/7 · 변경 완료',
          '같은 일정의 시간이 실제로 바뀌었는지 확인하세요. 확인 버튼을 누르면 마지막으로 동기화를 선택해요.'
        ),
      GuideStep.syncChoice || GuideStep.completed => (
          '마무리',
          '이것 말고도 더 많은 기능들이 있으니 확인해보세요.'
        ),
      _ => ('실전 안내', '화면의 실제 내용을 확인해주세요.'),
    };
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GuideSnapshot>(
      valueListenable: coordinator.state,
      builder: (context, s, _) {
        // 저장 화면 안내가 실제로 떠 있는지 여부. 편집기는 이 값이 true인
        // 동안에만 안내 단계(중요한 일정 → 강한 알림 → 저장)를 진행시킨다.
        final saveStageActive =
            s.run == GuideRun.active && s.step == GuideStep.correctAndSave;
        if (guideSaveStageActive.value != saveStageActive) {
          guideSaveStageActive.value = saveStageActive;
        }
        // 말하는 중에도 무엇을 말해야 하는지 화면에 남아 있어야 한다.
        // 말풍선이 음성 원문을 가리면 안 되므로 음성 원문과 마이크를 밝은
        // 구멍으로 뚫고, 그 바로 위에 연습 카드를 띄운다.
        if (s.run == GuideRun.active &&
            s.step == GuideStep.createSpeech &&
            guideListeningBubbleHidden.value) {
          return GuidedCoachmarkOverlay(
              registry: realUiGuideAnchorRegistry,
              targetId: 'voice.review',
              additionalTargetIds: const <String>['voice.start'],
              blockOutsideTaps: false,
              skipLabel: '안내 건너뛰기',
              bubble: const VoiceCorrectionExample(compact: true),
              progressLabel: '1/7',
              onSkip: widget.onSkip ??
                  () {
                    unawaited(coordinator.terminate(GuideExit.skip));
                  });
        }
        final id = _targetId(s);
        final ({GuidedAnchorRegistry registry, BuildContext? context}) resolved =
            id == null
                ? (registry: realUiGuideAnchorRegistry, context: null)
                : _resolveAnchor(id);
        final target = resolved.context;
        final currentTarget = _targetIsCurrent(target);
        final visibleTarget = currentTarget && _targetIsVisible(target);
        if (s.run == GuideRun.active &&
            id != null &&
            (target == null ||
                (!currentTarget &&
                    _atHome() &&
                    GuideRouteRecovery.supports(s))) &&
            MediaQuery.viewInsetsOf(context).bottom == 0) {
          return SafeArea(
              child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Material(
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                        '안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.'),
                                    if (GuideRouteRecovery.supports(s) &&
                                        _atHome())
                                      TextButton(
                                          key: const ValueKey(
                                              'guide-bound-resume'),
                                          onPressed: _recoveringRoute
                                              ? null
                                              : _continueBoundGuide,
                                          child: const Text('안내 계속')),
                                    if (_routeRecoveryError != null)
                                      Text(_routeRecoveryError!),
                                    TextButton(
                                        key: const ValueKey(
                                            'guide-missing-target-skip'),
                                        onPressed: widget.onSkip ??
                                            () {
                                              unawaited(coordinator
                                                  .terminate(GuideExit.skip));
                                            },
                                        child: const Text('안내 건너뛰기')),
                                  ]))))));
        }
        // correctAndSave: immediate top banner (no anchor) so the AI guide
        // is visible on entry, per user flow.
        if (s.step == GuideStep.correctAndSave) {
          if (s.run != GuideRun.active) {
            return const SizedBox.shrink();
          }
          // AI 파싱이 끝나기 전에는 편집기 화면이 흐려져 있어 안내를 그리지
          // 않는다. 파싱이 끝나면 스크롤 전에도 '일정 확인' 배너를 먼저 보여
          // 주고, 사용자가 직접 내린 뒤에만 단계별 스포트라이트를 켠다.
          if (!guideConfirmReady.value) {
            return const SizedBox.shrink();
          }
          // 실제 화면을 누르는 순서대로 강조 대상이 바뀐다.
          //   1) '중요한 일정으로 표시' 체크박스
          //   2) '강한 알림' 스위치
          //   3) '일정 저장' 버튼
          final stage = guideSaveStage.value;
          final guideTarget = switch (stage) {
            GuideSaveStage.important => 'confirm.critical',
            GuideSaveStage.strong => 'confirm.strong',
            GuideSaveStage.save => 'confirm.save',
          };
          final targetContext = _resolveAnchor(guideTarget).context;
          // 화면에 들어오자마자 보이는 안내: 스크롤 전에는 날짜·시간·장소를
          // 먼저 확인하게 하고, 사용자가 직접 내린 뒤에만 단계별 강조(구멍)를
          // 켜서 '중요한 일정'부터 순서대로 진행한다.
          final spotlight = guideConfirmSpotlightEligible(
                  ready: guideConfirmReady.value,
                  userScrolled: guideConfirmUserScrolled.value) &&
              _targetIsCurrent(targetContext) &&
              _targetIsVisible(targetContext);
          final bannerCopy = !spotlight
              ? (
                  '2/7 · 일정 확인',
                  '날짜·시간·장소가 맞는지 먼저 확인해 주세요.\n아래로 내리면 ‘중요한 일정’ → ‘강한 알람’ → ‘일정 저장’ 순서로 안내할게요.'
                )
              : switch (stage) {
                  GuideSaveStage.important => (
                      '2/7 · 중요한 일정',
                      '‘중요한 일정으로 표시’를 눌러보세요. 달력에서 굵게 표시돼요.'
                    ),
                  GuideSaveStage.strong => (
                      '2/7 · 강한 알람',
                      '‘강한 알람’을 켜면 일정 시작 시 큰 소리와 진동으로 알려줘요.'
                    ),
                  GuideSaveStage.save => (
                      '2/7 · 저장하기',
                      '이제 ‘일정 저장’을 눌러 저장해 보세요.'
                    ),
                };
          // Never reveal or scroll to a guide target automatically. The
          // spotlight is eligible only after parsing finished and the user
          // scrolled the list down by themselves.
          return Stack(children: [
            // 대상이 보이지 않을 때는 오버레이가 스스로 딤을 생략한다.
            if (spotlight)
              GuidedCoachmarkOverlay(
                  registry: realUiGuideAnchorRegistry,
                  targetId: guideTarget,
                  blockOutsideTaps: false,
                  showBubble: false,
                  bubble: const SizedBox.shrink(),
                  progressLabel: '2/7',
                  skipLabel: '안내 건너뛰기',
                  onSkip: widget.onSkip ??
                      () {
                        unawaited(coordinator.terminate(GuideExit.skip));
                      }),
            SafeArea(
                child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // 카드가 목록 상단을 덮어도 손가락 스크롤을
                              // 가로채지 않도록 입력만 통과시킨다.
                              IgnorePointer(
                                  child: Material(
                                      elevation: 8,
                                      borderRadius: BorderRadius.circular(16),
                                      color:
                                          Theme.of(context).colorScheme.surface,
                                      child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Text(bannerCopy.$1,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                            fontWeight:
                                                                FontWeight
                                                                    .w700)),
                                                const SizedBox(height: 8),
                                                Text(bannerCopy.$2),
                                              ])))),
                              TextButton(
                                  onPressed: widget.onSkip ??
                                      () => unawaited(coordinator
                                          .terminate(GuideExit.skip)),
                                  child: const Text('안내 건너뛰기')),
                            ])))),
          ]);
        }
        if (s.run != GuideRun.active ||
            id == null ||
            !currentTarget ||
            MediaQuery.viewInsetsOf(context).bottom > 0) {
          return const SizedBox.shrink();
        }
        if (!visibleTarget) {
          return SafeArea(
              child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Material(
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                        '안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.'),
                                    TextButton(
                                        key: const ValueKey(
                                            'guide-missing-target-skip'),
                                        onPressed: widget.onSkip ??
                                            () => unawaited(coordinator
                                                .terminate(GuideExit.skip)),
                                        child: const Text('안내 건너뛰기')),
                                  ]))))));
        }
        final copy = _copy(s, id);
        return GuidedCoachmarkOverlay(
            registry: resolved.registry,
            targetId: id,
            blockOutsideTaps: id == 'home.mic' ||
                id == 'voice.start' ||
                id == 'query.mic' ||
                id == 'calendar.saved' ||
                id == 'calendar.retry',
            skipLabel: '안내 건너뛰기',
            additionalTargetIds: const <String>[],
            bubble: s.step == GuideStep.createSpeech
                ? const VoiceCorrectionExample()
                : Text(copy.$2),
            progressLabel: copy.$1,
            onSkip: widget.onSkip ??
                () {
                  unawaited(coordinator.terminate(GuideExit.skip));
                });
      });
}

/// Waits for observed guide evidence, not a timer or a fabricated Next signal.
/// Account changes release only this waiter and never complete another UID.
Future<void> waitForGuideState(
    {required GuideCoordinator coordinator,
    required String uid,
    required Listenable auth,
    required String? Function() currentUid,
    required bool Function(GuideSnapshot) ready}) async {
  final done = Completer<void>();
  void check() {
    if (currentUid() != uid || ready(coordinator.state.value)) {
      if (!done.isCompleted) done.complete();
    }
  }

  coordinator.state.addListener(check);
  auth.addListener(check);
  try {
    check();
    await done.future;
  } finally {
    coordinator.state.removeListener(check);
    auth.removeListener(check);
  }
}

/// The production Shell uses this order; tests inject ports, never Supabase.
Future<bool> runGuideStartupSequence(
    {required Future<void> Function() ready,
    required Future<void> Function() intro,
    required bool Function() introConfirmed,
    required Future<void> Function() guide,
    required Future<bool> Function() syncChoice,
    required bool Function() sameAccount}) async {
  await ready();
  if (!sameAccount()) return false;
  await intro();
  if (!sameAccount() || !introConfirmed()) return false;
  await guide();
  if (!sameAccount()) return false;
  return syncChoice();
}
