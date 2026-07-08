import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'core/theme.dart';
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
import 'services/oauth_callback_handler.dart';
import 'services/update_service.dart';
import 'widgets/planflow_action_buttons.dart';

class PlanFlowApp extends StatefulWidget {
  const PlanFlowApp({super.key});

  @override
  State<PlanFlowApp> createState() => _PlanFlowAppState();
}

class _PlanFlowAppState extends State<PlanFlowApp> {
  static const String _pendingUpdateRestoreRouteKey =
      'startup:update_restore_route';

  StreamSubscription<Uri?>? _homeWidgetClickSubscription;
  StreamSubscription<Uri>? _planFlowLinkSubscription;
  StreamSubscription<List<SharedMediaFile>>? _sharedIcsSubscription;
  StreamSubscription<bool>? _foregroundBriefingSubscription;
  Timer? _foregroundBriefingPollTimer;
  bool _reauthSnackBarShown = false;
  bool _startupUpdateCheckRunning = false;
  int _startupUpdateCheckGeneration = 0;
  final AppLinks _appLinks = AppLinks();
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  final NaverIcsShareStore _naverIcsShareStore = const NaverIcsShareStore();
  bool _briefingDialogShowing = false;
  final NotificationService _notificationService = NotificationService();
  final ActivityTrackingService _activityTrackingService =
      ActivityTrackingService();
  late final AppLifecycleListener _lifecycleListener;
  String? _pendingHomeWidgetRoute;
  int _homeWidgetRouteGeneration = 0;
  bool? _homeWidgetShouldSeedHomeBase;

