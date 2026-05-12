import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'core/constants.dart';
import 'core/env.dart';
import 'core/region_settings.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/repositories/settings_repository.dart';
import 'providers/auth_provider.dart';
import 'services/calendar_auto_sync_service.dart';
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
  StreamSubscription<List<SharedMediaFile>>? _sharedIcsSubscription;
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  final NaverIcsShareStore _naverIcsShareStore = const NaverIcsShareStore();
  final NotificationService _notificationService = NotificationService();
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _oauthCallbackHandler.start();
    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        unawaited(_syncSessionAndCalendar(reason: 'resume'));
        unawaited(UpdateService.checkAndPrompt());
      },
    );
    unawaited(_syncSessionAndCalendar(reason: 'startup'));
    unawaited(_listenForSharedIcsFiles());
    unawaited(_notificationService.scheduleMonthlyNaverIcsReminder());
    _routeInitialHomeWidgetLaunch();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
  }

  Future<void> _syncSessionAndCalendar({required String reason}) async {
    final signedIn = await authProvider.syncCurrentSession();
    if (!signedIn) {
      return;
    }
    await _syncRegionSettings();
    final currentPath = appRouter.routeInformationProvider.value.uri.path;
    if (currentPath == AppRoutes.login || currentPath == AppRoutes.root) {
      appRouter.go(AppRoutes.home);
    }
    final pendingIcsPaths = await _naverIcsShareStore.takePendingPaths();
    if (pendingIcsPaths.isNotEmpty) {
      appRouter.go(AppRoutes.naverIcsImport, extra: pendingIcsPaths);
      return;
    }
    await _calendarAutoSyncService.syncConnectedCalendars(reason: reason);
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

  @override
  void dispose() {
    _homeWidgetClickSubscription?.cancel();
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

    final signedIn =
        authProvider.isSignedIn || await authProvider.syncCurrentSession();
    if (!signedIn) {
      await _naverIcsShareStore.savePendingPaths(paths);
      appRouter.go(AppRoutes.login);
      return;
    }

    appRouter.go(AppRoutes.naverIcsImport, extra: paths);
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
  }

  void _handleHomeWidgetUri(Uri? uri) {
    if (uri == null) {
      return;
    }

    if (uri.scheme == 'planflow' &&
        (uri.host == 'voice' || uri.path == '/voice')) {
      appRouter.go(AppRoutes.voice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlanFlowRegionController.instance,
      builder: (context, _) {
        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          title: 'PlanFlow',
          theme: buildPlanFlowTheme(),
          locale: PlanFlowRegionController.instance.region.locale,
          supportedLocales: const [
            Locale('ko', 'KR'),
            Locale('en', 'US'),
            Locale('ja', 'JP'),
            Locale('en', 'GB'),
            Locale('de', 'DE'),
            Locale('fr', 'FR'),
            Locale('en', 'AU'),
          ],
          localizationsDelegates: const [
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
