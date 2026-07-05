import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/env.dart';
import '../core/log_text.dart';
import '../core/supabase_auth_options.dart';
import 'oauth_callback_handler.dart';

enum PlanFlowOAuthProvider {
  google,
  kakao,
  naver,
}

abstract class AuthSessionClient {
  Session? get currentSession;
  User? get currentUser;
  Stream<AuthState> get authStateChanges;
  Future<void> refreshSession();
  Future<void> ensureProfile([User? user]);
  Future<void> signOut();
}

class AuthService implements AuthSessionClient {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _naverCalendarLogTag = 'PlanFlowNaverCalendar';

  final SupabaseClient _client;

  static void _logNaverCalendarAuth(String message) {
    debugPrint('[$_naverCalendarLogTag] auth ${logSafeText(message)}');
  }

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  User? get currentUser => _client.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<void> refreshSession() async {
    await _client.auth.refreshSession();
  }

  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    unawaited(_tryEnsureProfile(response.user));
    return response;
  }

  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    final response = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: AppEnv.authRedirectUrl,
      data: <String, dynamic>{
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
    if (response.session != null) {
      unawaited(_tryEnsureProfile(response.user));
    }
    return response;
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: AppEnv.authRedirectUrl,
    );
  }

  Future<void> updatePassword(String password) async {
    await _client.auth.updateUser(
      UserAttributes(password: password),
    );
  }

  Future<bool> signInWithOAuth(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
    bool forCalendar = false,
  }) async {
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'signInWithOAuth start forCalendar=$forCalendar '
        'forceConsent=$forceConsent '
        'sessionPresent=${_client.auth.currentSession != null}',
      );
    }
    final uri = await buildOAuthSignInUri(
      provider,
      forceConsent: forceConsent,
      forCalendar: forCalendar,
    );
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'signInWithOAuth built uri host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=${oauthScopesFor(provider, forCalendar: forCalendar) ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    return _launchOAuthUrl(
      uri: uri,
      appProvider: provider,
      supabaseProvider: _oauthProvider(provider),
      queryParams: queryParams,
      purpose: forCalendar ? 'calendar-link' : 'sign-in',
    );
  }

  Future<Uri> buildOAuthSignInUri(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
    bool forCalendar = false,
  }) async {
    final oauthProvider = _oauthProvider(provider);
    final scopes = oauthScopesFor(provider, forCalendar: forCalendar);
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'buildOAuthSignInUri request forCalendar=$forCalendar '
        'forceConsent=$forceConsent scopes=${scopes ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    final response = await _client.auth.getOAuthSignInUrl(
      provider: oauthProvider,
      redirectTo: AppEnv.authRedirectUrl,
      scopes: scopes,
      queryParams: queryParams,
    );
    return Uri.parse(response.url);
  }

  Future<bool> recheckNaverAccountConsent() {
    return signInWithOAuth(
      PlanFlowOAuthProvider.naver,
      forceConsent: true,
      forCalendar: true,
    );
  }

  Future<bool> connectCalendarProvider(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'connectCalendarProvider start sessionPresent=${_client.auth.currentSession != null} '
        'currentUserPresent=${_client.auth.currentUser != null}',
      );
    }
    if (_client.auth.currentSession == null) {
      if (provider == PlanFlowOAuthProvider.naver) {
        _logNaverCalendarAuth(
          'connectCalendarProvider no Supabase session -> signInWithOAuth for calendar',
        );
      }
      return signInWithOAuth(
        provider,
        forCalendar: provider == PlanFlowOAuthProvider.naver,
      );
    }

    // Naver 캘린더: getLinkIdentityUrl은 provider_token을 콜백 URL에 포함하지 않음.
    // full OAuth(signInWithOAuth)만 provider_token을 제공하므로 항상 이 경로 사용.
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'connectCalendarProvider naver -> signInWithOAuth forceConsent=true forCalendar=true',
      );
      return signInWithOAuth(provider, forceConsent: true, forCalendar: true);
    }

    final queryParams = oauthQueryParamsFor(provider);
    try {
      final response = await _client.auth.getLinkIdentityUrl(
        oauthProvider,
        redirectTo: AppEnv.authRedirectUrl,
        scopes: oauthScopesFor(provider, forCalendar: true),
        queryParams: queryParams,
      );
      return _launchOAuthUrl(
        uri: Uri.parse(response.url),
        appProvider: provider,
        supabaseProvider: oauthProvider,
        queryParams: queryParams,
        purpose: 'calendar-link',
      );
    } catch (_) {
      rethrow;
    }
  }

  Future<bool> reconnectNaverCalendar() {
    return connectCalendarProvider(PlanFlowOAuthProvider.naver);
  }

  Future<bool> disconnectNaverCalendar() async {
    final currentUser = _client.auth.currentUser;
    if (currentUser == null) {
      return false;
    }

    try {
      final identities = await _client.auth.getUserIdentities();
      UserIdentity? naverIdentity;
      for (final identity in identities) {
        final provider = identity.provider.toLowerCase();
        if (provider.contains('naver')) {
          naverIdentity = identity;
          break;
        }
      }

      if (naverIdentity == null) {
        return false;
      }

      await _client.auth.unlinkIdentity(naverIdentity);
      return true;
    } catch (error, stackTrace) {
      debugPrint('Naver calendar disconnect failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _launchOAuthUrl({
    required Uri uri,
    required PlanFlowOAuthProvider appProvider,
    required OAuthProvider supabaseProvider,
    required Map<String, String>? queryParams,
    required String purpose,
  }) async {
    // externalApplication(구글)은 별도 Chrome 태스크를 띄우는데, 리다이렉트로
    // 앱이 포그라운드로 돌아온 뒤에도 그 Chrome 태스크가 백그라운드에 남아있어
    // 앱 루트에서 뒤로가기를 누르면 홈 화면 대신 그 방치된 Chrome 화면이
    // 드러나는 문제가 있었다. Custom Tab(inAppBrowserView)은 앱과 같은
    // 태스크 안에 머물러 이 문제가 없고, Google의 WebView 로그인 차단 정책도
    // Custom Tab은 허용 대상이라 카카오/네이버와 동일하게 통일한다.
    final launchMode = switch (appProvider) {
      PlanFlowOAuthProvider.google => LaunchMode.inAppBrowserView,
      PlanFlowOAuthProvider.kakao => LaunchMode.inAppBrowserView,
      PlanFlowOAuthProvider.naver => LaunchMode.inAppBrowserView,
    };
    final forCalendar = purpose == 'calendar-link';
    final effectiveScopes =
        oauthScopesFor(appProvider, forCalendar: forCalendar) ?? 'default';
    debugPrint(
      'OAuth launch: purpose=$purpose appProvider=$appProvider '
      'supabaseProvider=$supabaseProvider host=${uri.host} path=${uri.path} '
      'scopes=$effectiveScopes '
      'queryParams=${queryParams?.keys.join(',') ?? 'none'}',
    );
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'launchOAuthUrl purpose=$purpose mode=$launchMode '
        'host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=$effectiveScopes '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    _markPendingOAuthCallback(appProvider: appProvider, purpose: purpose);
    await OAuthCallbackHandler.persistCurrentPendingCallback();
    final launched = await launchUrl(
      uri,
      mode: launchMode,
      webOnlyWindowName: '_self',
    );
    if (!launched) {
      if (appProvider == PlanFlowOAuthProvider.naver) {
        _logNaverCalendarAuth('launchOAuthUrl failed launched=false');
      }
      OAuthCallbackHandler.clearPendingCallback();
    }
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth('launchOAuthUrl result launched=$launched');
    }
    return launched;
  }

  void _markPendingOAuthCallback({
    required PlanFlowOAuthProvider appProvider,
    required String purpose,
  }) {
    switch (purpose) {
      case 'calendar-link':
        OAuthCallbackHandler.markPendingCalendarLink(appProvider);
        break;
      case 'sign-in':
        OAuthCallbackHandler.markPendingLogin(appProvider);
        break;
    }
  }

  @override
  Future<void> signOut() {
    return PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
      _client.auth.signOut,
    );
  }

  @override
  Future<void> ensureProfile([User? user]) async {
    final resolvedUser = user ?? currentUser;
    if (resolvedUser == null || _client.auth.currentSession == null) {
      return;
    }

    final metadata = resolvedUser.userMetadata ?? const <String, dynamic>{};
    final displayName = metadata['name'] ??
        metadata['full_name'] ??
        metadata['user_name'] ??
        metadata['nickname'];

    await _client.from('users').upsert(
      <String, dynamic>{
        'id': resolvedUser.id,
        'email': resolvedUser.email,
        if (displayName != null && displayName.toString().trim().isNotEmpty)
          'name': displayName.toString().trim(),
      },
      onConflict: 'id',
    );
  }

  Future<void> _tryEnsureProfile([User? user]) async {
    try {
      await ensureProfile(user);
    } catch (error) {
      debugPrint('Profile sync skipped: ${logSafeText(error)}');
    }
  }

  OAuthProvider _oauthProvider(PlanFlowOAuthProvider provider) {
    return switch (provider) {
      PlanFlowOAuthProvider.google => OAuthProvider.google,
      PlanFlowOAuthProvider.kakao => OAuthProvider.kakao,
      PlanFlowOAuthProvider.naver =>
        const OAuthProvider('custom:planflow-naver'),
    };
  }

  @visibleForTesting
  static String? oauthScopesFor(
    PlanFlowOAuthProvider provider, {
    // forCalendar=true: connectCalendarProvider 경로에서만 사용.
    // 로그인 흐름에는 기본 email scope만 요청.
    bool forCalendar = false,
  }) {
    return switch (provider) {
      PlanFlowOAuthProvider.google => null,
      // Kakao returns KOE205 when the app asks for consent items that are not
      // enabled in Kakao Developers. Keep login on profile-only scopes; email
      // can be added later only after the Kakao consent item is approved.
      PlanFlowOAuthProvider.kakao => 'openid,profile_nickname,profile_image',
      // Login uses the base email scope. Calendar connection still requests
      // calendar consent, and the settings flow falls back to CalDAV if launch
      // or permission verification does not complete.
      PlanFlowOAuthProvider.naver when forCalendar => 'email,calendar',
      PlanFlowOAuthProvider.naver => 'email',
    };
  }

  @visibleForTesting
  static Map<String, String>? oauthQueryParamsFor(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
  }) {
    if (provider == PlanFlowOAuthProvider.naver && forceConsent) {
      return const <String, String>{'auth_type': 'reprompt'};
    }
    return null;
  }
}
