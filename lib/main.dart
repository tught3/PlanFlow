import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/env.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'services/remote_config_service.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/event_prefetch_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await RemoteConfigService.initialize();
  FirebaseAnalytics.instance;
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

  if (AppEnv.naverMapClientId.trim().isNotEmpty) {
    var naverMapAuthFailed = false;
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
      }
    } catch (error) {
      debugPrint('Naver Map initialization skipped: $error');
    }
  }
  if (AppEnv.hasValidSupabaseConfig) {
    try {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
        ),
      ).timeout(const Duration(seconds: 10));
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
    }
  }
  runApp(const ProviderScope(child: PlanFlowApp()));
}
