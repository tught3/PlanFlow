import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:home_widget/home_widget.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:planflow/l10n/app_localizations.dart';

import 'core/constants.dart';
import 'core/diag_logger.dart';
import 'core/env.dart';
import 'core/region_settings.dart';
import 'core/router.dart';
import 'core/safe_prefs.dart';
import 'core/startup_route_gate.dart';
import 'core/home_widget_route_coordinator.dart';
import 'core/theme.dart';

// 순수 헬퍼(enum/도착 확인 resolver/queryParametersEqual/소비 게이트)는
// coordinator 파일로 이동했다. 기존에 app.dart에서 이 심볼들을 import하던
// 경로의 호환을 위해 재노출한다.
export 'core/home_widget_route_coordinator.dart'
    show HomeWidgetArrivalCheckResult,
        resolveHomeWidgetArrivalCheckResult,
        shouldConsumeHomeWidgetLaunch,
        queryParametersEqual;
import 'data/repositories/settings_repository.dart';
import 'features/groups/services/group_calendar_widget_service.dart';
import 'providers/auth_provider.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/app_feedback_service.dart';
import 'services/briefing_scheduler_service.dart';
import 'services/event_reminder_channel_migration_service.dart';
import 'services/activity_tracking_service.dart';
import 'services/smart_preparation_payload_migration_service.dart';
import 'services/naver_ics_share_store.dart';
import 'services/notification_service.dart';
import 'services/notification_route_contract.dart';
import 'services/interaction_idle_gate.dart';
import 'services/oauth_callback_handler.dart';
import 'services/update_service.dart';
import 'services/ios_app_store_update_service.dart';
import 'widgets/planflow_action_buttons.dart';
import 'widgets/ios_app_store_update_prompt.dart';

HomeWidgetRouteReadiness resolveAppHomeWidgetReadiness({
  required AuthProvider auth,
  required StartupRouteGate gate,
  required bool supabaseReady,
}) {
  if (!supabaseReady || !auth.hasResolvedInitialSession) {
    return HomeWidgetRouteReadiness.notReady;
  }
  if (!auth.isSignedIn) return HomeWidgetRouteReadiness.needsAuth;
  return gate.requiredSetupCompleteFor(auth.userId)
      ? HomeWidgetRouteReadiness.ready
      : HomeWidgetRouteReadiness.notReady;
}

/// Visible top-of-stack location used for widget-route arrival checks.
///
/// `routeInformationProvider.value` is NOT reliable after an imperative
/// push: once the pushed page is built, go_router (13.x, with
/// optionURLReflectsImperativeAPIs=false) silently reports the base
/// configuration uri (e.g. /home) back into the provider, so an arrival check
/// that runs after the frame sees the base location and re-pushes the target.
/// The delegate's current configuration keeps the pushed match.
Uri currentAppRouterLocation(GoRouter router) {
  final configuration = router.routerDelegate.currentConfiguration;
  if (configuration.isEmpty) {
    return router.routeInformationProvider.value.uri;
  }
  RouteMatchBase last = configuration.matches.last;
  while (last is ShellRouteMatch && last.matches.isNotEmpty) {
    last = last.matches.last;
  }
  if (last is ImperativeRouteMatch) {
    return last.matches.uri;
  }
  return configuration.uri;
}

/// While a resolved signed-in account is still completing required setup
/// (tour/permission onboarding in the Shell), the widget launch hold must not
/// keep suppressing redirects: the app has to reach HOME so the Shell can run
/// that setup. Releasing the hold neither consumes nor navigates the pending
/// target (the coordinator retains it and replays on the gate's completion
/// notification) and re-enables, not bypasses, the normal router guards.
/// Returns true when the hold should be released.
bool shouldReleaseWidgetHoldAwaitingRequiredSetup({
  required HomeWidgetRouteReadiness readiness,
  required AuthProvider auth,
  required StartupRouteGate gate,
  required bool supabaseReady,
}) {
  return readiness == HomeWidgetRouteReadiness.notReady &&
      supabaseReady &&
      auth.hasResolvedInitialSession &&
      auth.isSignedIn &&
      gate.widgetLaunchPending &&
      !gate.requiredSetupCompleteFor(auth.userId);
}

/// Seeds HOME and queues one push owned by the current submission.
/// Capture before seeding: router notifications may synchronously supersede it.
void seedHomeAndDeferHomeWidgetPush({
  required String route,
  required HomeWidgetRouteCoordinator Function() currentCoordinator,
  required bool Function() isMounted,
  required VoidCallback seedHome,
  required void Function(String route) push,
}) {
  final coordinator = currentCoordinator();
  final generation = coordinator.generation;
  seedHome();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!isMounted() ||
        !identical(currentCoordinator(), coordinator) ||
        coordinator.generation != generation ||
        coordinator.pendingRoute != route) {
      return;
    }
    push(route);
  });
}

class PlanFlowApp extends StatefulWidget {
  const PlanFlowApp({super.key});

  @override
  State<PlanFlowApp> createState() => _PlanFlowAppState();
}

class _PlanFlowAppState extends State<PlanFlowApp> {
  static const String _pendingUpdateRestoreRouteKey =
      'startup:update_restore_route';
  static const int _homeWidgetArrivalMaxAttempts = 10;
  // 라우터/Supabase/세션이 모두 준비될 때까지 기다릴 최대 시간. 이 시간 안에
  // ready가 되지 않으면 pending은 소비되지 않고 RETAINED로 보존된다(타임아웃이
  // 곧 성공/소비를 의미하지 않는다). 도착 확인 재시도(1.2초)보다 훨씬 길게
  // 잡아, 콜드스타트 직후 Supabase 초기화 지연/네트워크 지연으로 readiness가
  // 늦게 도착하는 경우에도 pending URI(선택 date/voice autoStart 포함)가
  // 사라지지 않게 한다.
  static const Duration _homeWidgetReadinessMaxWait = Duration(seconds: 15);
  // RETAINED 상태에서는 auth/gate 변화 또는 foreground resume으로 이벤트
  // 기반 재시도하므로 로그인/온보딩에 무한 갇히지 않는다.

