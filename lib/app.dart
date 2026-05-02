import 'dart:async';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'core/constants.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'providers/auth_provider.dart';
import 'services/oauth_callback_handler.dart';

class PlanFlowApp extends StatefulWidget {
  const PlanFlowApp({super.key});

  @override
  State<PlanFlowApp> createState() => _PlanFlowAppState();
}

class _PlanFlowAppState extends State<PlanFlowApp> {
  StreamSubscription<Uri?>? _homeWidgetClickSubscription;
  final OAuthCallbackHandler _oauthCallbackHandler = OAuthCallbackHandler();
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _oauthCallbackHandler.start();
    _lifecycleListener = AppLifecycleListener(
      onResume: () =>
          unawaited(authProvider.syncCurrentSession(ensureProfile: false)),
    );
    _routeInitialHomeWidgetLaunch();
    _homeWidgetClickSubscription = HomeWidget.widgetClicked.listen(
      _handleHomeWidgetUri,
    );
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
      routerConfig: appRouter,
    );
  }
}
