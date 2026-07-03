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

  /// 앱 시작 시 필수 환경변수를 검증한다.
  /// SUPABASE_URL 또는 SUPABASE_ANON_KEY가 누락/placeholder인 경우
  /// 명확한 안내 메시지와 함께 [StateError]를 throw한다.
  ///
  /// main()에서 runApp() 전에 호출하여 fail-fast 동작을 보장한다.
  static void validateRequiredConfig() {
    if (hasValidSupabaseConfig) {
      return;
    }

    final missing = <String>[];
    if (supabaseUrl.trim().isEmpty || _looksLikePlaceholder(supabaseUrl)) {
      missing.add('SUPABASE_URL');
    }
    if (supabaseAnonKey.trim().isEmpty ||
        _looksLikePlaceholder(supabaseAnonKey)) {
      missing.add('SUPABASE_ANON_KEY');
    }

    throw StateError(
      '[PlanFlow] 필수 환경변수가 누락되었거나 유효하지 않습니다.\n'
      '누락된 항목: ${missing.join(', ')}\n'
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
  }

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
