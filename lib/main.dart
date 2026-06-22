import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/env.dart';
import 'core/local_time.dart';
import 'core/supabase_auth_options.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'services/remote_config_service.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/event_prefetch_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureTimeZonesInitialized();
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  FlutterError.onError = FlutterError.presentError;

  runApp(const ProviderScope(child: PlanFlowApp()));
  unawaited(_initializePlatformServices());
}

Future<void> _initializePlatformServices() async {
  await Future.wait([
    _initializeFirebaseServices(),
    _initializeNaverMap(),
    _initializeSupabase(),
  ]);
}

Future<void> _initializeFirebaseServices() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 8));
    await RemoteConfigService.initialize();
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught platform error: $error\n$stack');
      unawaited(
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
      );
      return true;
    };
  } catch (error) {
    debugPrint('Firebase initialization skipped: $error');
  }
}

Future<void> _initializeNaverMap() async {
  if (AppEnv.naverMapClientId.trim().isNotEmpty) {
    var naverMapAuthFailed = false;
    debugPrint(
      'Naver Map init start: package=com.fluxstudio.planflow '
      'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
    );
    try {
      await FlutterNaverMap()
          .init(
            clientId: AppEnv.naverMapClientId,
            onAuthFailed: (error) {
              naverMapAuthFailed = true;
              debugPrint('Naver Map auth failed: $error');
            },
          )
          .timeout(const Duration(seconds: 8));
      if (!naverMapAuthFailed) {
        AppEnv.markNaverMapInitialized();
        debugPrint(
          'Naver Map init ready: package=com.fluxstudio.planflow '
          'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
        );
      }
    } catch (error) {
      debugPrint('Naver Map initialization skipped: $error');
    }
  }
}

Future<void> _initializeSupabase() async {
  if (AppEnv.hasValidSupabaseConfig) {
    try {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: buildPlanFlowAuthOptions(
          supabaseUrl: AppEnv.supabaseUrl,
          detectSessionInUri: false,
        ),
      ).timeout(const Duration(seconds: 30));
      AppEnv.markSupabaseInitialized();
      authProvider.start();
      String? lastPrefetchedUserId;
      void syncPrefetchForAuthUser() {
        final userId = authProvider.userId;
        if (userId == null || userId.isEmpty) {
          lastPrefetchedUserId = null;
          EventPrefetchService().invalidate();
          return;
        }
        if (lastPrefetchedUserId == userId) {
          return;
        }
        lastPrefetchedUserId = userId;
        unawaited(EventPrefetchService().warmUp(userId));
      }

      syncPrefetchForAuthUser();
      authProvider.addListener(syncPrefetchForAuthUser);
      unawaited(const DailyCalendarSyncSchedulerService().scheduleDaily());
    } catch (error) {
      debugPrint('Supabase initialization skipped: $error');
      authProvider.start();
    }
  } else {
    authProvider.start();
  }
}
