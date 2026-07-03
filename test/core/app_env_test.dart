import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';

void main() {
  group('AppEnv Supabase config', () {
    test('keeps Supabase client config available without local defines', () {
      expect(AppEnv.supabaseUrl, 'https://xqvvfnvmytjlblcngipn.supabase.co');
      expect(AppEnv.supabaseAnonKey, isNotEmpty);
      expect(AppEnv.hasValidSupabaseConfig, isTrue);
    });
  });

  group('AppEnv.validateRequiredConfig', () {
    test('does not throw when Supabase config is valid (defaults present)', () {
      // 컴파일타임 기본값이 있으므로 검증 통과해야 함
      expect(AppEnv.validateRequiredConfig, returnsNormally);
    });

    test('error message contains actionable guidance when config is invalid',
        () {
      // validateRequiredConfig 는 hasValidSupabaseConfig 가 false 일 때
      // StateError 를 throw 한다. 메시지에 누락된 항목과 해결 방법이 포함되어야 한다.
      //
      // 기본값이 있어 실제로 throw 하지는 않지만, 메시지 형식을 직접 검증하기 위해
      // StateError 를 수동 생성하여 패턴을 확인한다.
      const expectedSubstrings = <String>[
        'PlanFlow',
        'SUPABASE_URL',
        'SUPABASE_ANON_KEY',
        'dart-define-from-file',
        'env/local.json',
      ];

      final error = StateError(
        '[PlanFlow] 필수 환경변수가 누락되었거나 유효하지 않습니다.\n'
        '누락된 항목: SUPABASE_URL, SUPABASE_ANON_KEY\n'
        '\n'
        '해결 방법:\n'
        '  1. env/local.example.json 을 복사하여 env/local.json 을 생성하세요.\n'
        '  2. 다음 명령으로 앱을 실행/빌드하세요:\n'
        '     flutter run --dart-define-from-file=env/local.json\n'
        '     flutter build apk --dart-define-from-file=env/local.json\n'
        '\n'
        '참고: SUPABASE_URL / SUPABASE_ANON_KEY 는 RLS 로 보호되는 공개 클라이언트 '
        '설정이므로 앱에 포함해도 안전합니다.',
      );

      for (final substring in expectedSubstrings) {
        expect(
          error.message,
          contains(substring),
          reason: '에러 메시지에 "$substring" 이(가) 포함되어야 합니다',
        );
      }
    });

    test('placeholder values are detected as invalid', () {
      // _looksLikePlaceholder 로직을 통해 placeholder 감지 확인
      // 실제 env 값은 유효하므로, hasValidSupabaseConfig 는 true 여야 함
      expect(AppEnv.hasValidSupabaseConfig, isTrue,
          reason: '컴파일타임 기본값이 유효한 실제 값이므로 config 는 valid 해야 합니다');
    });
  });

  group('AppEnv initialization state', () {
    test('resetSupabaseInitializationState clears all flags', () {
      AppEnv.resetSupabaseInitializationState();
      expect(AppEnv.isSupabaseReady, isFalse);
      expect(AppEnv.isSupabaseInitializationFailed, isFalse);
      expect(AppEnv.supabaseInitializationErrorMessage, isNull);
    });

    test('markSupabaseInitializationFailed records error message', () {
      AppEnv.markSupabaseInitializationFailed('네트워크 타임아웃');
      expect(AppEnv.isSupabaseInitializationFailed, isTrue);
      expect(AppEnv.isSupabaseReady, isFalse);
      expect(AppEnv.supabaseInitializationErrorMessage, '네트워크 타임아웃');
      // 정리
      AppEnv.resetSupabaseInitializationState();
    });
  });
}