  StreamSubscription<Uri?>? _homeWidgetClickSubscription;
  StreamSubscription<Uri>? _planFlowLinkSubscription;
  StreamSubscription<List<SharedMediaFile>>? _sharedIcsSubscription;
  StreamSubscription<bool>? _foregroundBriefingSubscription;
  Timer? _foregroundBriefingPollTimer;
  bool _reauthSnackBarShown = false;
  bool _startupUpdateCheckRunning = false;
  int _startupUpdateCheckGeneration = 0;
  bool _startupSessionSyncRunning = false;
  int _startupSessionSyncGeneration = 0;
  final AppLinks _appLinks = AppLinks();
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  final NaverIcsShareStore _naverIcsShareStore = const NaverIcsShareStore();
  bool _briefingDialogShowing = false;
  final NotificationService _notificationService = NotificationService();
  final ActivityTrackingService _activityTrackingService =
      ActivityTrackingService();
  final InteractionIdleGate _interactionIdleGate = InteractionIdleGate.instance;
  late final AppLifecycleListener _lifecycleListener;
  String? _lastHandledHomeWidgetRoute;
  DateTime? _lastHandledHomeWidgetRouteAt;
  bool? _homeWidgetShouldSeedHomeBase;
  // pending 위젯 라우트의 상태(pending target/generation/deferral/도착 확인/
  // givingUp 보존)를 coordinator가 온전히 소유한다. 앱은 readiness 판정,
  // 실제 네비게이션, 로그인 리다이렉트, 게이트 해제 콜백만 주입한다.
  // givingUp은 이제 소비/clear가 아니라 RETAINED(보존)이며, auth/gate 변화
  // 또는 foreground resume(kickPendingRoute) 때 이벤트 기반으로 재시도한다.
  late final HomeWidgetRouteCoordinator _homeWidgetRouteCoordinator =
      HomeWidgetRouteCoordinator(
    readinessResolver: _resolveHomeWidgetReadiness,
    wakeSignal: Listenable.merge(<Listenable>[authProvider, startupRouteGate]),
    navigate: _navigatePendingHomeWidgetRoute,
    currentUri: () => currentAppRouterLocation(appRouter),
    consume: (route) =>
        _consumeHomeWidgetLaunch(reason: 'arrival_confirmed route=$route'),
    onDeferred: _onHomeWidgetRouteDeferred,
    onTerminal: _onHomeWidgetRouteTerminal,
    arrivalMaxAttempts: _homeWidgetArrivalMaxAttempts,
    readinessTimeout: _homeWidgetReadinessMaxWait,
  );
  final Map<String, Future<void>> _startupLifecycleJobs =
      <String, Future<void>>{};

