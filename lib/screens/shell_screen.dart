import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/responsive.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/settings_repository.dart';
import '../providers/auth_provider.dart';
import '../services/app_permission_service.dart';
import '../services/briefing_scheduler_service.dart';
import '../services/calendar_auto_sync_service.dart';
import '../services/calendar_sync_service.dart';
import '../services/critical_alarm_channel_migration_service.dart';
import '../services/departure_acknowledgement_store.dart';
import '../services/departure_alarm_service.dart';
import '../services/external_calendar_sync_guide_service.dart';
import '../services/feature_tour_service.dart';
import '../services/manual_event_side_effect_service.dart';
import '../core/startup_route_gate.dart';
import '../services/onboarding_startup_gate.dart';
import '../services/interaction_idle_gate.dart';
import '../services/pending_departure_store.dart';
import '../l10n/app_l10n.dart';
import 'calendar/calendar_screen.dart';
import 'home/home_screen.dart';
import 'settings/settings_screen.dart';
import '../widgets/planflow_action_buttons.dart';

const _shellDestinations = <_ShellDestination>[
  _ShellDestination(
    label: '홈',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  _ShellDestination(
    label: '일정',
    icon: Icons.event_note_outlined,
    selectedIcon: Icons.event_note,
  ),
  _ShellDestination(
    label: '설정',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

const double _shellTabSwipeEdgeWidth = 24;

class _ShellDestination {
  const _ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class ShellScreen extends StatefulWidget {
  const ShellScreen({
    super.key,
    this.initialIndex = 0,
    this.initialCalendarDate,
    this.initialSettingsAction,
    this.briefingIsMorning,
  });

  final int initialIndex;
  final DateTime? initialCalendarDate;
  final SettingsInitialAction? initialSettingsAction;

  /// When set, the calendar tab runs the briefing inline instead of opening a
  /// separate result page. Null keeps the normal shell behavior.
  final bool? briefingIsMorning;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with WidgetsBindingObserver {
  // GoRouter may recreate ShellScreen for each bottom-tab route. These
  // process/session claims keep that implementation detail from rerunning
  // onboarding and expensive post-onboarding work for the same account.
  static String? _sessionOnboardingUserId;
  static Future<void>? _sessionOnboardingFlow;
  static String? _sessionDeferredWorkUserId;

  late int _currentIndex;
  late final List<Widget?> _tabChildren;
  late final ScrollController _homeScrollController;
  final AppPermissionService _permissionService = AppPermissionService();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  late final ExternalCalendarSyncGuideService _externalCalendarGuideService =
      ExternalCalendarSyncGuideService(
    calendarAutoSyncService: _calendarAutoSyncService,
  );
  final DepartureAlarmService _departureAlarmService =
      const DepartureAlarmService();
  final CriticalAlarmChannelMigrationService _criticalAlarmMigrationService =
      const CriticalAlarmChannelMigrationService();
  final BriefingSchedulerService _briefingSchedulerService =
      BriefingSchedulerService();
  final PendingDepartureStore _pendingDepartureStore =
      const SharedPreferencesPendingDepartureStore();
  final DepartureAcknowledgementStore _departureAckStore =
      const SharedPreferencesDepartureAcknowledgementStore();
  Timer? _pendingDepartureTimer;
  // 45초 타이머·resume·startup 세 경로가 동시에 pending을 읽어 같은 알람 화면을
  // 중복 push하는 레이스를 막는 재진입 가드.
  bool _pendingDepartureCheckInFlight = false;
  bool _checkedPermissionOnboarding = false;
  bool _checkedExternalCalendarGuide = false;
  bool _checkedGoogleCalendarAutoPrompt = false;
  bool _checkedFeatureTour = false;
  bool _postOnboardingStartupTasksQueued = false;
  final OnboardingStartupGate _startupGate = OnboardingStartupGate();
  final InteractionIdleGate _interactionIdleGate = InteractionIdleGate.instance;
  int _startupWorkGeneration = 0;
  String? _observedUserId;
  // 로그인 직후 홈이 깜빡였다가 온보딩으로 넘어가는 플래시를 막기 위해,
  // 온보딩 필요 여부 판단이 끝날 때까지 홈 대신 로딩 화면을 보여준다.
  bool _onboardingDecisionPending = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _homeScrollController = ScrollController(keepScrollOffset: false);
    _tabChildren = List<Widget?>.filled(3, null);
    _tabChildren[_currentIndex] = _buildTabChild(_currentIndex);
    _observedUserId = authProvider.userId;
    _onboardingDecisionPending =
        _observedUserId != null && _observedUserId!.isNotEmpty;
    if (_observedUserId != null &&
        _observedUserId!.isNotEmpty &&
        _sessionOnboardingUserId == _observedUserId) {
      _onboardingDecisionPending = false;
    }
    if (_onboardingDecisionPending) {
      startupRouteGate.beginStartupWorkDeferral();
    }
    WidgetsBinding.instance.addObserver(this);
    authProvider.addListener(_handleAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runSignedInStartupTasks(reason: 'app_start'));
    });
    _pendingDepartureTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_maybeShowPendingDepartureAlarm()),
    );
  }

  @override
  void dispose() {
    _startupWorkGeneration += 1;
    authProvider.removeListener(_handleAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _homeScrollController.dispose();
    _pendingDepartureTimer?.cancel();
    startupRouteGate.completeStartupWorkDeferral();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (_onboardingDecisionPending) return;
      // Resume recovery and deferred startup share one singleflight future.
      // _runAlarmRecovery() internally awaits _refreshDepartureAlarmsAndMonitor()
      // and _maybeShowPendingDepartureAlarm(). Briefing rescheduling is a
      // separate idempotent backstop (scheduleDaily is safe to call on every
      // resume) so it must never be dropped from this branch again — losing
      // it previously caused permanent silence until a cold start.
      unawaited(startupRouteGate.startupWorkAllowedWhenIdle.then((_) async {
        await _runAlarmRecovery();
        await _ensureBriefingsScheduled(reason: 'app_resumed');
      }));
    }
  }

  /// 출발 전용 알람이 백그라운드/포그라운드 전환 중에 알림 대신 곧바로
  /// 화면으로 뜰 수 있도록, 보류 중인 출발 알람 정보를 확인해 이동한다.
  Future<void> _maybeShowPendingDepartureAlarm() async {
    if (!mounted || _pendingDepartureCheckInFlight) return;
    _pendingDepartureCheckInFlight = true;
    try {
      final pending = await _pendingDepartureStore.read();
      if (pending == null) {
        return;
      }
      final age = DateTime.now().difference(pending.fireAt);
      if (age.isNegative || age > const Duration(minutes: 5)) {
        await _pendingDepartureStore.clear();
        return;
      }
      if (await _departureAckStore.isAcknowledged(pending.eventId)) {
        await _pendingDepartureStore.clear();
        return;
      }
      await _pendingDepartureStore.clear();
      if (!mounted) return;
      final uri = '${AppRoutes.departureAlarm}'
          '?eventId=${Uri.encodeComponent(pending.eventId)}'
          '&title=${Uri.encodeComponent(pending.title)}';
      context.go(uri);
    } finally {
      _pendingDepartureCheckInFlight = false;
    }
  }

  void _handleAuthChanged() {
    final currentUserId = authProvider.userId;
    if (_observedUserId == currentUserId) {
      return;
    }

    _observedUserId = currentUserId;
    _checkedPermissionOnboarding = false;
    _checkedExternalCalendarGuide = false;
    _checkedGoogleCalendarAutoPrompt = false;
    _checkedFeatureTour = false;
    _postOnboardingStartupTasksQueued = false;
    _startupGate.reset();
    _startupWorkGeneration += 1;

    // Only an actual auth identity transition resets the process-scoped
    // claims. Recreating ShellScreen for a tab change must not reset them.
    _sessionOnboardingUserId = null;
    _sessionOnboardingFlow = null;
    _sessionDeferredWorkUserId = null;

    if (!mounted) {
      return;
    }

    setState(() {
      _onboardingDecisionPending =
          currentUserId != null && currentUserId.isNotEmpty;
    });
    if (currentUserId != null && currentUserId.isNotEmpty) {
      startupRouteGate.beginStartupWorkDeferral();
    } else {
      startupRouteGate.completeStartupWorkDeferral();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_runSignedInStartupTasks(reason: 'auth_changed'));
      }
    });
  }

  Future<void> _runSignedInStartupTasks({required String reason}) async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    if (_sessionOnboardingUserId == userId) {
      if (mounted && _onboardingDecisionPending) {
        setState(() => _onboardingDecisionPending = false);
      }
      return;
    }
    final inFlight = _sessionOnboardingFlow;
    if (inFlight != null) {
      await inFlight;
      if (mounted && _onboardingDecisionPending) {
        setState(() => _onboardingDecisionPending = false);
      }
      return;
    }

    final flow = _performSignedInStartupTasks(reason: reason, userId: userId);
    _sessionOnboardingFlow = flow;
    try {
      await flow;
    } finally {
      if (identical(_sessionOnboardingFlow, flow)) {
        _sessionOnboardingFlow = null;
      }
    }
  }

  Future<void> _performSignedInStartupTasks({
    required String reason,
    required String userId,
  }) async {
    final startedAt = DateTime.now();
    var flowCompleted = false;
    try {
      await _maybeOpenFeatureTour();
      if (!mounted) {
        return;
      }
      await _maybeOpenPermissionOnboarding();
      if (!mounted) {
        return;
      }
      await _maybeShowExternalCalendarSyncGuide();
      flowCompleted = true;
    } finally {
      // Always release the route gate, including onboarding/prefs exceptions.
      // Nonessential platform work has its own settled-idle permit, so this
      // cannot strand the app behind a permanent startup lock.
      startupRouteGate.completeStartupWorkDeferral();
      if (mounted) {
        _clearOnboardingGate();
        if (flowCompleted && authProvider.userId == userId) {
          _sessionOnboardingUserId = userId;
        }
        DiagLogger.log(
          'Onboarding',
          'gate released in ${DateTime.now().difference(startedAt).inMilliseconds}ms',
        );
      }
      if (flowCompleted) {
        _queuePostOnboardingStartupTasks(
          reason: reason,
          generation: _startupWorkGeneration,
        );
      }
    }
  }

  void _queuePostOnboardingStartupTasks({
    required String reason,
    required int generation,
  }) {
    final userId = authProvider.userId;
    if (userId == null ||
        userId.isEmpty ||
        _sessionDeferredWorkUserId == userId) {
      return;
    }
    _sessionDeferredWorkUserId = userId;
    if (_postOnboardingStartupTasksQueued) {
      return;
    }
    _postOnboardingStartupTasksQueued = true;
    unawaited(
      _startupGate
          .runAfterFirstHomeFrame(
        () => _runDeferredStartupTasks(
          reason: reason,
          generation: generation,
        ),
      )
          .catchError((Object error, StackTrace stackTrace) {
        // A failed deferred task must not consume the session claim. The next
        // resume/auth lifecycle can retry after the transient failure.
        if (_sessionDeferredWorkUserId == userId) {
          _sessionDeferredWorkUserId = null;
        }
        _postOnboardingStartupTasksQueued = false;
        DiagLogger.log('Onboarding', 'deferred startup failed; claim cleared');
        debugPrintStack(stackTrace: stackTrace);
      }),
    );
  }

  Future<void> _runDeferredStartupTasks({
    required String reason,
    required int generation,
  }) async {
    DiagLogger.log('Onboarding', 'deferred startup begin reason=$reason');
    final userId = authProvider.userId;
    if (!mounted ||
        generation != _startupWorkGeneration ||
        userId == null ||
        userId.isEmpty) {
      throw StateError('deferred startup became obsolete');
    }
    // Leave the first home frame completely quiet before releasing the global
    // startup permit. A frame being drawn does not mean the user has stopped
    // interacting, so require a short grace period plus a settled idle window.
    await Future<void>.delayed(const Duration(seconds: 1));
    await _interactionIdleGate.waitForStableIdle();
    if (!mounted ||
        generation != _startupWorkGeneration ||
        authProvider.userId != userId) {
      DiagLogger.log(
        'Onboarding',
        'deferred startup cancelled before gate release',
      );
      throw StateError('deferred startup became obsolete');
    }
    startupRouteGate.completeStartupWorkDeferral();
    // CalendarAutoSyncService is owned by PlanFlowApp.  Shell instances can
    // be recreated when navigation changes, so starting it here caused each
    // recreation to compete for the UI isolate and CalDAV parser.
    Future<bool> runWhenIdle(Future<void> Function() work) async {
      final idleGeneration = _interactionIdleGate.generation;
      await _interactionIdleGate.waitForIdle();
      if (!mounted ||
          generation != _startupWorkGeneration ||
          authProvider.userId != userId ||
          idleGeneration != _interactionIdleGate.generation) {
        DiagLogger.log('Onboarding', 'deferred startup task cancelled');
        throw StateError('deferred startup cancelled by interaction');
      }
      await work();
      return true;
    }

    await runWhenIdle(_migrateFutureCriticalAlarms);
    await runWhenIdle(_runAlarmRecovery);
    await runWhenIdle(() => _ensureBriefingsScheduled(reason: reason));
    if (reason == 'app_start') {
      await runWhenIdle(_maybeRecalculateAllAlarms);
    }
    await runWhenIdle(_maybeAutoConnectGoogleCalendar);
  }

  Future<void> _maybeOpenFeatureTour() async {
    if (_checkedFeatureTour || !mounted) return;
    _checkedFeatureTour = true;
    final shouldShow =
        await const SharedPreferencesFeatureTourStore().shouldShow();
    if (shouldShow && mounted) {
      await context.push(AppRoutes.featureTour);
    }
  }

  Future<void> _maybeRecalculateAllAlarms() async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) return;
    try {
      const key = 'alarm_recalc_last_run';
      final prefs = await SharedPreferences.getInstance();
      final lastRun = prefs.getInt(key) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastRun < const Duration(hours: 24).inMilliseconds) return;
      await ManualEventSideEffectService().recalculateUpcomingAlarmsForUser(
        userId: userId,
      );
      await prefs.setInt(key, now);
    } catch (error, stackTrace) {
      debugPrint('Alarm recalculation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _maybeAutoConnectGoogleCalendar() async {
    debugPrint('[GCAL] _maybeAutoConnect 진입');
    if (_checkedGoogleCalendarAutoPrompt || !mounted) {
      debugPrint(
        '[GCAL] return: alreadyChecked=$_checkedGoogleCalendarAutoPrompt '
        'mounted=$mounted',
      );
      return;
    }
    _checkedGoogleCalendarAutoPrompt = true;

    // Google 계정이 아니면 스킵
    debugPrint('[GCAL] isGoogleAccount=${authProvider.isGoogleAccount}');
    if (!authProvider.isGoogleAccount) {
      debugPrint('[GCAL] return: isGoogleAccount=false');
      return;
    }

    final userId = authProvider.userId;
    debugPrint('[GCAL] userId=$userId');
    if (userId == null || userId.isEmpty) {
      debugPrint('[GCAL] return: userId is null or empty');
      return;
    }

    // Google Calendar 연동 상태 확인
    final calendarSync = CalendarSyncService(
      googleServerClientId: AppEnv.googleServerClientId,
    );
    final status = await calendarSync.getGoogleStatus();
    final isConnected = status.status == CalendarIntegrationStatus.ready ||
        status.status == CalendarIntegrationStatus.synced;
    debugPrint(
      '[GCAL] googleStatus=${status.status} isConnected=$isConnected',
    );
    if (isConnected) {
      // 이미 연동됐으면 종료
      debugPrint('[GCAL] return: already connected');
      return;
    }

    // Startup/resume must never open the account picker. Interactive Google
    // sign-in is reserved for the explicit Calendar sync button in Settings;
    // this status probe is intentionally silent and leaves an unlinked account
    // for the user to connect on demand.
    debugPrint(
      '[GCAL] startup status check complete; interactive sign-in deferred '
      'to explicit Calendar sync action',
    );
  }

  Future<void> _refreshDepartureAlarmsAndMonitor() async {
    final result = await _departureAlarmService.refreshUpcoming();
    await _departureAlarmService.scheduleNextMonitor(
      interval: result.nextMonitorInterval,
    );
  }

  Future<void>? _alarmRecoveryFuture;

  Future<void> _runAlarmRecovery() {
    final existing = _alarmRecoveryFuture;
    if (existing != null) return existing;
    final future = () async {
      await _refreshDepartureAlarmsAndMonitor();
      await _maybeShowPendingDepartureAlarm();
    }();
    late final Future<void> tracked;
    tracked = future.whenComplete(() {
      if (identical(_alarmRecoveryFuture, tracked)) _alarmRecoveryFuture = null;
    });
    _alarmRecoveryFuture = tracked;
    return tracked;
  }

  Future<void> _migrateFutureCriticalAlarms() async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    await _criticalAlarmMigrationService.migrateFutureCriticalAlarmsIfNeeded(
      userId,
    );
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialIndex != widget.initialIndex &&
        _currentIndex != widget.initialIndex) {
      setState(() {
        _currentIndex = widget.initialIndex;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabChildren[_currentIndex] == null) {
          setState(() =>
              _tabChildren[_currentIndex] = _buildTabChild(_currentIndex));
        }
      });
    }
    if (oldWidget.initialCalendarDate != widget.initialCalendarDate &&
        widget.initialCalendarDate != null &&
        _currentIndex != 1) {
      setState(() {
        _currentIndex = 1;
      });
    }
  }

  void _showHomeAtTop() {
    if (!_homeScrollController.hasClients) {
      return;
    }

    _homeScrollController.jumpTo(0);
  }

  void _goToTab(int index) {
    if (index == _currentIndex) {
      return;
    }
    setState(() {
      _currentIndex = index;
    });
    // Keep this Shell alive while switching tabs. The inactive tab gets a
    // cheap placeholder for the transition frame and is mounted afterward.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (index == 0) _showHomeAtTop();
      if (_tabChildren[index] == null) {
        setState(() => _tabChildren[index] = _buildTabChild(index));
      }
    });
  }

  void _handleTabSwipe(DragEndDetails details) {
    final velocityX = details.primaryVelocity ?? 0;
    if (velocityX.abs() < 250) {
      return;
    }
    if (velocityX < 0) {
      _goToTab((_currentIndex + 1).clamp(0, 2));
    } else {
      _goToTab((_currentIndex - 1).clamp(0, 2));
    }
  }

  Future<void> _maybeOpenPermissionOnboarding() async {
    if (_checkedPermissionOnboarding || !mounted) {
      return;
    }
    _checkedPermissionOnboarding = true;

    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    try {
      final completed = await _permissionService.isOnboardingCompleted(userId);
      if (!mounted) {
        return;
      }
      // 게이트 해제(_clearOnboardingGate)는 이제 _runSignedInStartupTasks의
      // finally에서 담당한다 — 여기서 해제하면 온보딩 push 직전에 홈이
      // 1~2 프레임 깜빡이는 원인이 된다(2026-08-12 회귀).
      if (!completed && mounted) {
        await context.push(AppRoutes.permissionOnboarding);
      }
    } catch (error, stackTrace) {
      debugPrint('Permission onboarding check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _clearOnboardingGate() {
    if (!mounted || !_onboardingDecisionPending) {
      return;
    }
    setState(() {
      _onboardingDecisionPending = false;
    });
  }

  Future<void> _maybeShowExternalCalendarSyncGuide() async {
    if (_checkedExternalCalendarGuide || !mounted) {
      return;
    }
    _checkedExternalCalendarGuide = true;

    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final shouldShow =
        await _externalCalendarGuideService.shouldShowForUser(userId);
    if (!shouldShow || !mounted) {
      return;
    }

    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('외부 캘린더 동기화 안내'),
          content: const Text(
            '기존에 다른 캘린더 프로그램(구글, 네이버, 삼성)을 쓰고 계셨다면 '
            '일정 동기화를 위해 설정탭에서 동기화를 진행해 주세요.',
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '동기화 안 함',
                  onPressed: () => Navigator.of(context).pop(false),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  label: '동기화 설정',
                  onPressed: () => Navigator.of(context).pop(true),
                  type: ActionButtonType.primary,
                  flex: 1,
                ),
              ],
            ),
          ],
        );
      },
    );

    await _externalCalendarGuideService.markSeen(userId);
    if (!mounted) {
      return;
    }

    if (openSettings == true) {
      context.go('${AppRoutes.settings}?open=naver-caldav');
    }
  }

  /// Google 계정 로그인 사용자이고 Google Calendar가 미연동 상태이면
  /// interactive sync를 1회 자동 호출해 팝업을 띄운다.
  List<NavigationDestination> _buildNavigationBarDestinations() {
    final labels = _localizedDestinationLabels();
    return _shellDestinations.indexed
        .map(
          (entry) => NavigationDestination(
            icon: Icon(entry.$2.icon),
            selectedIcon: Icon(entry.$2.selectedIcon),
            label: labels[entry.$1],
          ),
        )
        .toList(growable: false);
  }

  List<String> _localizedDestinationLabels() {
    final l10n = appL10n(context);
    return <String>[l10n.homeTab, l10n.calendarTab, l10n.settingsTab];
  }

  List<NavigationRailDestination> _buildNavigationRailDestinations() {
    final labels = _localizedDestinationLabels();
    return _shellDestinations.indexed
        .map(
          (entry) => NavigationRailDestination(
            icon: Icon(entry.$2.icon),
            selectedIcon: Icon(entry.$2.selectedIcon),
            label: Text(labels[entry.$1]),
          ),
        )
        .toList(growable: false);
  }

  Widget _buildShellBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        IndexedStack(
          index: _currentIndex,
          children: List<Widget>.generate(
            3,
            (index) => _tabChildren[index] ?? const SizedBox.shrink(),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _shellTabSwipeEdgeWidth,
          child: _ShellTabSwipeEdge(
            key: const Key('shell-left-swipe-edge'),
            onHorizontalDragEnd: _handleTabSwipe,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: _shellTabSwipeEdgeWidth,
          child: _ShellTabSwipeEdge(
            key: const Key('shell-right-swipe-edge'),
            onHorizontalDragEnd: _handleTabSwipe,
          ),
        ),
      ],
    );
  }

  Widget _buildTabChild(int index) {
    switch (index) {
      case 0:
        return HomeScreen(scrollController: _homeScrollController);
      case 1:
        final briefingIsMorning = widget.briefingIsMorning;
        final calendar = CalendarScreen(
          initialDate: widget.initialCalendarDate,
          // The briefing route opens the selected-day agenda sheet itself;
          // the loader lives inside that sheet rather than over the month
          // grid. Normal CalendarScreen callers may still use
          // suppressInitialDaySheet for non-briefing flows.
          briefingIsMorning: briefingIsMorning,
        );
        return calendar;
      case 2:
        return SettingsScreen(
          key: ValueKey<String?>(
            'settings-${authProvider.userId}-'
            '${widget.initialSettingsAction?.name ?? 'none'}',
          ),
          userId: authProvider.userId,
          initialAction: widget.initialSettingsAction,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildBottomNavigationBar() {
    return NavigationBar(
      selectedIndex: _currentIndex,
      onDestinationSelected: _goToTab,
      destinations: _buildNavigationBarDestinations(),
    );
  }

  Widget _buildNavigationRail(PlanFlowResponsiveSize layoutSize) {
    final extended = layoutSize == PlanFlowResponsiveSize.expanded;

    return SafeArea(
      child: NavigationRail(
        selectedIndex: _currentIndex,
        onDestinationSelected: _goToTab,
        labelType: extended ? null : NavigationRailLabelType.selected,
        extended: extended,
        minWidth: 72,
        minExtendedWidth: 208,
        destinations: _buildNavigationRailDestinations(),
      ),
    );
  }

  Future<void> _ensureBriefingsScheduled({required String reason}) async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      debugPrint('Briefing schedule skipped ($reason): signed out');
      return;
    }

    try {
      final settings = await _loadBriefingSettings(userId);
      final result = await _briefingSchedulerService.scheduleDaily(
        morningTime: settings.morningBriefingAt,
        eveningTime: settings.eveningBriefingAt,
        userId: userId,
      );
      debugPrint(
        'Briefing schedule ensured ($reason): '
        'morning=${result.morning.scheduledAt.toIso8601String()} '
        'scheduled=${result.morning.scheduled}, '
        'evening=${result.evening.scheduledAt.toIso8601String()} '
        'scheduled=${result.evening.scheduled}, userId=$userId',
      );
    } catch (error, stackTrace) {
      debugPrint('Briefing schedule setup skipped ($reason): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<UserSettingsModel> _loadBriefingSettings(String userId) async {
    if (!AppEnv.isSupabaseReady) {
      return UserSettingsModel.defaults(userId: userId);
    }

    try {
      final repository = SettingsRepository.supabase();
      return await repository.fetchSettings(userId) ??
          UserSettingsModel.defaults(userId: userId);
    } catch (error, stackTrace) {
      debugPrint('Briefing settings load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return UserSettingsModel.defaults(userId: userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingDecisionPending) {
      // 로그인 직후 온보딩 여부 판단 중에는 홈 대신 로딩 화면을 보여줘
      // 홈이 깜빡였다가 온보딩으로 넘어가는 플래시를 막는다.
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('로딩 중'),
            ],
          ),
        ),
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _interactionIdleGate.notifyInteraction(),
      onPointerMove: (_) => _interactionIdleGate.notifyInteraction(),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            return;
          }
          if (_currentIndex != 0) {
            setState(() {
              _currentIndex = 0;
            });
            if (_tabChildren[0] == null) {
              setState(() => _tabChildren[0] = _buildTabChild(0));
            }
            return;
          }
          SystemNavigator.pop();
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final windowInfo = PlanFlowResponsive.windowInfoOf(
              context,
              constraints: constraints,
            );
            final layoutSize = windowInfo.sizeClass;
            final useRail = windowInfo.useNavigationRail;

            return Scaffold(
              body: useRail
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildNavigationRail(layoutSize),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Expanded(child: _buildShellBody()),
                      ],
                    )
                  : _buildShellBody(),
              bottomNavigationBar: useRail ? null : _buildBottomNavigationBar(),
            );
          },
        ),
      ),
    );
  }
}

class _ShellTabSwipeEdge extends StatelessWidget {
  const _ShellTabSwipeEdge({
    super.key,
    required this.onHorizontalDragEnd,
  });

  final GestureDragEndCallback onHorizontalDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: onHorizontalDragEnd,
      child: const SizedBox.expand(),
    );
  }
}
