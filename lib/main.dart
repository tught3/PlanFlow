import 'dart:developer' as developer;
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
import 'core/supabase_auth_options.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'services/remote_config_service.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/event_prefetch_service.dart';

/// PlanFlow 앱 엔트리포인트.
///
/// 부팅 시퀀스:
///  1. WidgetsFlutterBinding 초기화
///  2. 필수 환경변수 검증 (누락 시 [StateError] throw → fail-fast)
///  3. 방향 고정 / 디버그 출력 제어
///  4. ProviderScope 로 앱 래핑 후 runApp(PlanFlowApp)
///     - PlanFlowApp 은 MaterialApp.router(routerConfig: appRouter) 사용
///     - 테마: buildPlanFlowTheme() 기본값 적용
///  5. 백그라운드에서 Supabase.initialize · Firebase · NaverMap 초기화
///     (스플래시 화면이 로딩 상태를 표시)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 필수 환경변수 사전 검증: 누락 시 명확한 에러로 fail-fast
  AppEnv.validateRequiredConfig();

  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  FlutterError.onError = FlutterError.presentError;

  // ProviderScope 로 앱을 래핑. PlanFlowApp 은 MaterialApp.router + appRouter 를 사용.
  runApp(const ProviderScope(child: PlanFlowApp()));
  unawaited(_initializePlatformServices());
}

Future<void> _initializePlatformServices() async {
  await _initializeFirebaseServices();
  await _initializeNaverMap();
  await _initializeSupabase();
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
    developer.log(
      'Naver Map init start',
      name: 'PlanFlow',
      error: 'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
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
        developer.log(
          'Naver Map init success',
          name: 'PlanFlow',
          error: 'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
        );
      }
    } catch (error) {
      developer.log(
        'Naver Map init failed: $error',
        name: 'PlanFlow',
        error: error,
        stackTrace: StackTrace.current,
      );
    }
  }
}

Future<void> _initializeSupabase() async {
  // main()에서 AppEnv.validateRequiredConfig() 를 이미 통과했으므로
  // 여기서는 hasValidSupabaseConfig 가 true 임이 보장된다.
  // 하지만 런타임 안전망으로 한 번 더 확인한다.
  if (AppEnv.hasValidSupabaseConfig) {
    try {
      developer.log('Supabase init start', name: 'PlanFlow');
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: buildPlanFlowAuthOptions(
          supabaseUrl: AppEnv.supabaseUrl,
          detectSessionInUri: false,
        ),
      ).timeout(const Duration(seconds: 10));
      AppEnv.markSupabaseInitialized();
      developer.log('Supabase init success', name: 'PlanFlow');
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
      AppEnv.markSupabaseInitializationFailed(error);
      developer.log(
        'Supabase init failed: $error',
        name: 'PlanFlow',
        error: error,
        stackTrace: StackTrace.current,
      );
      authProvider.start();
    }
  } else {
    authProvider.start();
  }
}
