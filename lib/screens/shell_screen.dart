import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
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
  });

  final int initialIndex;
  final DateTime? initialCalendarDate;
  final SettingsInitialAction? initialSettingsAction;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with WidgetsBindingObserver {
  late int _currentIndex;
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
  String? _observedUserId;
  // 로그인 직후 홈이 깜빡였다가 온보딩으로 넘어가는 플래시를 막기 위해,
  // 온보딩 필요 여부 판단이 끝날 때까지 홈 대신 로딩 화면을 보여준다.
  bool _onboardingDecisionPending = false;
  // 온보딩 게이트 안전망 타이머. 권한 온보딩/튜토리얼 push Future가
  // 기기별 context.go() 복귀 경로에서 영원히 완료되지 않는(=게이트가 영구히
  // 닫혀 로딩 화면에 갇히는) 실패 모드를 막는다. _runSignedInStartupTasks
  // 시작 시 5초 후 강제 해제로 예약하고, 정상 종료 시 취소한다.
  Timer? _onboardingGateSafetyTimer;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _homeScrollController = ScrollController(keepScrollOffset: false);
    _observedUserId = authProvider.userId;
    _onboardingDecisionPending =
        _observedUserId != null && _observedUserId!.isNotEmpty;
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
    authProvider.removeListener(_handleAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _homeScrollController.dispose();
    _pendingDepartureTimer?.cancel();
    _onboardingGateSafetyTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(_calendarAutoSyncService.syncConnectedCalendars(
        reason: 'app_resumed',
      ));
      unawaited(_refreshDepartureAlarmsAndMonitor());
      unawaited(_maybeShowPendingDepartureAlarm());
      // 브리핑 알람은 "알람 콜백이 스스로 다음 날 것을 재예약"하는 체인
      // 하나에만 의존했다 — 그 체인이 한 번이라도 조용히 끊기면(스케줄
      // 실패·예외) 콜드스타트/설정 재저장 전까지 영구히 무음이 됐다(반복
      // 신고 5회째). scheduleDaily는 멱등이라(이미 맞게 예약돼 있으면
      // 그대로 두거나 동일하게 재예약) resume마다 불러도 안전하며, 이걸로
      // 앱을 여는 것 자체가 재예약 백스톱이 된다.
      unawaited(_ensureBriefingsScheduled(reason: 'app_resumed'));
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

    if (!mounted) {
      return;
    }

    setState(() {
      _onboardingDecisionPending =
          currentUserId != null && currentUserId.isNotEmpty;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_runSignedInStartupTasks(reason: 'auth_changed'));
      }
    });
  }

  Future<void> _runSignedInStartupTasks({required String reason}) async {
    // 온보딩 게이트 안전망: 권한 온보딩/튜토리얼 push Future가 기기별
    // context.go() 복귀 경로에서 영원히 완료되지 않는(=게이트가 영원히
    // 닫혀 로딩 화면에 갇히는) 실패를 막기 위한 최후의 보루. 정상 경로에서는
    // 아래 try 블록의 finally에서 게이트를 해제하고 이 타이머를 취소한다.
    // 하지만 어떤 이유로든(예외, await 중 위젯 dispose, context.go 복귀 지연)
    // 게이트가 5초 안에 풀리지 않으면 강제로 해제해 사용자가 홈에 도달한다.
    _onboardingGateSafetyTimer?.cancel();
    _onboardingGateSafetyTimer = Timer(
      const Duration(seconds: 5),
      () {
        if (mounted) {
          debugPrint(
            '[OnboardingGate] safety timer fired — forcing gate release '
            '(reason=$reason)',
          );
          _clearOnboardingGate();
        }
      },
    );

    try {
      await _maybeOpenPermissionOnboarding();
      if (!mounted) {
        return;
      }
      await _maybeOpenFeatureTour();
      if (!mounted) {
        return;
      }
      unawaited(_calendarAutoSyncService.syncConnectedCalendars(
        reason: reason,
        force: reason == 'auth_changed',
      ));
      unawaited(_migrateFutureCriticalAlarms());
      unawaited(_refreshDepartureAlarmsAndMonitor());
      unawaited(_maybeShowPendingDepartureAlarm());
      unawaited(_ensureBriefingsScheduled(reason: reason));
      if (reason == 'app_start') {
        unawaited(_maybeRecalculateAllAlarms());
      }
      debugPrint('[GCAL] _maybeAutoConnect 호출 시도 ($reason)');
      unawaited(_maybeAutoConnectGoogleCalendar());
    } finally {
      // 모든 온보딩 결정이 끝난 뒤(또는 예외 발생 시) 게이트를 해제한다.
      // 온보딩 push가 발생했더라도 결국엔 사용자가 온보딩을 완료하고
      // context.go(AppRoutes.home)로 돌아올 때 이 ShellScreen이 재사용되므로,
      // 그 시점에 게이트가 이미 열려있어야 홈이 보인다. push Future가
      // context.go 복귀를 만나 영원히 완료되지 않는 기기에서는 안전망
      // 타이머가 5초 후에 이 코드를 대신해 게이트를 연다.
      _onboardingGateSafetyTimer?.cancel();
      if (mounted) {
        _clearOnboardingGate();
      }
    }
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
    switch (index) {
      case 0:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showHomeAtTop();
          }
        });
        context.go(AppRoutes.home);
        break;
      case 1:
        context.go(AppRoutes.calendar);
        break;
      case 2:
        context.go(AppRoutes.settings);
        break;
    }
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

    if (mounted) {
      await _maybeShowExternalCalendarSyncGuide();
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
          children: [
            HomeScreen(scrollController: _homeScrollController),
            CalendarScreen(initialDate: widget.initialCalendarDate),
            SettingsScreen(
              key: ValueKey<String?>(
                'settings-${authProvider.userId}-'
                '${widget.initialSettingsAction?.name ?? 'none'}',
              ),
              userId: authProvider.userId,
              initialAction: widget.initialSettingsAction,
            ),
          ],
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_currentIndex != 0) {
          setState(() {
            _currentIndex = 0;
          });
          context.go(AppRoutes.home);
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