  @override
  void initState() {
    super.initState();
    _oauthCallbackHandler.start();
    authProvider.addListener(_onAuthProviderChange);
    startupRouteGate.addListener(_onStartupRouteGateChange);
    // 보존(retained)된 위젯 라우트가 온보딩 완료 등으로 정확히 목적지에 도착한
    // 경우 확인/소비할 수 있게 한다(확인 전용, 네비게이션/예산 리셋 없음).
    appRouter.routeInformationProvider.addListener(_onRouterLocationChanged);
    appRouter.routerDelegate.addListener(_onRouterLocationChanged);
    _lifecycleListener = AppLifecycleListener(
      onPause: () {
        unawaited(_deferStartupLifecycleWork(
          'foreground_state',
          () => BriefingSchedulerService.recordAppForegroundState(false),
        ));
      },
      onResume: () {
        unawaited(_deferStartupLifecycleWork('resume', () async {
          await _markForegroundAndCheckPendingBriefing();
          await _resumeHomeWidgetCheck();
          await _activityTrackingService.recordActive();
        }));
        unawaited(_scheduleDeferredSessionSync(reason: 'foreground_idle'));
        unawaited(_scheduleDeferredUpdateCheck());
      },
    );
    _foregroundBriefingSubscription = BriefingSchedulerService
        .foregroundBriefingStream
        .listen(_showForegroundBriefingDialog);
    unawaited(_deferStartupLifecycleWork(
      'initial_briefing',
      _markForegroundAndCheckPendingBriefing,
    ));
    // alarm_service의 알람 콜백은 별도 Dart VM에서 실행되므로 IsolateNameServer가
    // 작동하지 않는다. SharedPreferences pending key를 2초마다 확인해 모달로 전환한다.
    _foregroundBriefingPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        // 포그라운드 heartbeat 갱신: 앱이 백그라운드/종료되면 이 타이머가 멈춰
        // heartbeat가 낡고, 알람 콜백이 이를 백그라운드로 판정해 알림을 발화한다.
        unawaited(_deferStartupLifecycleWork('briefing_heartbeat', () async {
          await BriefingSchedulerService.refreshForegroundHeartbeat();
          await BriefingSchedulerService.checkPendingModalTrigger();
        }));
      },
    );
    unawaited(_scheduleDeferredSessionSync(reason: 'startup'));
    unawaited(
        _deferStartupLifecycleWork('shared_ics', _listenForSharedIcsFiles));
    unawaited(_deferStartupLifecycleWork(
      'naver_ics_reminder',
      _notificationService.scheduleMonthlyNaverIcsReminder,
    ));
    // 이전 버전이 예약해 둔 베타 후기 알림은 업데이트 후에도 남을 수
    // 있으므로, 새 예약 없이 기존 예약만 한 번 정리한다.
    unawaited(_deferStartupLifecycleWork(
        'beta_survey_cleanup', _notificationService.cancelBetaSurveyReminder));
    _routeInitialHomeWidgetLaunch();
    unawaited(_routeInitialNotificationLaunch());
    _listenForPlanFlowDeepLinks();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
    unawaited(_scheduleDeferredUpdateCheck());
    unawaited(_deferStartupLifecycleWork(
        'alarm_permissions', _logStartupAlarmPermissions));
  }

  Future<void> _deferStartupLifecycleWork(
    String key,
    Future<void> Function() work,
  ) {
    final existing = _startupLifecycleJobs[key];
    if (existing != null) return existing;
    final future = () async {
      try {
        await startupRouteGate.startupWorkAllowedWhenIdle;
        await work();
      } catch (error, stackTrace) {
        debugPrint('Deferred startup lifecycle work skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }();
    late final Future<void> tracked;
    tracked = future.whenComplete(() {
      if (identical(_startupLifecycleJobs[key], tracked)) {
        _startupLifecycleJobs.remove(key);
      }
    });
    _startupLifecycleJobs[key] = tracked;
    return tracked;
  }

  Future<void> _markForegroundAndCheckPendingBriefing() async {
    await BriefingSchedulerService.recordAppForegroundState(true);
    await BriefingSchedulerService.checkPendingModalTrigger();
  }

  /// 앱 시작 시 알림/정확알람 권한 상태를 진단로그에 항상 기록한다.
  /// 전체 알람(브리핑 포함) 미발생의 1차 원인이 권한 거부인지 기기에서 바로 확인용.
  Future<void> _logStartupAlarmPermissions() async {
    try {
      final status = await _notificationService.checkPermissionStatus();
      final pending = await _notificationService.pendingNotificationCount();
      DiagLogger.log(
        'AlarmPerm',
        'startup notifications=${status.notificationsEnabled} '
            'exact=${status.exactAlarmsEnabled} '
            'fullScreen=${status.fullScreenIntentStatus} '
            'pending=$pending',
      );
    } catch (error) {
      DiagLogger.log('AlarmPerm', 'startup check failed: $error');
    }
  }

  Future<void> _syncSessionAndCalendar({required String reason}) async {
    if (startupRouteGate.startupWorkDeferred) {
      return;
    }
    if (!await _waitForInitialAuthResolution()) {
      return;
    }
    final signedIn = await authProvider.syncCurrentSession();
    if (!signedIn) {
      return;
    }
    await _syncRegionSettings();
    unawaited(_activityTrackingService.recordActive());
    unawaited(_runChannelMigrations());
    // 그룹 달력 홈위젯 데이터 사전 갱신: 사용자가 그룹 화면에 진입하지 않고
    // 앱을 정상 실행/재개하기만 해도 gw_groups_json이 채워져 위젯 배치가
    // 가능하도록 한다(개인 위젯이 홈 로드마다 갱신되는 것과 동등). 과거엔
    // GroupEventProvider(그룹 화면 진입 시)에서만 갱신돼, 위젯 배치 시
    // "앱을 먼저 실행해 그룹을 불러오세요"만 뜨고 배치가 안 됐다. refresh()는
    // Android-only·10초 디바운스·내부 예외 catch라 무해하다.
    final gwUserId = authProvider.userId;
    if (gwUserId != null && gwUserId.isNotEmpty) {
      unawaited(GroupCalendarWidgetService().refresh(userId: gwUserId));
    }
    final pendingIcsPaths = await _naverIcsShareStore.takePendingPaths();
    if (pendingIcsPaths.isNotEmpty) {
      appRouter.go(AppRoutes.naverIcsImport, extra: pendingIcsPaths);
      return;
    }
    // Keep the app-level in-flight guard held until the calendar service has
    // actually finished.  Launching this unawaited allowed a second resume
    // or Shell instance to overlap the CalDAV import after the guard cleared.
    await _calendarAutoSyncService.syncConnectedCalendars(reason: reason);
  }

  Future<void> _runChannelMigrations() async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    try {
      await EventReminderChannelMigrationService()
          .migrateFutureEventRemindersIfNeeded(userId);
    } catch (error, stackTrace) {
      debugPrint('Channel migration skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    try {
      await SmartPreparationPayloadMigrationService().migrateIfNeeded(userId);
    } catch (error, stackTrace) {
      debugPrint('Smart preparation migration skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _scheduleDeferredSessionSync({required String reason}) async {
    if (!mounted) {
      return;
    }
    final generation = ++_startupSessionSyncGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final graceDelay = (reason == 'startup' || reason == 'foreground_idle')
          ? const Duration(seconds: 4)
          : Duration.zero;
      Future<void>.delayed(graceDelay, () {
        if (!mounted || generation != _startupSessionSyncGeneration) {
          return;
        }
        // Keep the first interactive frames free of network/CalDAV work.  An
        // idle-priority task is automatically postponed while the user is
        // tapping or scrolling, unlike a fixed timer which fires mid-gesture.
        SchedulerBinding.instance.scheduleTask<void>(
          () => _runDeferredSessionSync(generation, reason: reason, attempt: 0),
          Priority.idle,
        );
      });
    });
  }

  void _runDeferredSessionSync(
    int generation, {
    required String reason,
    required int attempt,
  }) {
    if (!mounted || generation != _startupSessionSyncGeneration) {
      return;
    }
    if (!_interactionIdleGate.isIdle) {
      _retryDeferredSessionSync(generation, reason: reason, attempt: attempt);
      return;
    }
    if (_startupSessionSyncRunning) {
      return;
    }
    if (!authProvider.hasResolvedInitialSession ||
        startupRouteGate.startupWorkDeferred) {
      _retryDeferredSessionSync(generation, reason: reason, attempt: attempt);
      return;
    }

    final currentRoute = _currentRouteLocation();
    if (currentRoute == null ||
        currentRoute == AppRoutes.root ||
        _isOnboardingRoute(currentRoute)) {
      _retryDeferredSessionSync(generation, reason: reason, attempt: attempt);
      return;
    }

    unawaited(() async {
      final interactionGeneration = _interactionIdleGate.generation;
      await _interactionIdleGate.waitForIdle();
      if (!mounted ||
          interactionGeneration != _interactionIdleGate.generation ||
          !_interactionIdleGate.isIdle) {
        _retryDeferredSessionSync(generation, reason: reason, attempt: attempt);
        return;
      }
      _startupSessionSyncRunning = true;
      try {
        await _syncSessionAndCalendar(reason: reason);
      } catch (error, stackTrace) {
        debugPrint('Deferred session sync skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
      } finally {
        _startupSessionSyncRunning = false;
      }
    }());
  }

  void _retryDeferredSessionSync(
    int generation, {
    required String reason,
    required int attempt,
  }) {
    if (!mounted || generation != _startupSessionSyncGeneration) {
      return;
    }
    if (attempt >= 20) {
      // Do not abandon the sync after repeated interaction blocks. Wait for
      // one settled idle window, then restart the bounded backoff sequence.
      unawaited(_interactionIdleGate.waitForStableIdle().then((_) {
        _runDeferredSessionSync(generation, reason: reason, attempt: 0);
      }));
      return;
    }
    final delay = Duration(milliseconds: attempt == 0 ? 80 : 160);
    unawaited(
      Future<void>.delayed(delay, () {
        _runDeferredSessionSync(
          generation,
          reason: reason,
          attempt: attempt + 1,
        );
      }),
    );
  }

  Future<void> _scheduleDeferredUpdateCheck() async {
    if (!mounted) {
      return;
    }
    final generation = ++_startupUpdateCheckGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runDeferredUpdateCheck(generation, attempt: 0);
    });
  }

  void _runDeferredUpdateCheck(
    int generation, {
    required int attempt,
  }) {
    if (!mounted || generation != _startupUpdateCheckGeneration) {
      return;
    }
    if (_startupUpdateCheckRunning) {
      return;
    }

    if (!authProvider.hasResolvedInitialSession ||
        startupRouteGate.startupWorkDeferred) {
      _retryDeferredUpdateCheck(generation, attempt: attempt);
      return;
    }

    final currentRoute = _currentRouteLocation();
    if (currentRoute == null ||
        currentRoute == AppRoutes.root ||
        _isOnboardingRoute(currentRoute)) {
      _retryDeferredUpdateCheck(generation, attempt: attempt);
      return;
    }

    unawaited(() async {
      final restoreRoute = await _loadPendingUpdateRestoreRoute();
      if (!mounted || generation != _startupUpdateCheckGeneration) {
        return;
      }

      if (!authProvider.isSignedIn) {
        if (restoreRoute != null) {
          await _clearPendingUpdateRestoreRoute();
        }
      } else if (restoreRoute != null && restoreRoute != currentRoute) {
        appRouter.go(restoreRoute);
        _retryDeferredUpdateCheck(generation, attempt: attempt + 1);
        return;
      }

      _startupUpdateCheckRunning = true;
      try {
        final persistRoute =
            _isPersistableRoute(currentRoute) ? currentRoute : null;
        if (persistRoute != null) {
          await _savePendingUpdateRestoreRoute(persistRoute);
        }
        final started = await UpdateService.checkAndPrompt(
          onIosUpdateAvailable: _showIosUpdatePrompt,
        );
        if (!started) {
          await _clearPendingUpdateRestoreRoute();
        }
      } catch (error, stackTrace) {
        debugPrint('Deferred update check skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
      } finally {
        _startupUpdateCheckRunning = false;
      }
    }());
  }

  Future<void> _showIosUpdatePrompt(IosAppStoreUpdate update) async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (!mounted || context == null || !context.mounted) return;
    await showIosAppStoreUpdatePrompt(
      context: context,
      update: update,
    );
  }

  void _retryDeferredUpdateCheck(
    int generation, {
    required int attempt,
  }) {
    if (!mounted || generation != _startupUpdateCheckGeneration) {
      return;
    }
    if (attempt >= 20) {
      unawaited(_interactionIdleGate.waitForStableIdle().then((_) {
        _runDeferredUpdateCheck(generation, attempt: 0);
      }));
      return;
    }
    final delay = Duration(milliseconds: attempt == 0 ? 80 : 160);
    unawaited(
      Future<void>.delayed(delay, () {
        _runDeferredUpdateCheck(generation, attempt: attempt + 1);
      }),
    );
  }

  String? _currentRouteLocation() {
    try {
      final uri = appRouter.routeInformationProvider.value.uri;
      final path = uri.path.trim();
      if (path.isEmpty) {
        return null;
      }
      final query = uri.hasQuery ? '?${uri.query}' : '';
      return '$path$query';
    } catch (_) {
      return null;
    }
  }

  bool _isPersistableRoute(String route) {
    return route.isNotEmpty &&
        route != AppRoutes.root &&
        route != AppRoutes.login &&
        route != AppRoutes.permissionOnboarding &&
        route != AppRoutes.resetPassword;
  }

  bool _isOnboardingRoute(String route) {
    return route == AppRoutes.login ||
        route == AppRoutes.permissionOnboarding ||
        route == AppRoutes.featureTour;
  }

  Future<String?> _loadPendingUpdateRestoreRoute() async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return null;
    final value = prefs.getString(_pendingUpdateRestoreRouteKey)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  Future<void> _savePendingUpdateRestoreRoute(String route) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return;
    await prefs.setString(_pendingUpdateRestoreRouteKey, route);
  }

  Future<void> _clearPendingUpdateRestoreRoute() async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return;
    await prefs.remove(_pendingUpdateRestoreRouteKey);
  }

  Future<void> _syncRegionSettings() async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty || !AppEnv.isSupabaseReady) {
      return;
    }
    try {
      final settings =
          await SettingsRepository.supabase().fetchSettings(userId);
      if (settings == null) {
        return;
      }
      PlanFlowRegionController.instance.setRegion(
        PlanFlowRegions.byLocaleAndTimeZone(
          countryCode: settings.countryCode,
          localeCode: settings.localeCode,
          timeZoneId: settings.timeZoneId,
        ),
      );
    } catch (error) {
      debugPrint('Region settings sync skipped: $error');
    }
  }

  void _showForegroundBriefingDialog(bool isMorning) {
    if (_briefingDialogShowing) return;
    // 앱 시작 직후에는 splash→home 초기 라우팅(go)이 다이얼로그를 덮어
    // 사용자가 누르기도 전에 사라진다. 라우팅이 안정된 뒤(다음 프레임 + 약간의
    // 지연)에 표시하고, barrierDismissible=false로 실수/초기 전환에 닫히지
    // 않게 한다. pending은 소비되기 전까지 재확인되므로 한 번은 반드시 뜬다.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || _briefingDialogShowing) return;
      final context = appRouter.routerDelegate.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      _briefingDialogShowing = true;
      // 다이얼로그 표시와 동시에 사전 로드 시작.
      unawaited(
        BriefingSchedulerService().preloadBriefing(isMorning: isMorning),
      );
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(isMorning ? '모닝 브리핑' : '이브닝 브리핑'),
          content: const Text('브리핑 알람이 도착했습니다.\n지금 재생하시겠습니까?'),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '내일 다시',
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(_rescheduleBriefingForTomorrow(isMorning));
                  },
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  label: '재생',
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    final type = isMorning ? 'morning' : 'evening';
                    // 브리핑은 별도 결과 화면으로 이동하지 않고, 일정 탭의
                    // 동일한 달력 위에서 실행한다. 일정 목록을 보면서 들을 수
                    // 있고, 기존 달력/바텀시트 상태도 그대로 유지된다.
                    // 모달 pop과 go를 같은 동기 콜백에서 호출하면 Navigator가
                    // 아직 모달 route를 정리하는 중이라 이동 요청이 유실될 수
                    // 있다. 모달이 실제로 닫힌 다음 프레임에 브리핑 route를
                    // 열어 일정 탭과 선택 날짜 상세 시트를 보장한다.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      appRouter.go('${AppRoutes.briefing}?type=$type');
                    });
                  },
                  type: ActionButtonType.primary,
                  flex: 1,
                ),
              ],
            ),
          ],
        ),
      ).whenComplete(() => _briefingDialogShowing = false);
    });
  }

  Future<void> _rescheduleBriefingForTomorrow(bool isMorning) async {
    final scheduled = await BriefingSchedulerService().rescheduleNextBriefing(
      isMorning: isMorning,
    );
    if (!mounted) {
      return;
    }
    final label = isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          scheduled
              ? '$label을 내일 다시 알려드릴게요.'
              : '$label 재알림을 예약하지 못했어요. 알림 권한을 확인해 주세요.',
        ),
      ),
    );
  }

  void _onAuthProviderChange() {
    if (!authProvider.isSignedIn) startupRouteGate.resetRequiredSetup();
    if (authProvider.hasResolvedInitialSession &&
        authProvider.hasAttemptedStartupSync &&
        authProvider.needsReauthentication &&
        authProvider.hasAccountSnapshot &&
        !_reauthSnackBarShown) {
      _reauthSnackBarShown = true;
      // 로그인 화면으로 강제 이동하지 않고, 앱 내에서 배너로 안내
      AppFeedbackService.scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text('세션이 만료되었어요. 설정에서 다시 로그인해 주세요.'),
          action: SnackBarAction(
            label: '재로그인',
            onPressed: () => appRouter.go(AppRoutes.login),
          ),
          duration: const Duration(seconds: 10),
        ),
      );
    } else if (authProvider.isSignedIn) {
      // 정상 로그인 복구 시 플래그 리셋
      _reauthSnackBarShown = false;
    }
    unawaited(_scheduleDeferredSessionSync(reason: 'auth_changed'));
    unawaited(_scheduleDeferredUpdateCheck());
  }

  void _onRouterLocationChanged() {
    _homeWidgetRouteCoordinator.notifyLocationChanged();
  }

  void _onStartupRouteGateChange() {
    unawaited(_scheduleDeferredSessionSync(reason: 'startup_gate'));
    unawaited(_scheduleDeferredUpdateCheck());
  }

  @override
  void dispose() {
    authProvider.removeListener(_onAuthProviderChange);
    startupRouteGate.removeListener(_onStartupRouteGateChange);
    appRouter.routeInformationProvider
        .removeListener(_onRouterLocationChanged);
    appRouter.routerDelegate.removeListener(_onRouterLocationChanged);
    // coordinator가 소유한 타이머/리스너와 pending 상태까지 함께 정리한다.
    _homeWidgetRouteCoordinator.dispose();
    _homeWidgetClickSubscription?.cancel();
    _planFlowLinkSubscription?.cancel();
    _sharedIcsSubscription?.cancel();
    _foregroundBriefingSubscription?.cancel();
    _foregroundBriefingPollTimer?.cancel();
    unawaited(_oauthCallbackHandler.dispose());
    unawaited(BriefingSchedulerService.recordAppForegroundState(false));
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _listenForSharedIcsFiles() async {
    _sharedIcsSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedMediaFiles, onError: (Object error, stackTrace) {
      debugPrint('Shared ICS stream failed: $error');
      debugPrintStack(stackTrace: stackTrace as StackTrace?);
    });

    final initialMedia = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initialMedia.isNotEmpty) {
      await _handleSharedMediaFiles(initialMedia);
      await ReceiveSharingIntent.instance.reset();
    }
  }

  Future<void> _handleSharedMediaFiles(List<SharedMediaFile> files) async {
    final paths = files
        .where(_isIcsShare)
        .map((file) => file.path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (paths.isEmpty) {
      return;
    }

    if (!await _waitForInitialAuthResolution()) {
      await _naverIcsShareStore.savePendingPaths(paths);
      appRouter.go(AppRoutes.login);
      return;
    }

    final signedIn =
        authProvider.isSignedIn || await authProvider.syncCurrentSession();
    if (!signedIn) {
      await _naverIcsShareStore.savePendingPaths(paths);
      appRouter.go(AppRoutes.login);
      return;
    }

    appRouter.go(AppRoutes.naverIcsImport, extra: paths);
  }

  Future<bool> _waitForInitialAuthResolution() async {
    if (!AppEnv.isSupabaseReady || authProvider.hasResolvedInitialSession) {
      return true;
    }
    final resolved = await authProvider.waitForInitialSessionResolution();
    if (!resolved) {
      debugPrint('Session sync deferred: initial auth unresolved');
    }
    return resolved;
  }

  bool _isIcsShare(SharedMediaFile file) {
    final path = file.path.toLowerCase();
    final mimeType = file.mimeType?.toLowerCase() ?? '';
    return path.endsWith('.ics') ||
        mimeType == 'text/calendar' ||
        mimeType == 'text/x-vcalendar' ||
        mimeType == 'application/ics' ||
        mimeType == 'application/octet-stream';
  }

  Future<void> _routeInitialHomeWidgetLaunch() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      DiagLogger.log('WidgetRoute', 'initial probe uri=${uri ?? "null"}');
      _handleHomeWidgetUri(uri);
      if (uri == null) _retryInitialHomeWidgetLaunchProbe(attempt: 0);
    } catch (error) {
      DiagLogger.log(
          'WidgetRoute', 'initial widget launch probe failed: $error');
      _retryInitialHomeWidgetLaunchProbe(attempt: 0);
    }
  }

  void _retryInitialHomeWidgetLaunchProbe({required int attempt}) {
    if (!mounted || _homeWidgetRouteCoordinator.hasPendingRoute ||
        attempt >= 6) {
      return;
    }
    // 첫 재시도는 50ms(플러그인 초기화 타이밍), 이후 150ms 간격
    final delayMs = attempt == 0 ? 50 : 150 * attempt;
    unawaited(
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted || _homeWidgetRouteCoordinator.hasPendingRoute) {
          return;
        }
        try {
          final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
          DiagLogger.log(
            'WidgetRoute',
            'initiallyLaunchedFromHomeWidget attempt=${attempt + 1} '
                'uri=${uri ?? "null"}',
          );
          if (uri != null) {
            _handleHomeWidgetUri(uri);
            return;
          }
        } catch (error) {
          // 재시도 도중 플러그인 측 race condition(예: native bridge가 아직
          // attach 되지 않음, MethodChannel 응답 누락)이 발생해도 다음 시도
          // 기회를 유지해 cold-start launch를 놓치지 않게 한다. 첫 호출의
          // catch는 _routeInitialHomeWidgetLaunch에 있지만 그 직후의 재시도
          // 반복에서도 동일한 보호가 필요해 여기서도 catch한다.
          DiagLogger.log(
            'WidgetRoute',
            'retry probe attempt=${attempt + 1} failed: $error',
          );
        }
        if (!mounted || _homeWidgetRouteCoordinator.hasPendingRoute) {
          return;
        }
        _retryInitialHomeWidgetLaunchProbe(attempt: attempt + 1);
      }),
    );
  }

  static const _settingsMethodChannel =
      MethodChannel('planflow/android_settings');

  /// 처리 완료 후 native intent action을 MAIN으로 재설정해 onResume 오탐 방지
  Future<void> _consumeHomeWidgetLaunch({String reason = 'unknown'}) async {
    DiagLogger.log(
      'WidgetRoute',
      'consumeHomeWidgetLaunch invoked reason=$reason',
    );
    try {
      await _settingsMethodChannel
          .invokeMethod<void>('consumeHomeWidgetLaunch');
    } catch (e) {
      debugPrint('App consumeHomeWidgetLaunch 무시: $e');
    }
  }

  /// warm-start fallback: widgetClicked 스트림이 유실된 경우 onResume에서 재확인
  Future<void> _resumeHomeWidgetCheck() async {
    // pending 라우트가 보존 중이면(deferral/givingUp retained 포함) 네이티브
    // probe로 같은 URI를 다루지 말고 이벤트 기반 재평가만 트리거한다.
    if (_homeWidgetRouteCoordinator.hasPendingRoute) {
      _homeWidgetRouteCoordinator.kickPendingRoute();
      return;
    }
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    // async 대기 중 스트림이 처리했을 수 있으므로 재확인
    if (_homeWidgetRouteCoordinator.hasPendingRoute) {
      _homeWidgetRouteCoordinator.kickPendingRoute();
      return;
    }
    if (uri != null) {
      _handleHomeWidgetUri(uri);
    }
  }

  void _listenForPlanFlowDeepLinks() {
    _planFlowLinkSubscription = _appLinks.uriLinkStream.listen(
      (uri) {
        DiagLogger.log(
          'WidgetRoute',
          'appLinks.uriLinkStream event uri=$uri',
        );
        _handlePlanFlowDeepLink(uri);
      },
      onError: (Object error, stackTrace) {
        debugPrint('PlanFlow deep link stream failed: $error');
        debugPrintStack(stackTrace: stackTrace as StackTrace?);
      },
    );
    unawaited(
      _appLinks.getInitialLink().then((uri) {
        DiagLogger.log(
          'WidgetRoute',
          'appLinks.getInitialLink uri=${uri ?? "null"}',
        );
        _handlePlanFlowDeepLink(uri);
      }),
    );
  }

  void _handlePlanFlowDeepLink(Uri? uri) {
    if (uri == null ||
        uri.scheme != 'planflow' ||
        uri.host == 'auth-callback') {
      return;
    }
    _handleHomeWidgetUri(uri);
  }

  /// 앱이 완전히 꺼진 상태에서 알림(브리핑 등)을 눌러 실행된 경우, 저장된
  /// launch details로 목적지 라우트를 복구한다. 홈위젯 라우트와 동일한
  /// gate(startupRouteGate)·재시도 메커니즘을 재사용한다.
  Future<void> _routeInitialNotificationLaunch() async {
    final route = await _notificationService.resolveColdStartLaunchRoute();
    if (route == null || _homeWidgetRouteCoordinator.hasPendingRoute) {
      return;
    }
    startupRouteGate.beginWidgetLaunch();
    _scheduleHomeWidgetRoute(route);
  }

  void _handleHomeWidgetUri(Uri? uri) {
    final route = resolveHomeWidgetRoute(uri);
    DiagLogger.log(
      'WidgetRoute',
      'resolveHomeWidgetRoute uri=${uri ?? "null"} route=${route ?? "null"}',
    );
    if (route != null) {
      // Android cold start can deliver the same widget URI through both the
      // HomeWidget probe and AppLinks.  A second push deactivates the first
      // VoiceInputScreen and cancels its newly-started STT session.
      final now = DateTime.now();
      if (shouldIgnoreDuplicateHomeWidgetRoute(
        route: route,
        previousRoute: _lastHandledHomeWidgetRoute,
        previousHandledAt: _lastHandledHomeWidgetRouteAt,
        now: now,
      )) {
        DiagLogger.log(
          'WidgetRoute',
          'duplicate route ignored route=$route',
        );
        return;
      }
      _lastHandledHomeWidgetRoute = route;
      _lastHandledHomeWidgetRouteAt = now;
      // native intent 소비(_consumeHomeWidgetLaunch)는 도착이 확인된
      // (confirmed) 시점에만 coordinator가 실행한다. givingUp이 되어도
      // 소비하지 않는다: pending 목적지(선택된 date/voice autoStart query
      // 포함)는 RETAINED로 보존되어, auth/gate 변화 또는 foreground
      // resume 때 이벤트 기반으로 재시도된다. 타임아웃/도착 실패가 곧
      // 성공/소비를 의미하지 않는다(구 P5R givingUp-소비 계약 교체).
      // 프로세스가 재시작되면 unconsumed intent가 재생될 수 있지만, 그
      // 재생이 곧 사용자가 의도한 목적지 복원이므로 의도된 동작이다.
      startupRouteGate.beginWidgetLaunch();
      _scheduleHomeWidgetRoute(route);
    }
  }

  void _scheduleHomeWidgetRoute(String route) {
    _homeWidgetShouldSeedHomeBase = null;
    // 첫 평가는 한 프레임 뒤에 실행해 기존 post-frame 적용 타이밍을 유지한다
    // (라우터/첫 프레임 안정화 이후 readiness 판정). 이후 deferral/givingUp
    // 보존/재시도는 전부 coordinator가 이벤트 기반으로 소유한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_homeWidgetRouteCoordinator.submitRoute(route));
    });
  }

  /// coordinator가 pending 라우트 평가를 위해 호출하는 readiness 판정.
  /// Supabase 준비 + 초기 세션 해석 + signed-in까지 왔을 때만 ready다.
  /// resolved-signed-out은 needsAuth: coordinator는 pending을 계속 들고
  /// 있고, 로그인 리다이렉트는 앱 소유 콜백(_onHomeWidgetRouteDeferred)이
  /// 담당한다(로그인/온보딩 강제 유지, 보호 화면 우회 없음).
  HomeWidgetRouteReadiness _resolveHomeWidgetReadiness() =>
      resolveAppHomeWidgetReadiness(
        auth: authProvider,
        gate: startupRouteGate,
        supabaseReady: AppEnv.isSupabaseReady,
      );

  /// pending 라우트가 readiness에 막혀 deferred될 때마다 호출된다.
  /// resolved-signed-out 상태면 로그인 화면으로 안내한다(pending은
  /// coordinator가 보존하므로 로그인 성공 시 이벤트 기반으로 재시도된다).
  void _onHomeWidgetRouteDeferred(
    String route,
    HomeWidgetRouteReadiness readiness,
  ) {
    if (readiness == HomeWidgetRouteReadiness.notReady) {
      // Deliver the gate notification outside the coordinator's evaluation
      // (and any build); re-check the policy when it actually runs.
      scheduleMicrotask(() {
        if (mounted &&
            shouldReleaseWidgetHoldAwaitingRequiredSetup(
              readiness: _resolveHomeWidgetReadiness(),
              auth: authProvider,
              gate: startupRouteGate,
              supabaseReady: AppEnv.isSupabaseReady,
            )) {
          DiagLogger.log('WidgetRoute',
              'hold released while awaiting required setup route=$route');
          startupRouteGate.completeWidgetLaunch();
        }
      });
      return;
    }
    if (readiness != HomeWidgetRouteReadiness.needsAuth) {
      return;
    }
    final currentPath = appRouter.routeInformationProvider.value.uri.path;
    if (currentPath == AppRoutes.login) {
      return;
    }
    DiagLogger.log(
      'WidgetRoute',
      'pending widget route deferred to login route=$route',
    );
    appRouter.go(AppRoutes.login);
  }

  /// coordinator가 도착 확인을 시작할 때 목적지 도달이 필요할 때만 호출하는
  /// 실제 네비게이션. 콜드스타트(스택 없음)에서는 홈을 먼저 깔고 그 위에
  /// 목표 화면을 push해 뒤로가기 시 앱 종료를 막는다(기존 seed-home-base
  /// 로직 유지). 위젯 라우트 홀드(startupRouteGate.beginWidgetLaunch)도
  /// 여기서 건다. 같은 목적지에 이미 도착해 있으면 coordinator가 네비게이션
  /// 없이 도착 확인만 진행하므로 중복 push가 구조적으로 불가능하다.
  void _navigatePendingHomeWidgetRoute(String route) {
    // Navigate first, then raise the hold. beginWidgetLaunch() refreshes the
    // router, which re-parses routeInformationProvider.value; right after a
    // pop (e.g. the required tour/permission route closing at HOME) that value
    // can still be the popped location until the next frame reports, so a
    // refresh before the navigation could resurrect the popped onboarding
    // route on top of the target. Navigation only runs when readiness is
    // ready (signed in + required setup complete), so no redirect depends on
    // the hold for this call.
    try {
      _navigatePendingHomeWidgetRouteUnheld(route);
    } finally {
      startupRouteGate.beginWidgetLaunch();
    }
  }

  void _navigatePendingHomeWidgetRouteUnheld(String route) {
    if (_homeWidgetShouldSeedHomeBase == null) {
      _homeWidgetShouldSeedHomeBase = shouldSeedHomeBaseForHomeWidgetRoute(
        route: route,
        canPop: appRouter.canPop(),
      );
      if (_homeWidgetShouldSeedHomeBase!) {
        // 콜드스타트에서는 홈을 먼저 실제로 마운트한 뒤 목표 화면을
        // push해야 초기 root redirect/라우터 복원과 경합하지 않는다.
        seedHomeAndDeferHomeWidgetPush(
          route: route,
          currentCoordinator: () => _homeWidgetRouteCoordinator,
          isMounted: () => mounted,
          seedHome: () => appRouter.go(AppRoutes.home),
          push: (target) => appRouter.push(target),
        );
        return;
      }
    }
    if (Uri.parse(route).path == AppRoutes.home) {
      appRouter.go(route);
    } else {
      appRouter.push(route);
    }
  }

  /// pending 라우트가 터미널 결과에 도달했을 때의 앱 소유 정책.
  ///
  /// - confirmed: 네이티브 intent 소비는 coordinator의 consume 콜백이 이미
  ///   정확히 1회 실행했다. 게이트는 700ms 뒤 해제(기존 타이밍 유지).
  /// - givingUp: pending은 coordinator가 RETAINED 보존한다(소비 없음).
  ///   게이트를 즉시 해제해 로그인/온보딩 강제가 정상 동작하게 하고,
  ///   auth/gate 변화·foreground resume(kickPendingRoute) 때 이벤트 기반
  ///   으로 재시도된다. 타임아웃은 성공/소비가 아니다.
  /// - cancelled: 새 요청으로 대체되었거나 cancel/dispose된 경우.
  void _onHomeWidgetRouteTerminal(
    String route,
    HomeWidgetRouteOutcome outcome,
  ) {
    switch (outcome) {
      case HomeWidgetRouteOutcome.confirmed:
        DiagLogger.log('WidgetRoute', 'arrival confirmed route=$route');
        final generation = _homeWidgetRouteCoordinator.generation;
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 700), () {
            if (!mounted ||
                generation != _homeWidgetRouteCoordinator.generation) {
              return;
            }
            startupRouteGate.completeWidgetLaunch();
          }),
        );
        break;
      case HomeWidgetRouteOutcome.givingUp:
        DiagLogger.log(
          'WidgetRoute',
          'arrival not confirmed route=$route '
              'retained=true consume=false (givingUp keeps pending)',
        );
        // suppression bypass 방지: 보존 중에도 로그인/온보딩 강제는 정상
        // 동작해야 하므로 위젯 홀드를 푼다.
        startupRouteGate.completeWidgetLaunch();
        break;
      case HomeWidgetRouteOutcome.cancelled:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlanFlowRegionController.instance,
      builder: (context, _) {
        return ValueListenableBuilder<UpdateUiState>(
          valueListenable: UpdateService.instance.uiState,
          builder: (context, updateState, _) {
            return MaterialApp.router(
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: AppFeedbackService.scaffoldMessengerKey,
              title: 'PlanFlow',
              theme: buildPlanFlowTheme(),
              locale: PlanFlowRegionController.instance.region.uiLocale,
              supportedLocales: const [
                Locale('ko', 'KR'),
                Locale('en', 'US'),
              ],
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              routerConfig: appRouter,
              builder: (context, child) {
                final showUpdateOverlay =
                    updateState == UpdateUiState.updating ||
                        updateState == UpdateUiState.openingPlayStore;
                return Stack(
                  children: <Widget>[
                    child ?? const SizedBox.shrink(),
                    if (showUpdateOverlay)
                      _UpdateProgressOverlay(state: updateState),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _UpdateProgressOverlay extends StatelessWidget {
  const _UpdateProgressOverlay({required this.state});

  final UpdateUiState state;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (state) {
      UpdateUiState.checking => (
          '업데이트 확인 중...',
          '잠시만 기다려 주세요.',
        ),
      UpdateUiState.updating => (
          '업데이트 중...',
          '업데이트가 끝날 때까지 잠시만 기다려 주세요.',
        ),
      UpdateUiState.openingPlayStore => (
          '업데이트 페이지를 여는 중...',
          '조금만 기다려 주세요.',
        ),
      UpdateUiState.idle => (
          '',
          '',
        ),
    };

    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          const ModalBarrier(
            dismissible: false,
            color: Colors.black45,
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Material(
                elevation: 10,
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 22,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(
                        height: 28,
                        width: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.black54,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
bool shouldIgnoreDuplicateHomeWidgetRoute({
  required String route,
  required String? previousRoute,
  required DateTime? previousHandledAt,
  required DateTime now,
}) {
  return route == previousRoute &&
      previousHandledAt != null &&
      now.difference(previousHandledAt) < const Duration(seconds: 2);
}

@visibleForTesting
String? resolveHomeWidgetRoute(Uri? uri) {
  if (uri == null || uri.scheme != 'planflow') {
    return null;
  }

  final query = uri.hasQuery ? '?${uri.query}' : '';
  switch (uri.host) {
    case 'schedule':
      final scheduleId =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.first.trim() : '';
      return scheduleId.isNotEmpty
          ? '${AppRoutes.eventDetail}/$scheduleId'
          : AppRoutes.calendar;
    case 'day':
      return NotificationRouteContract.canonicalPath(uri);
    case 'voice-launcher':
      return '${AppRoutes.voice}?autoStart=1';
    case 'voice':
      return '${AppRoutes.voice}$query';
    case 'voice-conversation':
      return '${AppRoutes.voiceConversation}?autoStart=1';
    case 'calendar':
      return '${AppRoutes.calendar}$query';
    case 'event':
      final pathId =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.first.trim() : '';
      final queryId = uri.queryParameters['eventId']?.trim() ??
          uri.queryParameters['event_id']?.trim() ??
          '';
      final eventId = pathId.isNotEmpty ? pathId : queryId;
      return eventId.isNotEmpty
          ? '${AppRoutes.eventDetail}/$eventId'
          : AppRoutes.calendar;
    case 'group-invite':
      final groupId = uri.queryParameters['groupId']?.trim() ??
          uri.queryParameters['group_id']?.trim() ??
          '';
      final token = uri.queryParameters['token']?.trim() ?? '';
      return groupId.isNotEmpty && token.isNotEmpty
          ? AppRoutes.groupInviteLinkFor(groupId: groupId, token: token)
          : AppRoutes.groups;
    case 'group-calendar':
      // 홈 위젯 탭: planflow://group-calendar?groupId=<gid>[&date=yyyy-MM-dd]
      // → 해당 그룹의 이벤트 목록(캘린더 보기)으로 이동. 날짜 셀을 탭한
      // 경우 date가 함께 오며, 그 날짜의 캘린더 보기로 바로 진입한다
      // (query를 그대로 붙여 router의 _parseRouteDate가 읽게 한다).
      final gcGroupId = uri.queryParameters['groupId']?.trim() ??
          uri.queryParameters['group_id']?.trim() ??
          '';
      final gcBase = gcGroupId.isNotEmpty
          ? AppRoutes.groupEventsForId(gcGroupId)
          : AppRoutes.groupEvents;
      return '$gcBase$query';
  }

  if (uri.path == '/voice') {
    return '${AppRoutes.voice}$query';
  }
  if (uri.path == '/voice-conversation') {
    return '${AppRoutes.voiceConversation}?autoStart=1';
  }
  if (uri.path == '/calendar') {
    return '${AppRoutes.calendar}$query';
  }
  final canonicalPath = NotificationRouteContract.canonicalPath(uri);
  if (canonicalPath != null) {
    return canonicalPath;
  }
  return null;
}

/// 홈 위젯/딥링크로 목표 [route]에 진입할 때, 홈 화면을 먼저 스택
/// 베이스로 깔아야 하는지 판단한다.
///
/// [canPop]이 false라는 것은 현재 라우터 스택에 뒤로 갈 대상이 없다는
/// 뜻이다(콜드스타트 또는 백그라운드 상태에서 위젯을 탭해 막 진입한
/// 경우). 이 상태에서 목표 라우트로 바로 `go()`하면 그 라우트가 스택의
/// 유일한 엔트리가 되어, 뒤로가기를 눌러도 pop할 대상이 없어 앱이
/// 종료된다. 따라서 이 경우에는 true를 반환해 호출부가 홈을 먼저
/// `go()`한 뒤 목표 라우트를 `push()`하도록 한다.
///
/// 이미 앱을 쓰던 중이라 정상적인 뒤로가기 스택이 있으면([canPop]==true)
/// 홈으로 스택을 초기화할 필요가 없으므로 false를 반환한다(호출부는
/// 그 위에 `push()`만 한다). 목표가 이미 홈 라우트인 경우도 false를
/// 반환한다(그대로 `go()`하면 된다).
@visibleForTesting
bool shouldSeedHomeBaseForHomeWidgetRoute({
  required String route,
  required bool canPop,
}) {
  if (canPop) {
    return false;
  }
  return Uri.parse(route).path != AppRoutes.home;
}
