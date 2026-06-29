import 'dart:async';
import 'dart:io';

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

/// 네트워크 단절(오프라인) 계열 예외인지 판별한다.
/// Supabase/Postgrest는 호스트 조회 실패 시 SocketException 또는 http
/// ClientException을 던지는데, 이는 앱 버그가 아니라 단말 네트워크 상태 문제다.
bool _isNetworkError(Object? error) {
  if (error is SocketException || error is TimeoutException) {
    return true;
  }
  final text = error.toString().toLowerCase();
  return text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('host lookup') ||
      text.contains('clientexception') ||
      text.contains('connection closed') ||
      text.contains('connection reset') ||
      text.contains('network is unreachable');
}

/// 앱 시작 직후/백그라운드 전환/엔진 detach 시 플랫폼 채널이 일시적으로 끊겨
/// 발생하는 channel-error / MissingPluginException 계열인지 판별한다.
/// 앱 버그가 아니라 일시적 환경 문제이므로 fatal로 집계하지 않는다.
bool _isTransientChannelError(Object? error) {
  if (error is MissingPluginException) {
    return true;
  }
  final text = error.toString();
  return text.contains('channel-error') ||
      text.contains('Unable to establish connection on channel');
}

/// fatal 크래시로 집계하지 않을 비치명적 런타임 예외인지 판별한다.
@visibleForTesting
bool isNonFatalRuntimeError(Object? error) =>
    _isNetworkError(error) || _isTransientChannelError(error);

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
      // 오프라인/네트워크 단절, 일시적 플랫폼 채널 단절은 사용자 환경 문제이지
      // 앱 버그가 아니므로 fatal 크래시로 집계하지 않고 비치명적 이벤트로만 기록한다.
      if (isNonFatalRuntimeError(details.exception)) {
        debugPrint('Non-fatal runtime error: ${details.exception}');
        unawaited(
          FirebaseCrashlytics.instance
              .recordError(details.exception, details.stack, fatal: false),
        );
        return;
      }
      FlutterError.presentError(details);
      unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      final nonFatal = isNonFatalRuntimeError(error);
      debugPrint('Uncaught platform error (fatal=${!nonFatal}): $error');
      unawaited(
        FirebaseCrashlytics.instance
            .recordError(error, stack, fatal: !nonFatal),
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
