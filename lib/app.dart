import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:planflow/l10n/app_localizations.dart';

import 'core/constants.dart';
import 'core/env.dart';
import 'core/region_settings.dart';
import 'core/router.dart';
import 'core/startup_route_gate.dart';
import 'core/theme.dart';
import 'data/repositories/settings_repository.dart';
import 'providers/auth_provider.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/app_feedback_service.dart';
import 'services/briefing_scheduler_service.dart';
import 'services/event_reminder_channel_migration_service.dart';
import 'services/smart_preparation_payload_migration_service.dart';
import 'services/naver_ics_share_store.dart';
import 'services/notification_service.dart';
import 'services/oauth_callback_handler.dart';
import 'services/update_service.dart';

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
  bool _reauthSnackBarShown = false;
  bool _startupUpdateCheckRunning = false;
  int _startupUpdateCheckGeneration = 0;
  final AppLinks _appLinks = AppLinks();
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  final NaverIcsShareStore _naverIcsShareStore = const NaverIcsShareStore();
  final NotificationService _notificationService = NotificationService();
  late final AppLifecycleListener _lifecycleListener;
  String? _pendingHomeWidgetRoute;
  int _homeWidgetRouteGeneration = 0;

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
        unawaited(BriefingSchedulerService.recordAppForegroundState(true));
        // widgetClicked 스트림이 유실된 warm-start를 복구하기 위해 먼저 실행
        unawaited(_resumeHomeWidgetCheck());
        unawaited(_syncSessionAndCalendar(reason: 'resume'));
        unawaited(_scheduleDeferredUpdateCheck());
      },
    );
    unawaited(BriefingSchedulerService.recordAppForegroundState(true));
    unawaited(_syncSessionAndCalendar(reason: 'startup'));
    unawaited(_listenForSharedIcsFiles());
    unawaited(_notificationService.scheduleMonthlyNaverIcsReminder());
    _routeInitialHomeWidgetLaunch();
    _listenForPlanFlowDeepLinks();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
    unawaited(_scheduleDeferredUpdateCheck());
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
    unawaited(_runChannelMigrations());
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
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_pendingUpdateRestoreRouteKey)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  Future<void> _savePendingUpdateRestoreRoute(String route) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingUpdateRestoreRouteKey, route);
  }

  Future<void> _clearPendingUpdateRestoreRoute() async {
    final prefs = await SharedPreferences.getInstance();
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
    } catch (_) {}
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
    appRouter.go(route);
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
        );
      },
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
