import 'dart:async';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/safe_prefs.dart';
import '../../core/local_time.dart';
import '../../core/startup_route_gate.dart';
import '../../widgets/guided_coachmark_overlay.dart';
import '../../widgets/guided_anchor.dart';
import 'guide_bubble_visibility.dart';
import 'guide_contract.dart';
import 'guide_coordinator.dart';
import 'guide_guards.dart';
import 'guide_instruction_text.dart';
import 'voice_correction_example.dart';
import 'guide_providers.dart';
import 'guide_qa_build_diagnostics.dart';
import 'guide_scope.dart';
import 'guide_route_recovery.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';
import '../../data/repositories/event_repository.dart';
import '../../screens/onboarding/legacy_intro_screen.dart';
import '../../screens/voice/voice_input_screen.dart';
import '../../screens/voice/voice_conversation_screen.dart';
import '../../services/app_feedback_service.dart';
import 'package:go_router/go_router.dart';

/// The scope must wrap the root navigator, not an individual Shell route.
/// Backend and quota-runtime bindings are injected by the application owner.
class RootGuideScope extends ConsumerStatefulWidget {
  const RootGuideScope(
      {super.key,
      required this.uid,
      required this.child,
      required this.bindRuntime,
      required this.unbindRuntime,
      this.backButtonDispatcher,
      this.router,
      this.onSwitchQaAccount,
      this.isGuideQa = false});
  final String? uid;
  final Widget child;
  final Object Function(GuideCoordinator) bindRuntime;
  final void Function(Object) unbindRuntime;
  final BackButtonDispatcher? backButtonDispatcher;
  final GoRouter? router;
  final Future<void> Function(String uid)? onSwitchQaAccount;

  /// Set only after the isolated QA package has been verified.
  final bool isGuideQa;
  @override
  ConsumerState<RootGuideScope> createState() => _RootGuideScopeState();
}

