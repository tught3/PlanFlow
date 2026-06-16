import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/analytics_service.dart';
import '../core/env.dart';
import '../core/router.dart';
import '../providers/auth_provider.dart';
import 'auth_service.dart';
import 'calendar_sync_service.dart';
import 'naver_calendar_permission_service.dart';

enum OAuthCallbackPurpose {
  login,
  calendarLink,
  emailConfirmation,
}

class OAuthCallbackHandler {
  OAuthCallbackHandler({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  static final ValueNotifier<String?> latestUserMessage =
      ValueNotifier<String?>(null);
  static OAuthCallbackPurpose? _pendingPurpose;
  static String? _pendingMethod;
  static DateTime? _pendingStartedAt;
  static const _storedPendingPurposeKey = 'oauth_callback_pending_purpose';
  static const _storedPendingMethodKey = 'oauth_callback_pending_method';
  static const _storedPendingStartedAtKey = 'oauth_callback_pending_started_at';

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;
  bool _initialLinkHandled = false;

  static void markPendingLogin(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    _pendingPurpose = OAuthCallbackPurpose.login;
    _pendingMethod = switch (provider) {
      PlanFlowOAuthProvider.google => 'google',
      PlanFlowOAuthProvider.kakao => 'kakao',
      PlanFlowOAuthProvider.naver => 'naver',
    };
    _pendingStartedAt = DateTime.now();
    unawaited(persistCurrentPendingCallback());
  }

  static void markPendingCalendarLink(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    _pendingPurpose = OAuthCallbackPurpose.calendarLink;
    _pendingMethod = switch (provider) {
      PlanFlowOAuthProvider.google => 'google',
      PlanFlowOAuthProvider.kakao => 'kakao',
      PlanFlowOAuthProvider.naver => 'naver',
    };
    _pendingStartedAt = DateTime.now();
    unawaited(persistCurrentPendingCallback());
  }

  static void markPendingEmailConfirmation() {
    clearLatestUserMessage();
    _pendingPurpose = OAuthCallbackPurpose.emailConfirmation;
    _pendingMethod = 'email';
    _pendingStartedAt = DateTime.now();
    unawaited(persistCurrentPendingCallback());
  }

  static String? consumePendingLoginMethod() {
    final purpose = _pendingPurpose;
    final method = _pendingMethod;
    final startedAt = _pendingStartedAt;
    clearPendingCallback();
    if (purpose != OAuthCallbackPurpose.login ||
        method == null ||
        startedAt == null ||
        DateTime.now().difference(startedAt) > const Duration(minutes: 10)) {
      return null;
    }
    return method;
  }

  static void clearPendingCallback() {
    _pendingPurpose = null;
    _pendingMethod = null;
    _pendingStartedAt = null;
    unawaited(_clearStoredPendingCallback());
  }

  static void clearLatestUserMessage() {
    latestUserMessage.value = null;
  }

  static bool hasPendingLogin({
    Duration maxAge = const Duration(minutes: 10),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.login &&
        _pendingMethod != null &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static bool hasPendingCalendarLink({
    Duration maxAge = const Duration(minutes: 10),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.calendarLink &&
        _pendingMethod != null &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static bool hasPendingEmailConfirmation({
    Duration maxAge = const Duration(hours: 24),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.emailConfirmation &&
        _pendingMethod == 'email' &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static String? get pendingLoginMethod {
    if (!hasPendingLogin()) {
      return null;
    }
    return _pendingMethod;
  }

  static Future<void> persistCurrentPendingCallback() async {
    final purpose = _pendingPurpose;
    final method = _pendingMethod;
    final startedAt = _pendingStartedAt;
    if (purpose == null || method == null || startedAt == null) {
      await _clearStoredPendingCallback();
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storedPendingPurposeKey, purpose.name);
      await prefs.setString(_storedPendingMethodKey, method);
      await prefs.setInt(
        _storedPendingStartedAtKey,
        startedAt.millisecondsSinceEpoch,
      );
    } catch (error) {
      debugPrint('OAuth pending callback persist skipped: $error');
    }
  }

  static Future<void> _clearStoredPendingCallback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storedPendingPurposeKey);
      await prefs.remove(_storedPendingMethodKey);
      await prefs.remove(_storedPendingStartedAtKey);
    } catch (error) {
      debugPrint('OAuth pending callback clear skipped: $error');
    }
  }

  static Future<_StoredOAuthPending?> _readStoredPendingCallback({
    Duration maxAge = const Duration(minutes: 10),
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final purposeName = prefs.getString(_storedPendingPurposeKey);
      final method = prefs.getString(_storedPendingMethodKey);
      final startedAtMillis = prefs.getInt(_storedPendingStartedAtKey);
      if (purposeName == null || method == null || startedAtMillis == null) {
        return null;
      }

      OAuthCallbackPurpose? purpose;
      for (final value in OAuthCallbackPurpose.values) {
        if (value.name == purposeName) {
          purpose = value;
          break;
        }
      }
      final startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMillis);
      if (purpose == null || DateTime.now().difference(startedAt) > maxAge) {
        await _clearStoredPendingCallback();
        return null;
      }

      return _StoredOAuthPending(
        purpose: purpose,
        method: method,
        startedAt: startedAt,
      );
    } catch (error) {
      debugPrint('OAuth pending callback restore skipped: $error');
      return null;
    }
  }

  @visibleForTesting
  static void clearInMemoryPendingCallbackForTest() {
    _pendingPurpose = null;
    _pendingMethod = null;
    _pendingStartedAt = null;
  }

  @visibleForTesting
  static Future<bool> hasRecoverableNaverCalendarLinkCallbackForTest() async {
    final pending = await _resolvePendingCallback();
    return shouldTrustProviderTokenForNaverCalendarLink(
      pendingPurpose: pending?.purpose,
      pendingMethod: pending?.method,
    );
  }

  static Future<_StoredOAuthPending?> _resolvePendingCallback() async {
    final inMemoryStartedAt = _pendingStartedAt;
    if (_pendingPurpose != null &&
        _pendingMethod != null &&
        inMemoryStartedAt != null &&
        DateTime.now().difference(inMemoryStartedAt) <=
            const Duration(minutes: 10)) {
      return _StoredOAuthPending(
        purpose: _pendingPurpose!,
        method: _pendingMethod!,
        startedAt: inMemoryStartedAt,
      );
    }
    return _readStoredPendingCallback();
  }

  @visibleForTesting
  static bool shouldExchangeOAuthCallback({
    required bool currentSessionPresent,
    required bool isPasswordRecovery,
    required bool hasPendingCalendarLink,
  }) {
    if (isPasswordRecovery) {
      return true;
    }
    if (hasPendingCalendarLink) {
      return true;
    }
    return !currentSessionPresent;
  }

  void start() {
    if (kIsWeb || !AppEnv.hasValidSupabaseConfig || _subscription != null) {
      return;
    }

    debugPrint(
      'OAuth callback listener start: '
      'supabaseReady=${AppEnv.isSupabaseReady}',
    );
    unawaited(_handleInitialLinkOnce());

    _subscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('OAuth callback listener error: $error');
      },
    );
  }

  Future<void> handleAuthCallbackUri(Uri uri) {
    return _handleUri(uri);
  }

  Future<void> _handleInitialLinkOnce() async {
    if (_initialLinkHandled) {
      return;
    }
    _initialLinkHandled = true;

    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        await _handleUri(uri);
      }
    } catch (error, stackTrace) {
      debugPrint('OAuth initial callback read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _handleUri(Uri uri) async {
    if (!_isAuthCallback(uri)) {
      return;
    }

    latestUserMessage.value = null;
    final resolvedPending = await _resolvePendingCallback();
    final pendingPurpose = resolvedPending?.purpose;
    final pendingMethod = resolvedPending?.method;
    final isPendingNaverCalendarLink =
        shouldTrustProviderTokenForNaverCalendarLink(
      pendingPurpose: pendingPurpose,
      pendingMethod: pendingMethod,
    );
    final normalizedUri = _normalizeAuthCallbackUri(uri);
    final isPasswordRecovery = isPasswordRecoveryCallback(normalizedUri);
    final isEmailConfirmation = isEmailConfirmationCallback(normalizedUri) ||
        hasPendingEmailConfirmation();
    debugPrint(
      'OAuth callback observed: host=${uri.host} '
      'queryKeys=${normalizedUri.queryParameters.keys.join(',')} '
      'passwordRecovery=$isPasswordRecovery '
      'emailConfirmation=$isEmailConfirmation '
      'pendingPurpose=$pendingPurpose pendingMethod=$pendingMethod',
    );

    final callbackErrorMessage = callbackErrorMessageFor(
      normalizedUri,
      isEmailConfirmation: isEmailConfirmation,
      pendingMethod: pendingMethod,
    );
    if (callbackErrorMessage != null) {
      debugPrint(
        'OAuth callback reported error: '
        'error=${normalizedUri.queryParameters['error']} '
        'errorCode=${normalizedUri.queryParameters['error_code']} '
        'description=${normalizedUri.queryParameters['error_description']}',
      );
      clearPendingCallback();
      latestUserMessage.value = callbackErrorMessage;
      return;
    }

    final ready = await _waitForSupabaseReady();
    if (!ready) {
      debugPrint('OAuth callback skipped: Supabase was not ready in time.');
      clearPendingCallback();
      latestUserMessage.value =
          '로그인 준비가 끝나기 전에 인증 콜백을 받았습니다. 앱을 다시 열고 로그인을 다시 시도해 주세요.';
      return;
    }

    final client = Supabase.instance.client;
    final shouldExchangeCallback = shouldExchangeOAuthCallback(
      currentSessionPresent: client.auth.currentSession != null,
      isPasswordRecovery: isPasswordRecovery,
      hasPendingCalendarLink:
          pendingPurpose == OAuthCallbackPurpose.calendarLink,
    );

    debugPrint(
      'OAuth callback routing: pendingPurpose=$pendingPurpose '
      'pendingMethod=$pendingMethod '
      'currentSessionPresent=${client.auth.currentSession != null} '
      'shouldExchange=$shouldExchangeCallback',
    );
    if (pendingMethod == 'naver') {
      debugPrint(
        '[PlanFlowNaverCalendar] oauth callback routing '
        'calendarLink=${pendingPurpose == OAuthCallbackPurpose.calendarLink} '
        'currentSessionPresent=${client.auth.currentSession != null} '
        'shouldExchange=$shouldExchangeCallback',
      );
    }

    if (!shouldExchangeCallback) {
      debugPrint('OAuth callback already produced a Supabase session.');
      await _captureNaverProviderTokenIfAny(
        allowWithoutNaverIdentity: isPendingNaverCalendarLink,
      );
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        if (isEmailConfirmation) {
          await AnalyticsService.logSignUp(method: 'email');
          clearPendingCallback();
        } else {
          await _logPendingLoginIfNeeded();
        }
      } else {
        clearPendingCallback();
      }
      return;
    }

    try {
      final response = await client.auth.getSessionFromUrl(normalizedUri);
      debugPrint(
        'OAuth callback exchange completed: user=${response.session.user.id}',
      );
      if (pendingMethod == 'naver') {
        debugPrint(
          '[PlanFlowNaverCalendar] oauth callback exchange completed '
          'providerTokenPresent='
          '${response.session.providerToken?.trim().isNotEmpty == true}',
        );
      }
      await _captureNaverProviderTokenIfAny(
        explicitProviderToken: response.session.providerToken,
        allowWithoutNaverIdentity: isPendingNaverCalendarLink,
      );
      // Google 로그인 시 Google Calendar interactive sync
      final loginSession = client.auth.currentSession;
      final loginProvider =
          loginSession?.user.appMetadata['provider']?.toString() ?? '';
      if (loginProvider.contains('google')) {
        unawaited(CalendarSyncService().syncGoogleCalendar(interactive: true));
      }
      if (isPasswordRecovery) {
        authProvider.markPasswordRecovery();
        clearPendingCallback();
        appRouter.go(AppRoutes.resetPassword);
        return;
      }
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        if (isEmailConfirmation) {
          await AnalyticsService.logSignUp(method: 'email');
          clearPendingCallback();
        } else {
          await _logPendingLoginIfNeeded();
        }
      } else {
        clearPendingCallback();
      }
    } on AuthException catch (error) {
      debugPrint(
        'OAuth callback exchange failed: ${error.message} '
        'code=${error.code} status=${error.statusCode}',
      );
      clearPendingCallback();
      latestUserMessage.value = isEmailConfirmation
          ? _messageForEmailConfirmationException(error)
          : _messageForAuthException(error);
    } catch (error) {
      debugPrint('OAuth callback exchange failed: $error');
      clearPendingCallback();
      latestUserMessage.value = isEmailConfirmation
          ? '이메일 인증을 확인하지 못했습니다. 인증 링크가 만료되었거나 이미 사용되었을 수 있습니다. 로그인으로 다시 시도해 주세요.'
          : '로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.';
    }
  }

  @visibleForTesting
  static String? callbackErrorMessageFor(
    Uri uri, {
    bool isEmailConfirmation = false,
    String? pendingMethod,
  }) {
    final error = uri.queryParameters['error']?.toLowerCase().trim() ?? '';
    final errorCode =
        uri.queryParameters['error_code']?.toLowerCase().trim() ?? '';
    final description =
        uri.queryParameters['error_description']?.toLowerCase().trim() ?? '';

    if (error.isEmpty && errorCode.isEmpty && description.isEmpty) {
      return null;
    }

    final combined = '$error $errorCode $description';
    if (isEmailConfirmation) {
      if (combined.contains('otp_expired') ||
          combined.contains('expired') ||
          combined.contains('invalid')) {
        return '이메일 인증 링크가 만료되었거나 이미 사용되었습니다. 로그인으로 다시 시도하거나 회원가입 메일을 다시 받아 주세요.';
      }
      if (combined.contains('access_denied')) {
        return '이메일 인증이 완료되지 않았습니다. 메일의 인증 링크를 다시 열어 주세요.';
      }
      return '이메일 인증을 완료하지 못했습니다. 인증 링크를 다시 확인해 주세요.';
    }

    if (combined.contains('access_denied')) {
      if (pendingMethod == null || pendingMethod == 'email') {
        return '인증이 완료되지 않았습니다. 이메일 인증 링크가 맞는지 확인하고, 기존 계정이면 로그인하거나 비밀번호 찾기를 이용해 주세요.';
      }
      final method = pendingMethod == 'kakao'
          ? '카카오'
          : pendingMethod == 'naver'
              ? '네이버'
              : '소셜';
      return '$method 동의 화면에서 권한을 취소했거나 필수 동의가 완료되지 않았습니다. 다시 시도해 주세요.';
    }
    if (combined.contains('manual_linking_disabled')) {
      return 'Supabase에서 Allow manual linking을 켜야 기존 계정에 소셜 로그인을 연결할 수 있습니다.';
    }
    if (combined.contains('bad_oauth_callback') || combined.contains('state')) {
      return '인증 콜백이 올바르지 않아 로그인을 완료하지 못했습니다. Supabase Redirect URL 설정을 확인해 주세요.';
    }
    if (combined.contains('identity_already_exists')) {
      return '이 소셜 계정은 이미 다른 PlanFlow 계정에 연결되어 있습니다. 해당 계정으로 로그인하거나 기존 연결을 정리한 뒤 다시 시도해 주세요.';
    }
    if (combined.contains('provider_email_needs_verification') ||
        combined.contains('getting user email')) {
      return '소셜 로그인에서 이메일 정보를 확인하지 못했습니다. Kakao/Naver 동의항목과 Supabase provider 설정을 확인해 주세요.';
    }
    if (combined.contains('multiple accounts with the same email')) {
      return '네이버 계정 이메일이 기존 로그인 정보와 충돌합니다. '
          'Supabase SQL Editor에서 custom:naver identity를 '
          'custom:planflow-naver로 마이그레이션한 뒤 다시 시도해 주세요.';
    }

    final errDetail = [
      if (error.isNotEmpty) error,
      if (errorCode.isNotEmpty) errorCode,
      if (description.isNotEmpty) description,
    ].join(' / ');
    return '소셜 인증을 완료하지 못했습니다.'
        '${errDetail.isEmpty ? '' : ' [$errDetail]'}'
        ' Supabase와 provider 콜백 설정을 확인해 주세요.';
  }

  String _messageForEmailConfirmationException(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('expired') || message.contains('invalid')) {
      return '이메일 인증 링크가 만료되었거나 이미 사용되었습니다. 로그인으로 다시 시도하거나 회원가입 메일을 다시 받아 주세요.';
    }
    return '이메일 인증을 확인하지 못했습니다. 인증 링크를 다시 확인해 주세요.';
  }

  String _messageForAuthException(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('identity_already_exists')) {
      return '이 소셜 계정은 이미 다른 PlanFlow 계정에 연결되어 있습니다. 기존 연결을 정리하거나 같은 소셜 계정으로 로그인해 주세요.';
    }
    if (message.contains('getting user email')) {
      return '소셜 인증은 되었지만 이메일 정보를 받지 못해 로그인을 완료하지 못했습니다. Kakao/Naver 동의항목과 Supabase provider 설정을 확인해 주세요.';
    }
    if (message.contains('missing provider id') ||
        message.contains('missing_provider_id')) {
      return '네이버 인증은 됐지만 Supabase가 네이버 사용자 ID를 읽지 못했습니다. '
          'Supabase Naver provider의 Userinfo URL을 naver-userinfo-proxy Edge Function으로 바꿔 주세요.';
    }
    if (error.code == 'server_error' ||
        error.statusCode == 'unexpected_failure') {
      return '소셜 인증 처리 중 Supabase 오류가 발생했습니다. Provider 콜백과 동의항목 설정을 확인해 주세요.';
    }
    return '소셜 인증을 완료하지 못했습니다.'
        ' [${error.message}]'
        ' Supabase와 provider 콜백 설정을 확인해 주세요.';
  }

  bool _isAuthCallback(Uri uri) {
    return uri.scheme == 'planflow' && uri.host == 'auth-callback';
  }

  Uri _normalizeAuthCallbackUri(Uri uri) {
    final fragmentParameters = Uri.splitQueryString(
      uri.fragment.startsWith('#') ? uri.fragment.substring(1) : uri.fragment,
    );
    if (fragmentParameters.isEmpty) {
      return uri;
    }

    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...fragmentParameters,
      },
      fragment: '',
    );
  }

  Future<bool> _waitForSupabaseReady({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (AppEnv.isSupabaseReady) {
      return true;
    }

    final deadline = DateTime.now().add(timeout);
    while (!AppEnv.isSupabaseReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return AppEnv.isSupabaseReady;
  }

  Future<void> _captureNaverProviderTokenIfAny({
    String? explicitProviderToken,
    bool allowWithoutNaverIdentity = false,
  }) async {
    try {
      final permissionService = NaverCalendarPermissionService();
      final token = explicitProviderToken?.trim();
      if (token != null && token.isNotEmpty) {
        await permissionService.captureProviderToken(
          token,
          allowWithoutNaverIdentity: allowWithoutNaverIdentity,
        );
        return;
      }
      await permissionService.captureCurrentProviderToken(
        allowWithoutNaverIdentity: allowWithoutNaverIdentity,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver provider token capture skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @visibleForTesting
  static bool shouldTrustProviderTokenForNaverCalendarLink({
    required OAuthCallbackPurpose? pendingPurpose,
    required String? pendingMethod,
  }) {
    return pendingPurpose == OAuthCallbackPurpose.calendarLink &&
        pendingMethod == 'naver';
  }

  @visibleForTesting
  static bool isPasswordRecoveryCallback(Uri uri) {
    final parameters = <String, String>{
      ...uri.queryParameters,
      if (uri.fragment.isNotEmpty)
        ...Uri.splitQueryString(
          uri.fragment.startsWith('#')
              ? uri.fragment.substring(1)
              : uri.fragment,
        ),
    };
    final normalizedType = parameters['type']?.toLowerCase().trim();
    if (normalizedType == 'recovery') {
      return true;
    }
    final normalizedEvent = parameters['event']?.toLowerCase().trim();
    return normalizedEvent == 'password_recovery' ||
        normalizedEvent == 'passwordrecovery';
  }

  @visibleForTesting
  static bool isEmailConfirmationCallback(Uri uri) {
    final parameters = <String, String>{
      ...uri.queryParameters,
      if (uri.fragment.isNotEmpty)
        ...Uri.splitQueryString(
          uri.fragment.startsWith('#')
              ? uri.fragment.substring(1)
              : uri.fragment,
        ),
    };
    final normalizedType = parameters['type']?.toLowerCase().trim();
    final normalizedEvent = parameters['event']?.toLowerCase().trim();
    return normalizedType == 'signup' ||
        normalizedType == 'email' ||
        normalizedType == 'email_change' ||
        normalizedEvent == 'signup' ||
        normalizedEvent == 'email_confirmed' ||
        normalizedEvent == 'emailconfirmation';
  }

  Future<bool> _syncAndRouteHome() async {
    final signedIn = await authProvider.syncCurrentSession();
    if (signedIn && !authProvider.isPasswordRecovery) {
      appRouter.go(AppRoutes.home);
    }
    return signedIn;
  }

  static Future<void> _logPendingLoginIfNeeded() async {
    final method = consumePendingLoginMethod();
    if (method != null) {
      await AnalyticsService.logLogin(method: method);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

class _StoredOAuthPending {
  const _StoredOAuthPending({
    required this.purpose,
    required this.method,
    required this.startedAt,
  });

  final OAuthCallbackPurpose purpose;
  final String method;
  final DateTime startedAt;
}
