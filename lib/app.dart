import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';

import 'core/constants.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'providers/auth_provider.dart';
import 'services/google_calendar_auto_sync_service.dart';
import 'services/oauth_callback_handler.dart';

class PlanFlowApp extends StatefulWidget {
  const PlanFlowApp({super.key});

  @override
  State<PlanFlowApp> createState() => _PlanFlowAppState();
}

class _PlanFlowAppState extends State<PlanFlowApp> {
  StreamSubscription<Uri?>? _homeWidgetClickSubscription;
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  final GoogleCalendarAutoSyncService _googleCalendarAutoSyncService =
      GoogleCalendarAutoSyncService();
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _oauthCallbackHandler.start();
    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_syncSessionAndCalendar(reason: 'resume')),
    );
    unawaited(_syncSessionAndCalendar(reason: 'startup'));
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
    final currentPath = appRouter.routeInformationProvider.value.uri.path;
    if (currentPath == AppRoutes.login || currentPath == AppRoutes.root) {
      appRouter.go(AppRoutes.home);
    }
    await _googleCalendarAutoSyncService.syncIfAllowed(reason: reason);
  }

  @override
  void dispose() {
    _homeWidgetClickSubscription?.cancel();
    unawaited(_oauthCallbackHandler.dispose());
    _lifecycleListener.dispose();
    super.dispose();
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
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'PlanFlow',
      theme: buildPlanFlowTheme(),
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [
        Locale('ko', 'KR'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      routerConfig: appRouter,
    );
  }
}