  @override
  void initState() {
    super.initState();
    _oauthCallbackHandler.start();
    authProvider.addListener(_onAuthProviderChange);
    startupRouteGate.addListener(_onStartupRouteGateChange);
    _lifecycleListener = AppLifecycleListener(
      onPause: () {
        unawaited(BriefingSchedulerService.recordAppForegroundState(false));
        unawaited(_syncCalendarInBackground());
      },
      onResume: () {
        unawaited(_markForegroundAndCheckPendingBriefing());
        // widgetClicked 스트림이 유실된 warm-start를 복구하기 위해 먼저 실행
        unawaited(_resumeHomeWidgetCheck());
        unawaited(_syncSessionAndCalendar(reason: 'resume'));
        unawaited(_activityTrackingService.recordActive());
        unawaited(_scheduleDeferredUpdateCheck());
      },
    );
    _foregroundBriefingSubscription = BriefingSchedulerService
        .foregroundBriefingStream
        .listen(_showForegroundBriefingDialog);
    unawaited(_markForegroundAndCheckPendingBriefing());
    // alarm_service의 알람 콜백은 별도 Dart VM에서 실행되므로 IsolateNameServer가
    // 작동하지 않는다. SharedPreferences pending key를 2초마다 확인해 모달로 전환한다.
    _foregroundBriefingPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        // 포그라운드 heartbeat 갱신: 앱이 백그라운드/종료되면 이 타이머가 멈춰
        // heartbeat가 낡고, 알람 콜백이 이를 백그라운드로 판정해 알림을 발화한다.
        unawaited(BriefingSchedulerService.refreshForegroundHeartbeat());
        unawaited(BriefingSchedulerService.checkPendingModalTrigger());
      },
    );
    unawaited(_syncSessionAndCalendar(reason: 'startup'));
    unawaited(_listenForSharedIcsFiles());
    unawaited(_notificationService.scheduleMonthlyNaverIcsReminder());
    unawaited(_scheduleBetaSurveyReminderIfNeeded());
    _routeInitialHomeWidgetLaunch();
    unawaited(_routeInitialNotificationLaunch());
    _listenForPlanFlowDeepLinks();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
    unawaited(_scheduleDeferredUpdateCheck());
    unawaited(_logStartupAlarmPermissions());
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

  Future<void> _syncCalendarInBackground() async {
    try {
      if (!await _waitForInitialAuthResolution()) {
        return;
      }
      final signedIn =
          authProvider.isSignedIn || await authProvider.syncCurrentSession();
      if (!signedIn) {
        return;
      }
      await _calendarAutoSyncService.syncConnectedCalendars(
        reason: 'background',
      );
    } catch (error, stackTrace) {
      debugPrint('Background calendar sync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _syncSessionAndCalendar({required String reason}) async {
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

  Future<void> _scheduleBetaSurveyReminderIfNeeded() async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return;
    final completed = prefs.getBool('beta_survey_completed') ?? false;
    if (completed) return;
    await _notificationService.scheduleBetaSurveyReminder();
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
        startupRouteGate.widgetLaunchPending) {
      _retryDeferredUpdateCheck(generation, attempt: attempt);
      return;
    }

    final currentRoute = _currentRouteLocation();
    if (currentRoute == null || currentRoute == AppRoutes.root) {
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
        final started = await UpdateService.checkAndPrompt();
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

  void _retryDeferredUpdateCheck(
    int generation, {
    required int attempt,
  }) {
    if (!mounted || generation != _startupUpdateCheckGeneration) {
      return;
    }
    if (attempt >= 20) {
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
                  label: '나중에',
                  onPressed: () => Navigator.of(ctx).pop(),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  label: '재생',
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    final type = isMorning ? 'morning' : 'evening';
                    appRouter.go('${AppRoutes.briefing}?type=$type');
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

  void _onAuthProviderChange() {
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
    unawaited(_scheduleDeferredUpdateCheck());
  }

  void _onStartupRouteGateChange() {
    unawaited(_scheduleDeferredUpdateCheck());
  }

  @override
  void dispose() {
    authProvider.removeListener(_onAuthProviderChange);
    startupRouteGate.removeListener(_onStartupRouteGateChange);
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
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    _handleHomeWidgetUri(uri);
    if (uri == null) {
      _retryInitialHomeWidgetLaunchProbe(attempt: 0);
    }
  }

  void _retryInitialHomeWidgetLaunchProbe({required int attempt}) {
    if (!mounted || _pendingHomeWidgetRoute != null || attempt >= 6) {
      return;
    }
    // 첫 재시도는 50ms(플러그인 초기화 타이밍), 이후 150ms 간격
    final delayMs = attempt == 0 ? 50 : 150 * attempt;
    unawaited(
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted || _pendingHomeWidgetRoute != null) {
          return;
        }
        final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
        if (uri != null) {
          _handleHomeWidgetUri(uri);
          return;
        }
        _retryInitialHomeWidgetLaunchProbe(attempt: attempt + 1);
      }),
    );
  }

  static const _settingsMethodChannel =
      MethodChannel('planflow/android_settings');

  /// 처리 완료 후 native intent action을 MAIN으로 재설정해 onResume 오탐 방지
  Future<void> _consumeHomeWidgetLaunch() async {
    try {
      await _settingsMethodChannel
          .invokeMethod<void>('consumeHomeWidgetLaunch');
    } catch (e) {
      debugPrint('App consumeHomeWidgetLaunch 무시: $e');
    }
  }

  /// warm-start fallback: widgetClicked 스트림이 유실된 경우 onResume에서 재확인
  Future<void> _resumeHomeWidgetCheck() async {
    if (_pendingHomeWidgetRoute != null) return;
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    // async 대기 중 스트림이 처리했을 수 있으므로 재확인
    if (_pendingHomeWidgetRoute != null) return;
    if (uri != null) {
      _handleHomeWidgetUri(uri);
    }
  }

  void _listenForPlanFlowDeepLinks() {
    _planFlowLinkSubscription = _appLinks.uriLinkStream.listen(
      (uri) {
        _handlePlanFlowDeepLink(uri);
      },
      onError: (Object error, stackTrace) {
        debugPrint('PlanFlow deep link stream failed: $error');
        debugPrintStack(stackTrace: stackTrace as StackTrace?);
      },
    );
    unawaited(_appLinks.getInitialLink().then(_handlePlanFlowDeepLink));
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
    if (route == null || _pendingHomeWidgetRoute != null) {
      return;
    }
    startupRouteGate.beginWidgetLaunch();
    _scheduleHomeWidgetRoute(route);
  }

  void _handleHomeWidgetUri(Uri? uri) {
    final route = resolveHomeWidgetRoute(uri);
    if (route != null) {
      // native intent를 소비해 onResume fallback에서 동일 URI 중복 처리 방지
      unawaited(_consumeHomeWidgetLaunch());
      startupRouteGate.beginWidgetLaunch();
      _scheduleHomeWidgetRoute(route);
    }
  }

  void _scheduleHomeWidgetRoute(String route) {
    _pendingHomeWidgetRoute = route;
    _homeWidgetShouldSeedHomeBase = null;
    final generation = ++_homeWidgetRouteGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPendingHomeWidgetRoute(generation, attempt: 0);
    });
  }

  void _applyPendingHomeWidgetRoute(
    int generation, {
    required int attempt,
  }) {
    if (!mounted || generation != _homeWidgetRouteGeneration) {
      return;
    }
    final route = _pendingHomeWidgetRoute;
    if (route == null) {
      startupRouteGate.completeWidgetLaunch();
      return;
    }
    if (!authProvider.hasResolvedInitialSession && attempt < 10) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          _applyPendingHomeWidgetRoute(generation, attempt: attempt + 1);
        }),
      );
      return;
    }
    // 실제 네비게이션(go/push)은 이 generation에서 딱 한 번만 실행한다.
    // auth 세션 대기 재시도(위 hasResolvedInitialSession 루프)가 여러 번
    // 돌면 이 지점에 처음 도달했을 때 이미 attempt > 0일 수 있으므로,
    // "attempt == 0"이 아니라 "_homeWidgetShouldSeedHomeBase가 아직
    // null인가"로 최초 1회를 판별해야 한다(attempt 기준이면 콜드스타트에서
    // auth 대기가 있었던 바로 그 경우에 아래 로직을 건너뛰고 원래 버그인
    // 단순 go(route)로 빠져 앱 종료가 재발한다). 이후 도착 확인 재시도는
    // 네비게이션을 다시 실행하지 않고 아래 지연 확인만 반복한다.
    if (_homeWidgetShouldSeedHomeBase == null) {
      // 콜드스타트/백그라운드 상태에서 위젯을 탭해 진입하면 라우터 스택이
      // 비어 있어(canPop()==false) go(route)가 유일한 스택 엔트리가 되고,
      // 그 결과 뒤로가기 시 pop할 대상이 없어 앱이 종료된다. 이 경우 홈을
      // 스택 베이스로 먼저 깔고 그 위에 목표 화면을 push해 back이 홈으로
      // 돌아가게 한다. 반대로 앱을 이미 쓰던 중(정상 스택 보유) 위젯을
      // 탭한 경우에는 기존 스택을 홈으로 초기화하지 않고 그냥 push만 한다.
      _homeWidgetShouldSeedHomeBase = shouldSeedHomeBaseForHomeWidgetRoute(
        route: route,
        canPop: appRouter.canPop(),
      );
      if (_homeWidgetShouldSeedHomeBase!) {
        appRouter.go(AppRoutes.home);
        appRouter.push(route);
      } else if (Uri.parse(route).path == AppRoutes.home) {
        appRouter.go(route);
      } else {
        appRouter.push(route);
      }
    }
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || generation != _homeWidgetRouteGeneration) {
          return;
        }
        final current = appRouter.routeInformationProvider.value.uri;
        final expected = Uri.parse(route);
        if (current.path == expected.path) {
          _pendingHomeWidgetRoute = null;
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 700), () {
              if (!mounted || generation != _homeWidgetRouteGeneration) {
                return;
              }
              startupRouteGate.completeWidgetLaunch();
            }),
          );
        } else if (attempt < 10) {
          _applyPendingHomeWidgetRoute(generation, attempt: attempt + 1);
        } else {
          startupRouteGate.completeWidgetLaunch();
        }
      }),
    );
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
String? resolveHomeWidgetRoute(Uri? uri) {
  if (uri == null || uri.scheme != 'planflow') {
    return null;
  }

  final query = uri.hasQuery ? '?${uri.query}' : '';
  switch (uri.host) {
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
