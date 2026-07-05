import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/supabase_client.dart';

/// SupabaseClientProvider 회귀 테스트.
///
/// 목적: Supabase 초기화 전/실패 상태에서 직접 `Supabase.instance.client`에
/// 접근하면 발생하던 StateError / LateInitializationError 크래시를 방지한다.
///
/// supabase_flutter 2.x의 `Supabase.instance` getter는 미초기화 시 StateError를
/// throw하므로, 래퍼는 `Supabase.instanceExists`를 우선 확인해야 한다.
void main() {
  group('SupabaseClientProvider (초기화 전 상태)', () {
    test('isAvailable은 초기화되지 않은 환경에서 false를 반환한다', () {
      // 테스트 환경에서는 Supabase.initialize()가 호출되지 않았으므로
      // instanceExists == false 이고 AppEnv.isSupabaseReady == false 이다.
      expect(SupabaseClientProvider.isAvailable, isFalse);
    });

    test('client는 초기화되지 않은 환경에서 null을 반환한다 (크래시 없음)', () {
      // 이전 코드: Supabase.instance.client 직접 접근 → StateError throw
      // 래퍼 도입 후: null 반환으로 안전한 fallback 가능
      expect(SupabaseClientProvider.client, isNull);
    });

    test('requireClient는 초기화되지 않은 환경에서 StateError를 throw한다', () {
      expect(
        SupabaseClientProvider.requireClient,
        throwsA(isA<StateError>()),
      );
    });

    test('currentUserId는 초기화되지 않은 환경에서 null을 반환한다', () {
      expect(SupabaseClientProvider.currentUserId, isNull);
    });
  });
}
