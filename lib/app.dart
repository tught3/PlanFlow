import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:planflow/l10n/app_localizations.dart';

import 'core/constants.dart';
import 'core/env.dart';
import 'core/region_settings.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/repositories/settings_repository.dart';
import 'providers/auth_provider.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/app_feedback_service.dart';
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
  StreamSubscription<Uri?>? _homeWidgetClickSubscription;
  StreamSubscription<Uri>? _planFlowLinkSubscription;
  StreamSubscription<List<SharedMediaFile>>? _sharedIcsSubscription;
  bool _reauthSnackBarShown = false;
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
    _lifecycleListener = AppLifecycleListener(
      onPause: () {
        unawaited(_syncCalendarInBackground());
      },
      onResume: () {
        unawaited(_syncSessionAndCalendar(reason: 'resume'));
        unawaited(_checkForAppUpdate());
      },
    );
    unawaited(_checkForAppUpdate());
    unawaited(_syncSessionAndCalendar(reason: 'startup'));
    unawaited(_listenForSharedIcsFiles());
    unawaited(_notificationService.scheduleMonthlyNaverIcsReminder());
    _routeInitialHomeWidgetLaunch();
    _listenForPlanFlowDeepLinks();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
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
    final pendingIcsPaths = await _naverIcsShareStore.takePendingPaths();
    if (pendingIcsPaths.isNotEmpty) {
      appRouter.go(AppRoutes.naverIcsImport, extra: pendingIcsPaths);
      return;
    }
    await _calendarAutoSyncService.syncConnectedCalendars(reason: reason);
  }

  Future<void> _checkForAppUpdate() async {
    await UpdateService.checkAndPrompt();
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
  }

  @override
  void dispose() {
    authProvider.removeListener(_onAuthProviderChange);
    _homeWidgetClickSubscription?.cancel();
    _planFlowLinkSubscription?.cancel();
    _sharedIcsSubscription?.cancel();
    unawaited(_oauthCallbackHandler.dispose());
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
    if (!mounted || _pendingHomeWidgetRoute != null || attempt >= 4) {
      return;
    }
    unawaited(
      Future<void>.delayed(Duration(milliseconds: 180 * (attempt + 1)),
          () async {
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
        if (current.path == expected.path && current.query == expected.query) {
          _pendingHomeWidgetRoute = null;
        } else if (attempt < 10) {
          _applyPendingHomeWidgetRoute(generation, attempt: attempt + 1);
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
