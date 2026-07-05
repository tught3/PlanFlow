import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

/// Supabase 싱글턴 클라이언트 접근을 중앙화하는 래퍼 모듈.
///
/// 이 모듈은 lib/main.dart 의 [_initializeSupabase] 호출로 생성된
/// `Supabase.instance.client` 에 대한 단일 진입점을 제공한다.
///
/// ## 도입 배경
/// 코드베이스 전체(Repository / Screen / Provider 등 30+ 지점)에서
/// `Supabase.instance.client`를 직접 참조하고 있었다. 이를 통해 다음 문제가
/// 반복 발생했다:
/// - **초기화 전 접근**: `Supabase.initialize()`는 async + 10s 타임아웃으로
///   지연 실행되므로, 초기화 완료 전에 접근하면
///   `LateInitializationError` / null-dereference 크래시가 발생한다.
/// - **초기화 실패 후 접근**: 환경 설정 누락이나 타임아웃 시에도
///   `Supabase.instance`에 접근하는 코드가 있어 회복 불가능한 장애를 유발한다.
/// - **`Supabase.instance` 자체의 throw 동작**: supabase_flutter 2.x에서는
///   `Supabase.instance` getter가 초기화되지 않은 상태에서 `StateError`를
///   throw한다. `Supabase.instance != null`과 같은 비교는 의미가 없으며
///   예외를 발생시킨다.
///
/// 이 래퍼는 [SupabaseClientProvider.client]를 통해 안전한 접근을 보장하고,
/// 준비되지 않은 상태에서는 명확한 에러 로그 + null 반환(또는 예외)을 제공한다.
class SupabaseClientProvider {
  SupabaseClientProvider._();

  /// Supabase가 현재 사용 가능한지 여부.
  ///
  /// 세 조건을 모두 만족해야 true:
  /// 1. `Supabase.instanceExists` — 패키지 싱글턴이 초기화됨 (StateError 방지)
  /// 2. `AppEnv.isSupabaseReady` — 앱 레벨 초기화 성공 플래그
  ///
  /// `AppEnv.isSupabaseReady`가 true라면 항상 instanceExists도 true이지만,
  /// 방어적으로 둘 다 확인한다.
  static bool get isAvailable {
    return AppEnv.isSupabaseReady && Supabase.instanceExists;
  }

  /// 현재 활성 Supabase 클라이언트를 반환한다.
  ///
  /// 초기화가 완료되지 않았거나 실패한 경우 `null`을 반환한다.
  /// 호출부에서 null 검사 후 안전하게 fallback 로직을 수행할 수 있다.
  static SupabaseClient? get client {
    if (!isAvailable) {
      if (kDebugMode) {
        debugPrint(
          'SupabaseClientProvider: client accessed before initialization. '
          'ready=${AppEnv.isSupabaseReady}, '
          'instanceExists=${Supabase.instanceExists}, '
          'failed=${AppEnv.isSupabaseInitializationFailed}',
        );
      }
      return null;
    }
    try {
      return Supabase.instance.client;
    } catch (error, stackTrace) {
      debugPrint('SupabaseClientProvider: failed to resolve client: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  /// 초기화되지 않은 상태에서 호출되면 [StateError]를 던진다.
  ///
  /// Repository의 non-null 필드 초기화처럼 클라이언트가 반드시 필요한
  /// 코드 경로에서 사용한다. 호출부에서 [isAvailable]을 먼저 확인하는 것이
  /// 권장된다.
  static SupabaseClient requireClient() {
    final resolved = client;
    if (resolved == null) {
      throw StateError(
        'Supabase client is not available. '
        'ready=${AppEnv.isSupabaseReady}, '
        'instanceExists=${Supabase.instanceExists}, '
        'failed=${AppEnv.isSupabaseInitializationFailed}, '
        'message=${AppEnv.supabaseInitializationErrorMessage}',
      );
    }
    return resolved;
  }

  /// 현재 로그인된 사용자 ID를 반환한다.
  /// 클라이언트를 사용할 수 없거나 세션이 없으면 `null`을 반환한다.
  static String? get currentUserId {
    final resolved = client;
    if (resolved == null) {
      return null;
    }
    return resolved.auth.currentUser?.id;
  }
}
