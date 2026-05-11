import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';

void main() {
  test('AppEnv keeps Supabase client config available without local defines',
      () {
    expect(AppEnv.supabaseUrl, 'https://xqvvfnvmytjlblcngipn.supabase.co');
    expect(AppEnv.supabaseAnonKey, isNotEmpty);
    expect(AppEnv.hasValidSupabaseConfig, isTrue);
  });
}
