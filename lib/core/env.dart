import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static bool _supabaseInitialized = false;

  static String get supabaseUrl => _envValue('SUPABASE_URL');
  static String get supabaseAnonKey => _envValue('SUPABASE_ANON_KEY');
  static String get openAiApiKey => _envValue('OPENAI_API_KEY');
  static String get googleAndroidClientId =>
      _envValue('GOOGLE_ANDROID_CLIENT_ID');
  static String get googleWebClientId {
    final webClientId = _envValue('GOOGLE_WEB_CLIENT_ID');
    return webClientId.isNotEmpty
        ? webClientId
        : _envValue('GOOGLE_SERVER_CLIENT_ID');
  }

  static String get googleServerClientId => googleWebClientId;
  static String get naverClientId => _envValue('NAVER_CLIENT_ID');
  static String get naverClientSecret => _envValue('NAVER_CLIENT_SECRET');
  static String get authRedirectUrl => 'planflow://auth-callback';

  static bool get isSupabaseReady => _supabaseInitialized;

  static bool get isConfigured =>
      isSupabaseReady && supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static void markSupabaseInitialized() {
    _supabaseInitialized = true;
  }

  static String _envValue(String key) {
    final compileTimeValue = _compileTimeEnvValue(key);
    if (compileTimeValue.isNotEmpty) {
      return compileTimeValue;
    }

    try {
      return dotenv.env[key] ?? '';
    } catch (_) {
      return '';
    }
  }

  static String _compileTimeEnvValue(String key) {
    return switch (key) {
      'SUPABASE_URL' => const String.fromEnvironment('SUPABASE_URL'),
      'SUPABASE_ANON_KEY' => const String.fromEnvironment('SUPABASE_ANON_KEY'),
      'GOOGLE_ANDROID_CLIENT_ID' =>
        const String.fromEnvironment('GOOGLE_ANDROID_CLIENT_ID'),
      'GOOGLE_WEB_CLIENT_ID' =>
        const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      'GOOGLE_SERVER_CLIENT_ID' =>
        const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
      'NAVER_CLIENT_ID' => const String.fromEnvironment('NAVER_CLIENT_ID'),
      'NAVER_CLIENT_SECRET' =>
        const String.fromEnvironment('NAVER_CLIENT_SECRET'),
      _ => '',
    };
  }
}
