import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static bool _supabaseInitialized = false;

  static String get supabaseUrl => _envValue('SUPABASE_URL');
  static String get supabaseAnonKey => _envValue('SUPABASE_ANON_KEY');
  static String get openAiApiKey => _envValue('OPENAI_API_KEY');
  static String get googleAndroidClientId =>
      _envValue('GOOGLE_ANDROID_CLIENT_ID');
  static String get naverClientId => _envValue('NAVER_CLIENT_ID');
  static String get naverClientSecret => _envValue('NAVER_CLIENT_SECRET');

  static bool get isSupabaseReady => _supabaseInitialized;

  static bool get isConfigured =>
      isSupabaseReady &&
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      openAiApiKey.isNotEmpty;

  static void markSupabaseInitialized() {
    _supabaseInitialized = true;
  }

  static String _envValue(String key) {
    try {
      return dotenv.env[key] ?? '';
    } catch (_) {
      return '';
    }
  }
}
