class AppEnv {
  static const _defaultSupabaseUrl = 'https://xqvvfnvmytjlblcngipn.supabase.co';
  static const _defaultSupabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhxdnZmbnZteXRqbGJsY25naXBuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc2MjAyNTQsImV4cCI6MjA5MzE5NjI1NH0.'
      '_YMZvcyy5W5-YUI--1kNrAzCAC9H8BfW2ku0DUpXIpM';

  static bool _supabaseInitialized = false;
  static bool _supabaseInitializationFailed = false;
  static String? _supabaseInitializationErrorMessage;
  static bool _naverMapInitialized = false;

  static String get supabaseUrl => _envValue('SUPABASE_URL');
  static String get supabaseAnonKey => _envValue('SUPABASE_ANON_KEY');
  static String get googleMapsApiKey => _envValue('GOOGLE_MAPS_API_KEY');
  static String get tmapApiKey => _envValue('TMAP_API_KEY');
  static String get naverMapClientId => _envValue('NAVER_MAP_CLIENT_ID');
  static String get naverMapProxyUrl =>
      _nonPlaceholderEnvValue('NAVER_MAP_PROXY_URL');
  static String get googleAndroidClientId =>
      _envValue('GOOGLE_ANDROID_CLIENT_ID');
  static String get googleWebClientId {
    final webClientId = _nonPlaceholderEnvValue('GOOGLE_WEB_CLIENT_ID');
    return webClientId.isNotEmpty
        ? webClientId
        : _nonPlaceholderEnvValue('GOOGLE_SERVER_CLIENT_ID');
  }

  static String get googleServerClientId {
    final serverClientId = _nonPlaceholderEnvValue('GOOGLE_SERVER_CLIENT_ID');
    return serverClientId.isNotEmpty ? serverClientId : googleWebClientId;
  }

  static String get naverClientId => _envValue('NAVER_CLIENT_ID');
  static String get authRedirectUrl => 'planflow-v2://auth-callback';

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
  static bool get isSupabaseInitializationFailed =>
      _supabaseInitializationFailed;
  static String? get supabaseInitializationErrorMessage =>
      _supabaseInitializationErrorMessage;
  static bool get isNaverMapReady => _naverMapInitialized;

  static bool get isConfigured => isSupabaseReady && hasValidSupabaseConfig;

  static void markSupabaseInitialized() {
    _supabaseInitialized = true;
    _supabaseInitializationFailed = false;
    _supabaseInitializationErrorMessage = null;
  }

  static void markSupabaseInitializationFailed([Object? error]) {
    _supabaseInitialized = false;
    _supabaseInitializationFailed = true;
    final message = error?.toString().trim();
    _supabaseInitializationErrorMessage = message != null && message.isNotEmpty
        ? message
        : 'Supabase 초기화에 실패했습니다.';
  }

  static void resetSupabaseInitializationState() {
    _supabaseInitialized = false;
    _supabaseInitializationFailed = false;
    _supabaseInitializationErrorMessage = null;
  }

  static void markNaverMapInitialized() {
    _naverMapInitialized = true;
  }

  static String _envValue(String key) {
    final compileTimeValue = _compileTimeEnvValue(key);
    if (compileTimeValue.trim().isNotEmpty) {
      return compileTimeValue;
    }
    return switch (key) {
      'SUPABASE_URL' => _defaultSupabaseUrl,
      'SUPABASE_ANON_KEY' => _defaultSupabaseAnonKey,
      _ => '',
    };
  }

  static String _nonPlaceholderEnvValue(String key) {
    final value = _envValue(key).trim();
    return value.isNotEmpty && !_looksLikePlaceholder(value) ? value : '';
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
      'NAVER_MAP_PROXY_URL' =>
        const String.fromEnvironment('NAVER_MAP_PROXY_URL'),
      'GOOGLE_WEB_CLIENT_ID' =>
        const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      'GOOGLE_SERVER_CLIENT_ID' =>
        const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
      'NAVER_CLIENT_ID' => const String.fromEnvironment('NAVER_CLIENT_ID'),
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
        normalized.contains('your-google-server-client-id') ||
        normalized.contains('your-google-maps-api-key') ||
        normalized.contains('your-tmap-api-key') ||
        normalized.contains('your-naver-map-client-id') ||
        normalized.contains('your-naver-map-client-secret') ||
        normalized.contains('your-naver-map-proxy-url');
  }
}
