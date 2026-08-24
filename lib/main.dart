import 'dart:developer' as developer;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/analytics_service.dart';
import 'core/diag_logger.dart';
import 'core/env.dart';
import 'core/local_time.dart';
import 'core/runtime_error_filter.dart';
import 'core/startup_route_gate.dart';
import 'core/supabase_auth_options.dart';
import 'providers/auth_provider.dart';
import 'services/remote_config_service.dart';
import 'services/calendar_auto_sync_service.dart';
import 'services/event_prefetch_service.dart';
import 'services/kasi_holiday_service.dart';
import 'services/ad_service.dart';
import 'features/groups/services/group_cleanup_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  startupRouteGate.beginStartupWorkDeferral();
  ensureTimeZonesInitialized();
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // Use Flutter's supported edge-to-edge mode instead of legacy system-bar
  // color/visibility APIs. SafeArea widgets keep interactive content clear of
  // the system insets while Android 15+ enforces edge-to-edge by default.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  FlutterError.onError = FlutterError.presentError;

  runApp(const ProviderScope(child: PlanFlowApp()));
  unawaited(_initializePlatformServices());
  unawaited(_scheduleStaleGroupAlarmReconcile());
}

Future<void>? _staleGroupAlarmReconcile;
Future<void>? _dailyCalendarSyncSchedule;

Future<void> _scheduleStaleGroupAlarmReconcile() {
  return _staleGroupAlarmReconcile ??= () async {
    // This is non-essential startup work. Keep it behind the same onboarding
    // and settled-idle permit as platform services, and claim it once so
    // auth/lifecycle callbacks cannot start duplicate queries.
    await startupRouteGate.startupWorkAllowedWhenIdle;
    await _reconcileStaleGroupAlarms();
  }();
}