class _RootGuideScopeState extends ConsumerState<RootGuideScope>
    with WidgetsBindingObserver {
  GuideCoordinator? _coordinator;
  Object? _token;
  Object _epoch = Object();
  String? _error;
  String? _retryMessage;
  bool _retrying = false;
  bool _switchingQaAccount = false;
  bool _retryRequiresStart = false;
  bool _sessionOnlyRecovery = false;
  bool _waitingPanelVisible = false;
  ChildBackButtonDispatcher? _guideBackDispatcher;
  ModalRoute<dynamic>? _syncChoiceRoute;
  _SessionOnlyGuideProgressStore? _recoveryProgress;
  _PermissionSettingsReturnFence? _permissionSettingsReturn;
  @override
  void initState() {
    super.initState();
    logGuideQaBuildDefines();
    WidgetsBinding.instance.addObserver(this);
    _attachBackDispatcher();
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
    if (oldWidget.backButtonDispatcher != widget.backButtonDispatcher) {
      _detachBackDispatcher();
      _attachBackDispatcher();
    }
    if (oldWidget.uid != widget.uid) _start();
  }

  void _attachBackDispatcher() {
    final dispatcher = widget.backButtonDispatcher;
    if (dispatcher == null) return;
    final child = dispatcher.createChildBackButtonDispatcher();
    _guideBackDispatcher = child;
    child.addCallback(_handleRootBackButton);
    // Router also registers a callback. Use a priority child once Router has
    // mounted so its normal pop path remains available for unhandled Back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_guideBackDispatcher, child)) {
        child.takePriority();
      }
    });
  }

  void _detachBackDispatcher() {
    _guideBackDispatcher?.removeCallback(_handleRootBackButton);
    _guideBackDispatcher = null;
  }

  @override
  Future<bool> didPopRoute() => widget.backButtonDispatcher == null
      ? _handleRootBackButton()
      : Future.value(false);

  bool _recoveryVisible(GuideSnapshot s) =>
      _retrying ||
      _switchingQaAccount ||
      _retryMessage != null ||
      _error != null ||
      (s.run != GuideRun.terminal &&
          (s.run != GuideRun.active || s.errorCode != null));

  VoidCallback _registerSyncChoiceRoute(ModalRoute<dynamic> route) {
    _syncChoiceRoute = route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_syncChoiceRoute, route)) setState(() {});
    });
    return () {
      if (identical(_syncChoiceRoute, route)) {
        _syncChoiceRoute = null;
        if (mounted) setState(() {});
      }
    };
  }

  bool get _syncChoiceRouteIsCurrent => _syncChoiceRoute?.isCurrent == true;

  Future<bool> _handleRootBackButton() async {
    final uid = widget.uid;
    if (widget.isGuideQa ||
        uid == null ||
        uid.isEmpty ||
        _sessionOnlyRecovery ||
        _syncChoiceRouteIsCurrent) {
      return false;
    }
    final snapshot = _coordinator?.state.value;
    if (snapshot == null ||
        snapshot.uid != uid ||
        (_recoveryVisible(snapshot) &&
            (snapshot.run != GuideRun.terminal || _error != null)) ||
        (snapshot.run == GuideRun.active && _waitingPanelVisible)) {
      unawaited(_skipFromBack());
      return true;
    }
    final navigator = widget.router?.routerDelegate.navigatorKey.currentState;
    if (snapshot.run == GuideRun.active &&
        navigator != null &&
        !navigator.canPop()) {
      // GoRouter does not call maybePop on a single-route Navigator. The
      // guided screen's PopScope still needs to receive explicit system Back.
      return navigator.maybePop();
    }
    return false;
  }

  void _start({bool retry = false}) {
    _epoch = Object();
    _permissionSettingsReturn = null;
    _retrying = retry;
    _switchingQaAccount = false;
    _retryRequiresStart = false;
    _retryMessage = null;
    _waitingPanelVisible = false;
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
        if (coordinator is RealUiGuideCoordinator) {
          await coordinator.start(
              uid: uid, skipIncompleteOnColdStart: !widget.isGuideQa && !retry);
        } else {
          await coordinator.start(uid: uid);
        }
        if (!identical(epoch, _epoch) || !mounted) return;
        if (coordinator.state.value.run == GuideRun.terminal &&
            await GuideSyncChoiceStore().isClosed(uid)) {
          if (!identical(epoch, _epoch) || !mounted) return;
          startupRouteGate.closeGuideChoice(uid);
        }
      } catch (_) {
        if (identical(epoch, _epoch)) {
          _error = '안내를 불러오지 못했습니다.';
          _retryRequiresStart = true;
        }
      } finally {
        if (mounted && identical(epoch, _epoch)) {
          setState(() => _retrying = false);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a real background transition may pause the guide. Android emits
    // `inactive` while a permission dialog is on top of a still-visible,
    // still-interactive app, so pausing there would strand an active ASR run.
    // Only a return from an explicitly opened settings screen may resume.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _coordinator?.suspend(GuidePauseReason.background);
    } else if (state == AppLifecycleState.resumed) {
      final fence = _permissionSettingsReturn;
      _permissionSettingsReturn = null;
      final coordinator = _coordinator;
      final current = coordinator?.state.value;
      if (fence != null &&
          current != null &&
          current.uid == widget.uid &&
          fence.matches(current, DateTime.now())) {
        unawaited(coordinator!.dispatch(ResumeRequested(
          uid: current.uid,
          sessionId: current.sessionId!,
          expectedRevision: current.revision,
        )));
      }
    }
  }

  VoidCallback? _beginPermissionSettingsReturn() {
    final current = _coordinator?.state.value;
    if (current == null || current.uid != widget.uid ||
        current.run != GuideRun.active ||
        current.sessionId?.isNotEmpty != true) {
      return null;
    }
    final fence = _PermissionSettingsReturnFence(current, DateTime.now());
    _permissionSettingsReturn = fence;
    return () {
      if (identical(_permissionSettingsReturn, fence)) {
        _permissionSettingsReturn = null;
      }
    };
  }

  @override
  void dispose() {
    _epoch = Object();
    _detachBackDispatcher();
    guideListeningBubbleHidden.removeListener(_onListeningBubbleChanged);
    guideConfirmUserScrolled.removeListener(_onListeningBubbleChanged);
    guideConfirmReady.removeListener(_onListeningBubbleChanged);
    WidgetsBinding.instance.removeObserver(this);
    _coordinator?.suspend(GuidePauseReason.routeLost);
    if (_token case final Object token) widget.unbindRuntime(token);
    super.dispose();
  }

  void _skipThisSession() {
    if (widget.isGuideQa || _switchingQaAccount) return;
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
      _retryMessage = null;
      _retrying = false;
      _waitingPanelVisible = false;
    });
  }

  Future<void> _retryGuide() async {
    if (_retrying || _switchingQaAccount) return;
    final coordinator = _coordinator;
    if (coordinator == null || _error != null) {
      setState(() => _start(retry: true));
      return;
    }
    final epoch = _epoch;
    final uid = widget.uid;
    if (uid == null || uid.isEmpty) return;
    final requiresStart = _retryRequiresStart;
    setState(() {
      _retrying = true;
      _retryMessage = null;
    });
    bool ownsAttempt() =>
        mounted &&
        identical(epoch, _epoch) &&
        uid == widget.uid &&
        identical(coordinator, _coordinator);
    var attemptedStart = false;
    try {
      final current = coordinator.state.value;
      if (requiresStart || current.uid != uid || current.sessionId == null) {
        attemptedStart = true;
        await coordinator.start(uid: uid);
      } else {
        await coordinator.dispatch(ResumeRequested(
            uid: uid,
            sessionId: current.sessionId!,
            expectedRevision: current.revision));
      }
      if (!ownsAttempt()) return;
      if (attemptedStart) _retryRequiresStart = false;
      final result = coordinator.state.value;
      if (result.uid != uid ||
          (result.run != GuideRun.terminal &&
              (result.run != GuideRun.active || result.errorCode != null))) {
        _retryMessage = result.failureDiagnostic == null &&
                !(widget.isGuideQa &&
                    result.errorCode == 'created_binding_conflict')
            ? '안내를 이어가지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요.'
            : null;
      }
    } catch (_) {
      if (ownsAttempt()) {
        if (attemptedStart) _retryRequiresStart = true;
        _retryMessage = '안내를 이어가지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요.';
      }
    } finally {
      if (ownsAttempt()) setState(() => _retrying = false);
    }
  }

  Future<void> _switchQaAccount() async {
    final action = widget.onSwitchQaAccount;
    final uid = widget.uid;
    if (_retrying || _switchingQaAccount || action == null || uid == null) {
      return;
    }
    final epoch = _epoch;
    setState(() {
      _switchingQaAccount = true;
      _retryMessage = null;
    });
    bool ownsAttempt() =>
        mounted && identical(epoch, _epoch) && uid == widget.uid;
    try {
      await action(uid);
    } catch (_) {
      if (ownsAttempt()) {
        _retryMessage = '계정을 바꾸지 못했어요. ‘계정 바꾸기’를 다시 눌러 주세요.';
      }
    } finally {
      if (ownsAttempt()) setState(() => _switchingQaAccount = false);
    }
  }

  Future<void> _skipFromBack() async {
    if (widget.isGuideQa || _switchingQaAccount) return;
    final uid = widget.uid;
    final coordinator = _coordinator;
    if (coordinator == null ||
        _error != null ||
        coordinator.state.value.uid != uid) {
      _skipThisSession();
      return;
    }
    final epoch = _epoch;
    bool ownsAttempt() =>
        mounted &&
        identical(epoch, _epoch) &&
        uid == widget.uid &&
        identical(coordinator, _coordinator);
    try {
      await coordinator.terminate(GuideExit.skip);
      if (ownsAttempt()) {
        setState(() {
          _retryMessage = null;
          _retrying = false;
        });
      }
    } catch (_) {
      if (ownsAttempt()) {
        _skipThisSession();
      }
    }
  }

  Widget _loadingNotice() => const Positioned.fill(
      child: ColoredBox(
          key: ValueKey('guide-loading-barrier'),
          color: Color(0x55000000),
          child: Center(child: CircularProgressIndicator())));

  String? _failureCode(GuideSnapshot? snapshot) {
    final errorCode = snapshot?.errorCode;
    final diagnosticCode = snapshot?.failureDiagnostic?.code;
    // A transient connection failure can predate the binding checkpoint.
    // Show the blocking checkpoint instead of the stale connection message.
    const transient = {'timeout', 'network', 'backend_unavailable'};
    final bindingBlocked = errorCode == 'guide_session_changed' ||
        errorCode == 'guide_bound_event_missing' ||
        (widget.isGuideQa && errorCode == 'created_binding_conflict');
    final code = bindingBlocked && transient.contains(diagnosticCode)
        ? errorCode
        : diagnosticCode ?? errorCode;
    if (code == null) return null;
    if (widget.isGuideQa && code == 'created_binding_conflict') return code;
    const known = {
      'local_uid_mismatch',
      'auth_error',
      'timeout',
      'network',
      'terminal',
      'expired',
      'denied',
      'malformed',
      'wire_expired',
      'backend_unavailable',
      'guide_session_changed',
      'guide_bound_event_missing',
      'guide_progress_load_failed',
      'guide_progress_save_failed',
      'guide_operation_failed',
    };
    const deniedReasons = {
      'denied:invalid_request',
      'denied:request_replay_mismatch',
      'denied:session_expired',
      'denied:session_terminal',
    };
    return known.contains(code) || deniedReasons.contains(code) ? code : null;
  }

  String _failureMessage(String? code, {required bool fatal}) {
    switch (code) {
      case 'local_uid_mismatch':
      case 'auth_error':
        return widget.onSwitchQaAccount != null
            ? '로그인 정보를 확인할 수 없어요. 계정을 바꾸거나 다시 로그인해 주세요.'
            : '로그인 정보를 확인할 수 없어요. 다시 로그인해 주세요.';
      case 'terminal':
      case 'expired':
      case 'denied:session_terminal':
      case 'denied:session_expired':
      case 'guide_bound_event_missing':
        return '이 안내는 다시 시작해야 해요. 계정과 안내 상태를 확인해 주세요.';
      case 'timeout':
        return '안내 연결 시간이 초과됐어요. 연결 상태를 확인한 뒤 다시 시도해 주세요.';
      case 'network':
      case 'backend_unavailable':
        return '안내 서버에 연결하지 못했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.';
      case 'guide_progress_save_failed':
        return '안내 진행 상태를 저장하지 못했어요. 다시 시도해 주세요.';
      case 'guide_progress_load_failed':
        return '안내 진행 상태를 불러오지 못했어요. 다시 시도해 주세요.';
      case 'wire_expired':
        return '안내 연결 정보가 만료됐어요. 다시 시도해 주세요.';
      case 'guide_session_changed':
        return '로그인 상태가 바뀌었어요. 계정을 확인한 뒤 다시 시도해 주세요.';
      case 'created_binding_conflict':
        return '저장된 일정과 안내의 연결 정보가 일치하지 않아요. 계정과 안내 상태를 확인해 주세요.';
      case 'denied':
      case 'denied:invalid_request':
      case 'denied:request_replay_mismatch':
        return '안내 시작이 거절됐어요. 계정과 안내 상태를 확인해 주세요.';
      case 'malformed':
        return '안내 서버의 응답을 확인하지 못했어요. 다시 시도해 주세요.';
      case 'guide_operation_failed':
        return '안내를 이어가지 못했어요. 다시 시도해 주세요.';
      default:
        if (widget.isGuideQa) {
          return fatal
              ? '안내를 불러오지 못했어요. 무료 횟수를 쓰지 않고 다시 시도할 수 있어요.'
              : '안내가 잠시 멈췄어요. 다시 시도해 주세요.';
        }
        return fatal
            ? '안내를 불러오지 못했어요. 무료 횟수를 쓰지 않고 다시 시도하거나 뒤로가기로 안내를 닫을 수 있어요.'
            : '안내가 잠시 멈췄어요. 다시 시도하거나 뒤로가기로 안내를 닫을 수 있어요.';
    }
  }

  Widget _recoveryNotice({required bool fatal, GuideSnapshot? snapshot}) {
    final busy = _retrying || _switchingQaAccount;
    final code = _failureCode(snapshot);
    return Positioned.fill(
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
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            GuideInstructionText(_switchingQaAccount
                                ? '로그인 화면으로 이동하고 있어요.'
                                : _retrying
                                    ? '안내를 다시 연결하고 있어요. 잠시만 기다려 주세요.'
                                    : _retryMessage ??
                                        _failureMessage(code, fatal: fatal)),
                            if (widget.isGuideQa && code != null && !busy)
                              Text('안내 오류 코드: $code',
                                  key: const ValueKey('guide-failure-code')),
                            if (busy)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: CircularProgressIndicator(
                                  key: const ValueKey('guide-retry-progress'),
                                  semanticsLabel: _switchingQaAccount
                                      ? '로그인 화면으로 이동 중'
                                      : '안내 다시 연결 중',
                                ),
                              ),
                            Wrap(children: [
                              TextButton(
                                  key: const ValueKey('guide-retry'),
                                  onPressed: busy ? null : _retryGuide,
                                  child: const Text('다시 시도')),
                              if (widget.onSwitchQaAccount != null)
                                TextButton(
                                    key: const ValueKey(
                                        'guide-switch-qa-account'),
                                    onPressed: busy ? null : _switchQaAccount,
                                    child: const Text('계정 바꾸기')),
                            ])
                          ]))))))
    ]));
  }

  Widget _terminalNotice() => Positioned(
      top: 12,
      left: 16,
      right: 16,
      child: IgnorePointer(
          child: SafeArea(
              child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        GuideInstructionText(
                            _failureMessage('terminal', fatal: false)),
                        Text('안내 오류 코드: terminal',
                            key: const ValueKey('guide-failure-code')),
                      ]))))));

  @override
  Widget build(BuildContext context) {
    final coordinator = _coordinator;
    if (widget.uid == null || widget.uid!.isEmpty) return widget.child;
    Widget content;
    // The QA account switch may first show a Navigator confirmation. That
    // dialog owns its modal barrier; the app-level QA barrier protects the
    // subsequent sign-out. Let both render above the guide recovery layer.
    final qaSwitching = widget.isGuideQa && _switchingQaAccount;
    if (coordinator == null) {
      content = Stack(fit: StackFit.expand, children: [
        IgnorePointer(
            ignoring: !qaSwitching,
            child: ExcludeFocus(excluding: !qaSwitching, child: widget.child)),
        if (!qaSwitching)
          if (_retrying || _switchingQaAccount || _error != null)
            _recoveryNotice(fatal: true)
          else
            _loadingNotice(),
      ]);
    } else {
      content = GuideScope(
          coordinator: coordinator,
          allowBackSkip: !widget.isGuideQa,
          beginPermissionSettingsReturn: _beginPermissionSettingsReturn,
          registerSyncChoiceRoute: _registerSyncChoiceRoute,
          child: ValueListenableBuilder<GuideSnapshot>(
              valueListenable: coordinator.state,
              builder: (context, s, _) {
                final waiting =
                    s.uid != widget.uid && _error == null && !_retrying;
                final syncChoiceRouteIsCurrent = _syncChoiceRouteIsCurrent;
                final recovery =
                    _recoveryVisible(s) && !syncChoiceRouteIsCurrent;
                final blocked = waiting || recovery;
                final coaching = !blocked &&
                    !syncChoiceRouteIsCurrent &&
                    s.run == GuideRun.active &&
                    s.step != GuideStep.intro &&
                    s.step != GuideStep.completionConfirm &&
                    s.step != GuideStep.syncChoiceConfirmed;
                if (!coaching) _waitingPanelVisible = false;
                return Stack(fit: StackFit.expand, children: [
                  IgnorePointer(
                      ignoring: blocked && !qaSwitching,
                      child: ExcludeFocus(
                          excluding: blocked && !qaSwitching,
                          child: widget.child)),
                  if (coaching)
                    RealUiGuideCoachmark(
                        key: ObjectKey(coordinator),
                        coordinator: coordinator,
                        router: widget.router,
                        isGuideQa: widget.isGuideQa,
                        onWaitingPanelVisibilityChanged: (visible) {
                          _waitingPanelVisible = visible;
                        }),
                  if (waiting && !qaSwitching) _loadingNotice(),
                  if (!blocked &&
                      widget.isGuideQa &&
                      s.run == GuideRun.terminal &&
                      s.failureDiagnostic?.kind == GuideFailureKind.terminal)
                    _terminalNotice(),
                  if (!waiting && recovery && !qaSwitching)
                    _recoveryNotice(fatal: _error != null, snapshot: s),
                ]);
              }));
    }
    content = GuideSaveFeedbackHost(child: content);
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

class _PermissionSettingsReturnFence {
  _PermissionSettingsReturnFence(GuideSnapshot snapshot, this.armedAt)
      : uid = snapshot.uid,
        sessionId = snapshot.sessionId!,
        step = snapshot.step,
        armedRevision = snapshot.revision;

  final String uid;
  final String sessionId;
  final GuideStep step;
  final int armedRevision;
  final DateTime armedAt;

  bool matches(GuideSnapshot current, DateTime now) {
    final age = now.difference(armedAt);
    return !age.isNegative &&
        age <= const Duration(minutes: 3) &&
        current.uid == uid &&
        current.sessionId == sessionId &&
        current.step == step &&
        current.run == GuideRun.paused &&
        current.pauseReason == GuidePauseReason.background &&
        current.revision == armedRevision + 1;
  }
}

/// Explicit, in-memory recovery only. It never grants an exempt operation.
class _SessionOnlySkippedGuideCoordinator implements GuideCoordinator {
  _SessionOnlySkippedGuideCoordinator(String uid)
      : _state = ValueNotifier(GuideSnapshot(
            uid: uid,
            version: realUiGuideVersion,
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
  String key(String uid) => 'guide_sync_choice:$realUiGuideVersion:$uid';
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
      {super.key,
      required this.coordinator,
      this.router,
      this.onSkip,
      this.onWaitingPanelVisibilityChanged,
      this.isGuideQa = false});
  final GuideCoordinator coordinator;
  final GoRouter? router;
  final VoidCallback? onSkip;
  final ValueChanged<bool>? onWaitingPanelVisibilityChanged;
  final bool isGuideQa;

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
  static const _confirmReviewTargets = <String>[
    'confirm.title',
    'confirm.dateTime',
    'confirm.location',
  ];
  GuideCoordinator get coordinator => widget.coordinator;
  Timer? _routeCheck;
  bool _recoveringRoute = false;
  String? _routeRecoveryError;
  bool _firstInlineRouteFrame = false;

  bool _isInlineGuideDestination(GuideSnapshot snapshot) {
    final matches = widget.router?.routerDelegate.currentConfiguration;
    final id = snapshot.createdEventId;
    if (snapshot.run != GuideRun.active ||
        id == null ||
        matches == null ||
        matches.isEmpty) {
      return false;
    }
    final location = matches.last.matchedLocation;
    final eventId = Uri.encodeComponent(id);
    final isDetail = location == '${AppRoutes.eventDetail}/$eventId';
    return switch (snapshot.step) {
      GuideStep.savedDetail || GuideStep.updatedDetail => isDetail,
      GuideStep.editPreview =>
        isDetail || location == '${AppRoutes.eventEdit}/$eventId',
      _ => false,
    };
  }

  // The destination supplies its own guide before its anchors are measured.
  void _holdRootCoachmarkForRouteFrame() {
    _firstInlineRouteFrame = _isInlineGuideDestination(coordinator.state.value);
    if (!_firstInlineRouteFrame) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _firstInlineRouteFrame) {
        setState(() => _firstInlineRouteFrame = false);
      }
    });
  }

  void _onRouterChanged() {
    if (mounted) setState(_holdRootCoachmarkForRouteFrame);
  }

  bool _atHome() {
    if (!mounted) return false;
    final home = _resolveAnchor('home.mic').context;
    return _targetIsCurrent(home);
  }

  bool _needsPreviewRefresh(GuideSnapshot snapshot) =>
      snapshot.expectedUpdatedStartLocal == null &&
      (snapshot.step == GuideStep.editPreview ||
          snapshot.step == GuideStep.updatedDetail);

  Future<void> _continueBoundGuide() async {
    if (_recoveringRoute || !_atHome()) return;
    final capturedCoordinator = coordinator;
    setState(() {
      _recoveringRoute = true;
      _routeRecoveryError = null;
    });
    try {
      final before = capturedCoordinator.state.value;
      final sessionId = before.sessionId;
      if (_needsPreviewRefresh(before) &&
          sessionId != null &&
          before.uid == authProvider.userId) {
        final resumed = await capturedCoordinator.dispatch(ResumeRequested(
            uid: before.uid,
            sessionId: sessionId,
            expectedRevision: before.revision));
        if (!mounted ||
            !identical(coordinator, capturedCoordinator) ||
            !_atHome()) {
          return;
        }
        if (!identical(capturedCoordinator.state.value, resumed) ||
            resumed.uid != before.uid ||
            resumed.version != before.version ||
            resumed.sessionId != sessionId ||
            resumed.createdEventId != before.createdEventId ||
            resumed.serverRevision < before.serverRevision) {
          throw StateError('preview_recovery_context_changed');
        }
        if (_needsPreviewRefresh(resumed)) {
          throw StateError('preview_recovery_missing_time');
        }
      }
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
        setState(() =>
            _routeRecoveryError = '안내를 이어가지 못했어요. 저장한 일정은 그대로예요. 다시 시도해주세요.');
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
            extra: recovery.opensEditPreview
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
            _needsPreviewRefresh(coordinator.state.value)
                ? '변경할 시간을 확인하지 못했어요. ‘안내 계속’을 눌러 다시 시도해 주세요.'
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
  bool? _lastLegacyIntroCurrent;
  Rect? _lastRect;
  Rect? _lastSavedSummaryRect;
  // 저장 단계에 들어올 때마다 '중요한 일정'부터 다시 시작한다. 화면이
  // 이전 안내 단계에 머물러 있어도 새 안내가 저장 단계의 첫 컷아웃을
  // 건너뛰지 않게 한다.
  bool _saveStageResetDone = false;
  Timer? _confirmScrollCueTimer;
  bool _showConfirmScrollCue = false;

  @override
  void initState() {
    super.initState();
    widget.router?.routerDelegate.addListener(_onRouterChanged);
    _holdRootCoachmarkForRouteFrame();
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
    guideSaveProgress.addListener(_onSaveStageChanged);
    coordinator.state.addListener(_onGuideStateForSaveStage);
    // Registry mounting and Navigator popup changes do not emit guide signals.
    _routeCheck = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final snapshot = coordinator.state.value;
      _syncConfirmScrollCue(snapshot);
      // correctAndSave 단계에는 일반 대상 ID가 없으므로 저장 단계 대상을
      // 따로 본다. '중요한 일정' → '강한 알림'으로 넘어가면 앵커가 나중에
      // 등록되므로, 여기서 다시 그리지 않으면 구멍이 옛 자리에 남는다.
      final id = _targetId(snapshot) ?? _saveStageTargetId(snapshot);
      final target = id == null ? null : _resolveAnchor(id).context;
      final current = _targetIsCurrent(target);
      final visible = current && _targetIsVisible(target);
      final legacyIntroCurrent = _legacyIntroIsCurrent();
      // 앵커가 같은 화면에 있어도 스크롤로 위치가 바뀌면 구멍이 옛 자리에
      // 남는다. 대상 영역이 실제로 움직였는지도 함께 지켜본다.
      final rect = id == null ? null : _targetRectInHost(id);
      final summaryRect = id == 'saved.confirm' &&
              _targetIsCurrent(_resolveAnchor('saved.summary').context)
          ? _targetRectInHost('saved.summary')
          : null;
      if (!identical(target, _lastTarget) ||
          current != _lastCurrent ||
          visible != _lastVisible ||
          legacyIntroCurrent != _lastLegacyIntroCurrent ||
          rect != _lastRect ||
          summaryRect != _lastSavedSummaryRect ||
          id != _lastId) {
        _lastTarget = target;
        _lastId = id;
        _lastCurrent = current;
        _lastVisible = visible;
        _lastLegacyIntroCurrent = legacyIntroCurrent;
        _lastRect = rect;
        _lastSavedSummaryRect = summaryRect;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(RealUiGuideCoachmark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router?.routerDelegate.removeListener(_onRouterChanged);
      widget.router?.routerDelegate.addListener(_onRouterChanged);
      _holdRootCoachmarkForRouteFrame();
    }
  }

  @override
  void dispose() {
    widget.router?.routerDelegate.removeListener(_onRouterChanged);
    _routeCheck?.cancel();
    _confirmScrollCueTimer?.cancel();
    coordinator.state.removeListener(_onGuideStateForSaveStage);
    guideSaveStage.removeListener(_onSaveStageChanged);
    guideConfirmReady.removeListener(_onConfirmGateChanged);
    guideConfirmUserScrolled.removeListener(_onConfirmGateChanged);
    guideSaveProgress.removeListener(_onSaveStageChanged);
    super.dispose();
  }

  void _onSaveStageChanged() {
    if (mounted) setState(() {});
  }

  /// 파싱 완료·사용자 스크롤 상태가 바뀌면 스포트라이트를 다시 그린다.
  void _onConfirmGateChanged() {
    if (!mounted) return;
    _syncConfirmScrollCue(coordinator.state.value);
    setState(() {});
  }

  bool _waitingForConfirmScroll(GuideSnapshot snapshot) =>
      snapshot.run == GuideRun.active &&
      snapshot.step == GuideStep.correctAndSave &&
      guideConfirmReady.value &&
      !guideConfirmUserScrolled.value &&
      _targetIsCurrent(_resolveAnchor('confirm.review').context);

  void _syncConfirmScrollCue(GuideSnapshot snapshot) {
    if (!_waitingForConfirmScroll(snapshot)) {
      _confirmScrollCueTimer?.cancel();
      _confirmScrollCueTimer = null;
      if (_showConfirmScrollCue) setState(() => _showConfirmScrollCue = false);
      return;
    }
    if (_showConfirmScrollCue || _confirmScrollCueTimer != null) return;
    _confirmScrollCueTimer = Timer(const Duration(seconds: 2), () {
      _confirmScrollCueTimer = null;
      if (mounted && _waitingForConfirmScroll(coordinator.state.value)) {
        setState(() => _showConfirmScrollCue = true);
      }
    });
  }

  /// 안내가 저장 단계에 새로 진입할 때만 단계를 초기화한다. 같은 저장
  /// 화면에서 사용자가 토글을 누르는 동안에는 되돌리지 않는다.
  void _onGuideStateForSaveStage() {
    if (!mounted) return;
    final s = coordinator.state.value;
    _syncConfirmScrollCue(s);
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

  String? _visibleSaveOption() {
    if (!guideConfirmSpotlightEligible(
        ready: guideConfirmReady.value,
        userScrolled: guideConfirmUserScrolled.value)) {
      return null;
    }
    final id = switch (guideSaveStage.value) {
      GuideSaveStage.important => 'confirm.critical',
      GuideSaveStage.strong => 'confirm.strong',
      GuideSaveStage.save => 'confirm.save',
    };
    final target = _resolveAnchor(id).context;
    return _targetIsCurrent(target) && _targetIsVisible(target) ? id : null;
  }

  String? _visibleConfirmReviewTarget() {
    if (!guideConfirmReady.value) return null;
    for (final id in _confirmReviewTargets) {
      final target = _resolveAnchor(id).context;
      if (_targetIsCurrent(target) && _targetIsVisible(target)) return id;
    }
    return null;
  }

  /// 저장 안내에서 현재 화면에 보이는 편집 필드 또는 실제 조작 대상.
  String? _saveStageTargetId(GuideSnapshot s) {
    if (s.run != GuideRun.active || s.step != GuideStep.correctAndSave) {
      return null;
    }
    return _visibleSaveOption() ?? _visibleConfirmReviewTarget();
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

  bool _legacyIntroIsCurrent() =>
      _targetIsCurrent(_resolveAnchor(LegacyIntroScreen.routeAnchorId).context);

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
    if ((s.step == GuideStep.savedDetail ||
            s.step == GuideStep.updatedDetail) &&
        _targetIsCurrent(_resolveAnchor('detail.inlineGuide').context)) {
      return 'detail.inlineGuide';
    }
    if (s.step == GuideStep.savedDetail) {
      final confirm = _resolveAnchor('saved.confirm').context;
      if (_targetIsCurrent(confirm) && _targetIsVisible(confirm)) {
        return 'saved.confirm';
      }
      // Start on the saved event summary. The prep/departure card is farther
      // down and may be absent until its own data is available.
      final summary = _resolveAnchor('saved.summary').context;
      if (_targetIsCurrent(summary)) return 'saved.summary';
      final detail = _resolveAnchor('saved.departure').context;
      if (_targetIsCurrent(detail)) return 'saved.departure';
      final row = _resolveAnchor('home.saved').context;
      if (_targetIsCurrent(row)) return 'home.saved';
      final loading = _resolveAnchor('home.saved.loading').context;
      if (_targetIsCurrent(loading)) return 'home.saved.loading';
      final retry = _resolveAnchor('home.saved.retry').context;
      return _targetIsCurrent(retry) ? 'home.saved.retry' : 'home.saved';
    }
    if (s.step == GuideStep.editPreview) {
      if (_targetIsCurrent(_resolveAnchor('edit.inlineGuide').context)) {
        return 'edit.inlineGuide';
      }
      if (_targetIsCurrent(
          _resolveAnchor('detail.guideSaveProgress').context)) {
        return 'detail.guideSaveProgress';
      }
    }
    if (s.step == GuideStep.querySpeech) {
      final input = _resolveAnchor('voice.review').context;
      if (_targetIsCurrent(input)) return 'voice.review';
      if (_targetIsCurrent(_resolveAnchor('query.composer').context)) {
        return 'query.composer';
      }
      final retry = _resolveAnchor('query.retry').context;
      if (_targetIsCurrent(retry)) {
        final mic = _resolveAnchor('query.retryMic').context;
        return _targetIsCurrent(mic) ? 'query.retryMic' : 'query.retry';
      }
      return 'query.results';
    }
    return switch (s.step) {
      GuideStep.homeMic => 'home.mic',
      // Only the microphone button is lit: it is the control that actually
      // starts recognition. The transcript card and the disabled
      // "현재 내용으로 입력" button stay dimmed.
      GuideStep.createSpeech => 'voice.start',
      // correctAndSave selects its visible review fields and save controls
      // separately to keep the important/alarm/save sequence scroll-driven.
      GuideStep.queryMic => 'query.mic',
      GuideStep.queryResults || GuideStep.changeSpeech => 'query.composer',
      GuideStep.editPreview => 'edit.save',
      GuideStep.updatedDetail => 'updated.confirm',
      _ => null,
    };
  }

  (String, String) _copy(GuideSnapshot s, String id) {
    final saved = s.savedLocalDate;
    final date =
        saved == null ? null : (saved.isUtc ? planflowLocal(saved) : saved);
    final dateWords = date == null ? null : '${date.month}월 ${date.day}일';
    final retry = id == 'query.retry' ||
        id == 'query.retryMic' ||
        (id == 'query.composer' &&
            _targetIsCurrent(_resolveAnchor('query.retry').context));
    return switch (s.step) {
      GuideStep.homeMic => ('1/7 · 음성으로 입력 시작', '버튼을 눌러 음성으로 일정을 입력해보세요.'),
      GuideStep.createSpeech => ('1/7', ''),
      GuideStep.correctAndSave => (
          '2/7 · AI가 분류·저장',
          'AI가 시간·제목·장소를 알아서 분류했어요. 틀리면 직접 고칠 수 있어요.\n아래로 내려가 ‘중요한 일정으로 표시’와 ‘강한 알람’을 눌러보고, ‘일정 저장’을 눌러주세요.'
        ),
      GuideStep.savedDetail => (
          savedDetailGuideTitle,
          id == 'home.saved'
              ? '홈 탭에서 강조된 일정을 눌러 주세요.'
              : id == 'home.saved.retry'
                  ? '저장한 일정을 찾지 못했어요. ‘다시 확인’으로 기존 목록만 새로 불러와요. 새 일정은 만들지 않아요.'
                  : savedDetailGuideBody
        ),
      GuideStep.queryMic || GuideStep.querySpeech => (
          '4/7 · 음성으로 조회',
          retry
              ? dateWords == null
                  ? '조회 결과에 방금 저장한 일정이 없어요. 저장한 일정의 날짜로 다시 말해 주세요.'
                  : '조회 결과에 방금 저장한 일정이 없어요. “$dateWords 일정 보여줘”라고 다시 말해 주세요.'
              : dateWords == null
                  ? '마이크를 누르고 “내일 일정 보여줘”라고 말해주세요.'
                  : '마이크를 누르고 “$dateWords 일정 보여줘”라고 말해주세요.'
        ),
      GuideStep.queryResults => (
          '4/7 · 일정 다시 조회',
          dateWords == null
              ? '저장한 일정의 날짜를 말한 뒤 전송 버튼을 눌러 다시 조회해 주세요.'
              : '“$dateWords 일정 보여줘”라고 말한 뒤 전송 버튼을 눌러 다시 조회해 주세요.'
        ),
      GuideStep.changeSpeech => (
          '5/7 · 음성으로 변경',
          '방금 저장한 일정이 첫 번째로 보여요. “첫 번째 일정을 오후 5시로 변경해줘”라고 말해 보세요.'
        ),
      GuideStep.editPreview => (editPreviewGuideTitle, editPreviewGuideBody),
      GuideStep.updatedDetail => (
          updatedDetailGuideTitle,
          updatedDetailGuideBody
        ),
      GuideStep.completionConfirm ||
      GuideStep.syncChoice ||
      GuideStep.syncChoiceConfirmed ||
      GuideStep.completed =>
        ('마무리', '이것 말고도 더 많은 기능들이 있으니 확인해보세요.'),
      _ => ('실전 안내', '화면의 실제 내용을 확인해주세요.'),
    };
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GuideSnapshot>(
      valueListenable: coordinator.state,
      builder: (context, s, _) {
        widget.onWaitingPanelVisibilityChanged?.call(false);
        final legacyIntroCurrent = _legacyIntroIsCurrent();
        // 저장 화면 안내가 실제로 떠 있는지 여부. 편집기는 이 값이 true인
        // 동안에만 안내 단계(중요한 일정 → 강한 알림 → 저장)를 진행시킨다.
        final saveStageActive = !legacyIntroCurrent &&
            s.run == GuideRun.active &&
            s.step == GuideStep.correctAndSave;
        if (guideSaveStageActive.value != saveStageActive) {
          guideSaveStageActive.value = saveStageActive;
        }
        final saveProgress = guideSaveProgress.value;
        if (saveProgress != null &&
            identical(saveProgress.coordinator, coordinator) &&
            saveProgress.route.isCurrent) {
          return const SizedBox.shrink();
        }
        // The feature intro has its own buttons. Its route may appear before
        // the current guide target mounts, so suppress the waiting card too.
        if (legacyIntroCurrent ||
            _targetIsCurrent(_resolveAnchor('confirm.guidePending').context)) {
          return const SizedBox.shrink();
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
              pulseTargetIds: const <String>['voice.start'],
              blockOutsideTaps: false,
              bubble: const VoiceCorrectionExample(compact: true),
              progressLabel: '1/7',
              onSkip: null);
        }
        final id = _targetId(s);
        if ((_firstInlineRouteFrame && _isInlineGuideDestination(s)) ||
            id == 'home.saved.loading' ||
            id == 'detail.inlineGuide' ||
            id == 'edit.inlineGuide' ||
            id == 'detail.guideSaveProgress') {
          return const SizedBox.shrink();
        }
        final ({
          GuidedAnchorRegistry registry,
          BuildContext? context
        }) resolved = id == null
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
          widget.onWaitingPanelVisibilityChanged?.call(true);
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
                                    GuideInstructionText(widget.isGuideQa
                                        ? '안내할 실제 화면을 기다리고 있어요. 화면을 확인해 주세요.'
                                        : '안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 뒤로가기로 안내를 닫을 수 있어요.'),
                                    if (GuideRouteRecovery.supports(s) &&
                                        _atHome())
                                      TextButton(
                                          key: const ValueKey(
                                              'guide-bound-resume'),
                                          onPressed: _recoveringRoute
                                              ? null
                                              : _continueBoundGuide,
                                          child: Text(_recoveringRoute
                                              ? '안내를 불러오는 중…'
                                              : '안내 계속')),
                                    if (_routeRecoveryError != null)
                                      GuideInstructionText(
                                          _routeRecoveryError!),
                                  ]))))));
        }
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
          final stage = guideSaveStage.value;
          final actionTarget = _visibleSaveOption();
          final reviewTarget =
              actionTarget == null ? _visibleConfirmReviewTarget() : null;
          final bannerCopy = actionTarget == null
              ? (
                  '2/7 · 일정 확인',
                  '제목, 날짜·시간, 장소가 맞는지 확인해 주세요.\n확인했다면 아래로 스크롤해 주세요. ‘중요한 일정’ → ‘강한 알람’ → ‘일정 저장’ 순서로 안내할게요.'
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
          final bannerBody = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GuideInstructionText(bannerCopy.$2),
              if (actionTarget == null &&
                  !guideConfirmUserScrolled.value &&
                  _showConfirmScrollCue)
                const _ConfirmScrollCue(),
            ],
          );
          final guideTarget = actionTarget ?? reviewTarget;
          if (guideTarget != null) {
            final additionalTargets = reviewTarget != null
                ? _confirmReviewTargets
                    .where((id) => id != reviewTarget)
                    .toList(growable: false)
                : stage == GuideSaveStage.save
                    ? const <String>['confirm.save.top']
                    : const <String>[];
            return GuidedCoachmarkOverlay(
                registry: realUiGuideAnchorRegistry,
                targetId: guideTarget,
                additionalTargetIds: additionalTargets,
                pulseTargetIds: actionTarget == null
                    ? const <String>[]
                    : <String>[actionTarget, ...additionalTargets],
                preferBubbleBetweenTargets: additionalTargets.isNotEmpty,
                blockOutsideTaps: false,
                bubble: bannerBody,
                progressLabel: bannerCopy.$1,
                onSkip: null);
          }
          return Stack(children: [
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
                                                bannerBody,
                                              ])))),
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
          widget.onWaitingPanelVisibilityChanged?.call(true);
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
                                    GuideInstructionText(widget.isGuideQa
                                        ? '안내할 실제 화면을 기다리고 있어요. 화면을 확인해 주세요.'
                                        : '안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 뒤로가기로 안내를 닫을 수 있어요.'),
                                  ]))))));
        }
        if (s.step == GuideStep.editPreview) {
          return GuideEditPreviewCoachmark(registry: resolved.registry);
        }
        final copy = _copy(s, id);
        final conversationComposer = id == 'query.composer';
        final allowToolbarBack = !widget.isGuideQa &&
            (id.startsWith('voice.') || id.startsWith('query.')) &&
            _targetIsCurrent(_resolveAnchor('guide.back').context);
        final overlay = GuidedCoachmarkOverlay(
            registry: resolved.registry,
            targetId: id,
            pulseTargetIds: id == 'updated.confirm'
                ? const <String>['updated.confirm', 'updated.time']
                : conversationComposer
                    ? const <String>['query.retryMic', 'query.send']
                    : id == 'voice.start' || id == 'voice.review'
                        ? const <String>['voice.start', 'voice.submit']
                        : const <String>{
                            'home.mic',
                            'home.saved',
                            'home.saved.retry',
                            'saved.confirm',
                            'query.mic',
                            'query.retryMic',
                            'query.retry',
                          }.contains(id)
                            ? <String>[id]
                            : const <String>[],
            passThroughTargetIds: <String>[
              if (id == 'voice.start') 'voice.submit',
              if (allowToolbarBack) ...const ['guide.back', 'guide.exit'],
            ],
            blockOutsideTaps: id == 'home.mic' ||
                id == 'voice.start' ||
                id == 'query.mic' ||
                (conversationComposer && s.step == GuideStep.querySpeech) ||
                id == 'query.retryMic' ||
                id == 'query.retry' ||
                id == 'home.saved' ||
                id == 'home.saved.retry',
            preferBubbleBetweenTargets:
                id == 'saved.confirm' || id == 'updated.confirm',
            preferLowerBubbleSlot:
                id == 'saved.confirm' || id == 'updated.confirm',
            alignBubbleAboveTarget:
                id == 'saved.confirm' || id == 'updated.confirm',
            additionalTargetIds: id == 'saved.confirm'
                ? const <String>['saved.summary']
                : id == 'updated.confirm'
                    ? const <String>['updated.time']
                    : conversationComposer
                        ? const <String>['query.retryMic']
                        : s.step == GuideStep.querySpeech &&
                                id == 'voice.review'
                            ? const <String>['voice.start']
                            : const <String>[],
            bubble: s.step == GuideStep.createSpeech
                ? const VoiceCorrectionExample()
                : conversationComposer
                    ? GuideInstructionText.rich(TextSpan(children: [
                        TextSpan(text: '${copy.$2}\n\n'),
                        const TextSpan(
                          text: '말을 다 했다면 전송 버튼을 꼭 눌러 주세요.',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ]))
                    : GuideInstructionText(copy.$2),
            progressLabel: copy.$1,
            onSkip: null);
        if (!allowToolbarBack) return overlay;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding:
                media.padding.copyWith(top: media.padding.top + kToolbarHeight),
          ),
          child: overlay,
        );
      });
}

