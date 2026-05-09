import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static bool _supabaseInitialized = false;
  static bool _naverMapInitialized = false;

  static String get supabaseUrl => _envValue('SUPABASE_URL');
  static String get supabaseAnonKey => _envValue('SUPABASE_ANON_KEY');
  static String get googleMapsApiKey => _envValue('GOOGLE_MAPS_API_KEY');
  static String get tmapApiKey => _envValue('TMAP_API_KEY');
  static String get naverMapClientId => _envValue('NAVER_MAP_CLIENT_ID');
  static String get naverMapClientSecret =>
      _envValue('NAVER_MAP_CLIENT_SECRET');
  static String get naverMapProxyUrl => _envValue('NAVER_MAP_PROXY_URL');
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

  static bool get hasValidSupabaseConfig {
    final url = supabaseUrl.trim();
    final anonKey = supabaseAnonKey.trim();

    if (url.isEmpty || anonKey.isEmpty) {
      return false;
    }

    if (_looksLikePlaceholder(url) || _looksLikePlaceholder(anonKey)) {
      return false;
    }

    return true;
  }

  static bool get isSupabaseReady => _supabaseInitialized;
  static bool get isNaverMapReady => _naverMapInitialized;

  static bool get isConfigured => isSupabaseReady && hasValidSupabaseConfig;

  static void markSupabaseInitialized() {
    _supabaseInitialized = true;
  }

  static void markNaverMapInitialized() {
    _naverMapInitialized = true;
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
      'GOOGLE_MAPS_API_KEY' =>
        const String.fromEnvironment('GOOGLE_MAPS_API_KEY'),
      'TMAP_API_KEY' => const String.fromEnvironment('TMAP_API_KEY'),
      'NAVER_MAP_CLIENT_ID' =>
        const String.fromEnvironment('NAVER_MAP_CLIENT_ID'),
      'NAVER_MAP_CLIENT_SECRET' =>
        const String.fromEnvironment('NAVER_MAP_CLIENT_SECRET'),
      'NAVER_MAP_PROXY_URL' =>
        const String.fromEnvironment('NAVER_MAP_PROXY_URL'),
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

  static bool _looksLikePlaceholder(String value) {
    final normalized = value.toLowerCase();
    return normalized.startsWith('your-') ||
        normalized.contains('your-project.supabase.co') ||
        normalized.contains('your-supabase-anon-key') ||
        normalized.contains('your-google-web-client-id') ||
        normalized.contains('your-google-android-client-id') ||
        normalized.contains('your-google-maps-api-key') ||
        normalized.contains('your-tmap-api-key') ||
        normalized.contains('your-naver-map-client-id') ||
        normalized.contains('your-naver-map-client-secret') ||
        normalized.contains('your-naver-map-proxy-url');
  }
}