Future<void> _scheduleDailyCalendarSyncAfterStartup() {
  final existing = _dailyCalendarSyncSchedule;
  if (existing != null) return existing;
  final future = () async {
    try {
      await startupRouteGate.startupWorkAllowedWhenIdle;
      await const DailyCalendarSyncSchedulerService().scheduleDaily();
    } catch (error, stackTrace) {
      _dailyCalendarSyncSchedule = null;
      debugPrint('Daily calendar sync scheduling deferred: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }();
  _dailyCalendarSyncSchedule = future;
  return future;
}

Future<void> _initializePlatformServices() async {
  // Firebase/Crashlytics/NaverMap/광고/공휴일 캐시는 로그인 여부와 무관하게
  // time-0부터 즉시 시작한다 — 이들은 필수 인프라라, 로그인에 도달하지 못하는
  // 세션(예: _initializeSupabase의 재시도 루프가 버텨내려는 "Supabase가
  // 끝내 준비되지 않는" 실패 모드)에서도 에러 리포팅(Crashlytics)이 반드시
  // 살아있어야 한다. startupRouteGate.startupWorkAllowedWhenIdle에는
  // 타임아웃/폴백이 없고 shell_screen이 로그인 후 홈 화면에 도달해야만
  // 풀리므로, 과거 이 함수 전체를 그 게이트 뒤로 묶었던 버전(7a57af99)은
  // 로그인하지 못한 모든 세션에서 Firebase/NaverMap/광고를 영구히 실행하지
  // 않는 회귀였다(리뷰에서 확인, 여기서 수정). 진짜 로그인 의존적인 작업
  // (그룹 알람 정리, 일일 캘린더 동기화)만 각자의 스케줄 함수 내부에서 그
  // 게이트를 계속 기다린다 — 이 함수 자체에는 더 이상 게이트가 없다.
  //
  // firebaseReady는 여기서 만들되 즉시 await하지 않는다 — Supabase 초기화가
  // 이 Future와 병렬로 진행되게 하기 위함이다(2026-08-12 f027c0a2가 이걸
  // await로 앞세워 Supabase 준비 시점을 늦춰 첫 프레임 크래시를 유발한 회귀를
  // 되돌린다). AdService만 이 Future를 내부에서 기다린다(_primingAdService
  // 참조) — 그래서 RemoteConfig 값이 정착하기 전에 광고를 영구 비활성화하던
  // 원래 버그(f027c0a2가 고친 것)는 재발하지 않는다.
  final firebaseReady = _initializeFirebaseServices();
  await _initializeSupabase();
  await Future.wait([
    firebaseReady,
    _initializeNaverMap(),
    _primingAdService(firebaseReady),
    _primeHolidayCache(),
  ]);
}

/// 부팅 시 active 그룹 집합을 조회하고, 그 집합에 들지 않는 그룹 이벤트의
/// 알림/알람을 정리한다. 부팅 블로킹을 막기 위해 main()에서 unawaited로 호출.
///
/// - currentUser가 아직 준비되지 않았거나 미로그인 상태면 즉시 스킵한다.
/// - 그룹 조회는 RLS로 본인 그룹만 반환된다.
/// - 10초 타임아웃 / 예외는 앱 시작을 막지 않고 로그만 남긴다(fail-open).
Future<void> _reconcileStaleGroupAlarms() async {
  try {
    if (!AppEnv.isSupabaseReady) {
      debugPrint('[BootReconcile] Supabase not ready, skipping');
      return;
    }
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      debugPrint(
        '[BootReconcile] No user session, skipping stale alarm reconcile',
      );
      return;
    }

    final activeGroups = await client
        .from('groups')
        .select('id')
        .eq('status', 'active')
        .timeout(const Duration(seconds: 10));

    final activeGroupIds =
        (activeGroups as List).map((row) => row['id'] as String).toSet();

    debugPrint(
      '[BootReconcile] Found ${activeGroupIds.length} active groups',
    );

    await GroupCleanupService.instance.reconcileStaleAlarms(
      activeGroupIds,
      userId: userId,
    );
  } on TimeoutException {
    debugPrint('[BootReconcile] Query timeout, skipping');
  } catch (error, stack) {
    debugPrint('[BootReconcile] Failed: $error\n$stack');
  }
}

/// 1차 BM: GPT 일정 파싱 리워드 광고 초기화. Remote Config가 OFF면 즉시 종료.
///
/// [firebaseReady]는 `_initializeFirebaseServices()`가 반환한 것과 동일한
/// Future 인스턴스를 그대로 전달받아 먼저 기다린다. AdService.initialize()가
/// RemoteConfigService.rewardedAdEnabled를 동기로 읽기 때문에 RemoteConfig
/// fetch가 settle되기 전에 읽으면 컴파일타임 기본값(false)을 읽어 광고를
/// 영구 비활성화하는 경쟁 상태가 있었다(2026-08-12 확인, f027c0a2에서 최초 수정).
/// 단, 여기서 RemoteConfigService.initialize()를 직접 다시 호출하지 않는다 —
/// 그 함수는 Firebase.apps가 비어 있으면 fetch를 건너뛰고 _initialized를
/// 영구 true로 고정해버리므로, Firebase.initializeApp() 완료 전에 호출되면
/// RemoteConfig가 앱 전체에서 영원히 기본값만 쓰게 되는 더 심각한 회귀가 난다.
///
/// 의존성 google_mobile_ads가 pubspec에 추가돼 있어야 한다. 빌드 환경에서
/// 패키지가 누락되면 Dynamic loading 없이도 import 자체가 깨질 수 있어
/// try/catch로 격리한다.
Future<void> _primingAdService(Future<void> firebaseReady) async {
  try {
    await firebaseReady;
    await AdService.instance.initialize();
    // 진단 신호 (M4, 이슈 A). priming 후에도 _initialized=false면
    // RC OFF / UMP unavailable / MobileAds 실패 중 어딘가에서 광고가
    // 조기 종료된 상태다. release에선 AnalyticsService가 no-op이지만
    // debug/profile에선 즉시 grep 가능하고 추후 SDK 활성화 시 자동 수집.
    // logAdInitSkipped는 현재 부재해 가장 가까운 logAdLoadFailed 경유.
    if (!AdService.instance.isInitialized) {
      unawaited(
        AnalyticsService.logAdLoadFailed(
          reason: 'post_prime_not_initialized',
          requestId: 'ad_init',
        ),
      );
    }
  } catch (error, stack) {
    debugPrint('AdService initialize skipped: $error');
    // 진단 신호 (M4, 이슈 A). try/catch 자체가 이미 네트워크/일시 오류를
    // best-effort로 흡수하지만, 크래시 추적용 Crashlytics에는 fatal=false
    // 로 남겨 silent fail이 운영 환경에서도 가시화되게 한다.
    unawaited(
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false),
    );
  }
}

/// 한국천문연구원 공공 API로 올해·작년·내년 공휴일 데이터를 백그라운드로
/// 받아와 [KoreanHolidays]에 반영한다. 실패해도 klc 계산값으로 계속
/// 동작하므로 앱 시작을 막지 않는다(fail-open, 결과를 기다리지 않음).
Future<void> _primeHolidayCache() async {
  try {
    final thisYear = DateTime.now().year;
    await KasiHolidayService.instance.primeYears(
      [thisYear - 1, thisYear, thisYear + 1],
    );
  } catch (error) {
    debugPrint('Holiday cache priming skipped: $error');
  }
}

Future<void> _initializeFirebaseServices() async {
  try {
    // Firebase Core has one shared, recoverable startup path. Remote Config
    // owns its separate 10s fetch timeout and retry state.
    if (!await RemoteConfigService.ensureFirebaseInitialized()) return;
    await RemoteConfigService.initialize();
    FlutterError.onError = (FlutterErrorDetails details) {
      // 오프라인/네트워크 단절은 사용자 환경 문제라 Crashlytics 이슈로 보내지 않는다.
      if (shouldDropFromCrashlytics(details.exception)) {
        debugPrint('Dropped network runtime error: ${details.exception}');
        return;
      }
      // 일시적 플랫폼 채널 단절은 fatal 크래시로 집계하지 않는다.
      if (shouldReportNonFatalToCrashlytics(details.exception)) {
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
      if (shouldDropFromCrashlytics(error)) {
        debugPrint('Dropped uncaught network error: $error');
        return true;
      }
      final nonFatal = shouldReportNonFatalToCrashlytics(error);
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
  final naverConfigured = AppEnv.naverMapClientId.trim().isNotEmpty;
  final googleConfigured = AppEnv.googleMapsApiKey.trim().isNotEmpty;
  final tmapConfigured = AppEnv.tmapApiKey.trim().isNotEmpty;
  DiagLogger.log(
    'MapInit',
    'config naver=$naverConfigured google=$googleConfigured tmap=$tmapConfigured',
  );

  if (naverConfigured) {
    var naverMapAuthFailed = false;
    developer.log(
      'Naver Map init start',
      name: 'PlanFlow',
      error: 'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
    );
    DiagLogger.log('MapInit', 'naver start');
    try {
      await FlutterNaverMap()
          .init(
            clientId: AppEnv.naverMapClientId,
            onAuthFailed: (error) {
              naverMapAuthFailed = true;
              debugPrint('Naver Map auth failed: $error');
              DiagLogger.log('MapInit', 'naver auth_failed');
            },
          )
          .timeout(const Duration(seconds: 8));
      if (!naverMapAuthFailed) {
        AppEnv.markNaverMapInitialized();
        DiagLogger.log('MapInit', 'naver success');
        developer.log(
          'Naver Map init success',
          name: 'PlanFlow',
          error: 'clientIdSet=${AppEnv.naverMapClientId.trim().isNotEmpty}',
        );
      }
    } on TimeoutException {
      DiagLogger.log('MapInit', 'naver timeout');
    } catch (error) {
      DiagLogger.log('MapInit', 'naver failed type=${error.runtimeType}');
      developer.log(
        'Naver Map init failed: $error',
        name: 'PlanFlow',
        error: error,
        stackTrace: StackTrace.current,
      );
    }
  }

  if (!AppEnv.isNaverMapReady && googleConfigured) {
    DiagLogger.log('MapInit', 'google fallback available');
  } else if (!AppEnv.isNaverMapReady && !googleConfigured) {
    DiagLogger.log('MapInit', 'unavailable naver=false google=false');
  }
}

Future<void> _initializeSupabase() async {
  if (AppEnv.hasValidSupabaseConfig) {
    Object? lastError;
    for (var attempt = 0; attempt < 3 && !AppEnv.isSupabaseReady; attempt++) {
      try {
        developer.log('Supabase init start attempt=${attempt + 1}',
            name: 'PlanFlow');
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
      } catch (error) {
        lastError = error;
        developer.log('Supabase init attempt failed',
            name: 'PlanFlow', error: error);
        if (attempt < 2) {
          await Future<void>.delayed(
              Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
    }
    if (!AppEnv.isSupabaseReady) {
      final error = lastError ?? StateError('Supabase initialization failed');
      AppEnv.markSupabaseInitializationFailed(error);
      debugPrint('Supabase initialization unavailable after retry: $error');
      authProvider.start();
    } else {
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
      unawaited(_scheduleDailyCalendarSyncAfterStartup());
    }
  } else {
    authProvider.start();
  }
}