class _ConfirmScrollCue extends StatelessWidget {
  const _ConfirmScrollCue();

  @override
  Widget build(BuildContext context) {
    final arrow = Icon(
      Icons.keyboard_double_arrow_down_rounded,
      color: Theme.of(context).colorScheme.primary,
    );
    return SizedBox(
      key: const ValueKey('guide-confirm-scroll-cue'),
      height: 38,
      child: MediaQuery.disableAnimationsOf(context)
          ? Center(child: arrow)
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 900),
              builder: (context, value, child) {
                final bounce = 1 - (2 * value - 1).abs();
                return Center(
                  child: Transform.translate(
                    offset: Offset(0, 5 * Curves.easeInOut.transform(bounce)),
                    child: child,
                  ),
                );
              },
              child: arrow,
            ),
    );
  }
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

/// An earned ad reward may survive the background pause caused by displaying
/// the ad. It is still bound to the original account, screen and guide step.
Future<GuideSnapshot?> resumeGuideReplayAfterReward({
  required GuideCoordinator coordinator,
  required GuideSnapshot captured,
  required bool Function() stillOwnsScreen,
  required Listenable accountChanges,
}) async {
  final session = captured.sessionId;
  if (!captured.isReplay ||
      captured.run != GuideRun.active ||
      session == null) {
    return null;
  }
  final settled = Completer<GuideSnapshot?>();

  void check() {
    if (settled.isCompleted) return;
    final current = coordinator.state.value;
    final adPause = current.isReplay &&
        current.uid == captured.uid &&
        current.version == captured.version &&
        current.sessionId == session &&
        current.step == captured.step &&
        current.serverRevision == captured.serverRevision &&
        current.revision == captured.revision + 1 &&
        current.run == GuideRun.paused &&
        current.pauseReason == GuidePauseReason.background;
    if (!stillOwnsScreen() || (!identical(current, captured) && !adPause)) {
      settled.complete(null);
    } else {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
        settled.complete(current);
      }
    }
  }

  final listener = AppLifecycleListener(onStateChange: (_) => check());
  coordinator.state.addListener(check);
  accountChanges.addListener(check);
  GuideSnapshot? ready;
  try {
    check();
    ready =
        await settled.future.timeout(guideBeginTimeout, onTimeout: () => null);
  } finally {
    listener.dispose();
    coordinator.state.removeListener(check);
    accountChanges.removeListener(check);
  }
  if (ready == null ||
      !stillOwnsScreen() ||
      !identical(coordinator.state.value, ready)) {
    return null;
  }
  if (identical(ready, captured)) return captured;
  final resumed = await coordinator.dispatch(ResumeRequested(
      uid: captured.uid, sessionId: session, expectedRevision: ready.revision));
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (!stillOwnsScreen() ||
      (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
      !identical(coordinator.state.value, resumed) ||
      resumed.uid != captured.uid ||
      resumed.version != captured.version ||
      resumed.sessionId != session ||
      resumed.step != captured.step ||
      resumed.serverRevision != captured.serverRevision ||
      resumed.revision != ready.revision + 1 ||
      resumed.run != GuideRun.active ||
      !resumed.isReplay) {
    return null;
  }
  return resumed;
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
