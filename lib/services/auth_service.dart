import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'oauth_callback_handler.dart';
import '../core/env.dart';
import '../core/supabase_auth_options.dart';

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
  AuthService({SupabaseClient? client, GoogleSignIn? googleSignIn})
      : _client = client ?? Supabase.instance.client,
        _googleSignIn = googleSignIn;

  final SupabaseClient _client;
  GoogleSignIn? _googleSignIn;

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

  Future<AuthResponse> signInWithGoogleNative() async {
    final serverClientId = AppEnv.googleServerClientId.trim();
    if (serverClientId.isEmpty) {
      throw AuthException(
        'Google 로그인 설정이 없습니다. Google serverClientId를 확인해 주세요.',
      );
    }

    final googleUser = await _googleSignInInstance.signIn();
    if (googleUser == null) {
      throw AuthException('Google 로그인이 취소되었습니다.');
    }

    final googleAuth = await googleUser.authentication;
    final idToken = googleAuth.idToken?.trim();
    final accessToken = googleAuth.accessToken?.trim();
    if (idToken == null || idToken.isEmpty) {
      throw AuthException('Google ID 토큰을 받지 못했습니다.');
    }
    if (accessToken == null || accessToken.isEmpty) {
      throw AuthException('Google access token을 받지 못했습니다.');
    }

    final response = await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
    unawaited(_tryEnsureProfile(response.user));
    return response;
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
    final uri = await buildOAuthSignInUri(
      provider,
      forceConsent: forceConsent,
      forCalendar: forCalendar,
    );
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    return _launchOAuthUrl(
      uri: uri,
      appProvider: provider,
      supabaseProvider: _oauthProvider(provider),
      queryParams: queryParams,
      purpose: 'sign-in',
    );
  }

  GoogleSignIn get _googleSignInInstance {
    return _googleSignIn ??= GoogleSignIn(
      serverClientId: AppEnv.googleServerClientId,
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
    final response = await _client.auth.getOAuthSignInUrl(
      provider: oauthProvider,
      redirectTo: AppEnv.authRedirectUrl,
      scopes: scopes,
      queryParams: queryParams,
    );
    return Uri.parse(response.url);
  }

  Future<bool> recheckNaverAccountConsent() {
    return signInWithOAuth(PlanFlowOAuthProvider.naver, forceConsent: true);
  }

  Future<bool> connectCalendarProvider(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    if (_client.auth.currentSession == null) {
      return signInWithOAuth(
        provider,
        forCalendar: provider == PlanFlowOAuthProvider.naver,
      );
    }

    if (provider == PlanFlowOAuthProvider.naver &&
        await _hasLinkedIdentity('naver')) {
      debugPrint(
        'OAuth calendar link fallback: provider=naver already linked, '
        'requesting fresh consent instead of identity link',
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
    } catch (error, stackTrace) {
      if (provider == PlanFlowOAuthProvider.naver &&
          _isIdentityAlreadyExistsError(error)) {
        debugPrint(
          'OAuth calendar link already exists: falling back to '
          'fresh Naver consent flow',
        );
        debugPrintStack(stackTrace: stackTrace);
        return signInWithOAuth(provider, forceConsent: true, forCalendar: true);
      }
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
      debugPrint('Naver calendar disconnect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _hasLinkedIdentity(String providerKey) async {
    try {
      final identities = await _client.auth.getUserIdentities();
      return identities.any((identity) {
        final provider = identity.provider.toLowerCase();
        return provider.contains(providerKey.toLowerCase());
      });
    } catch (error, stackTrace) {
      debugPrint('OAuth linked identity lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  bool _isIdentityAlreadyExistsError(Object error) {
    if (error is AuthException) {
      final message = error.message.toLowerCase();
      final code = error.code?.toLowerCase() ?? '';
      return message.contains('identity_already_exists') ||
          code.contains('identity_already_exists');
    }
    final text = error.toString().toLowerCase();
    return text.contains('identity_already_exists');
  }

  Future<bool> _launchOAuthUrl({
    required Uri uri,
    required PlanFlowOAuthProvider appProvider,
    required OAuthProvider supabaseProvider,
    required Map<String, String>? queryParams,
    required String purpose,
  }) async {
    final launchMode = switch (appProvider) {
      // Google OAuth는 풀 브라우저보다 커스텀 탭이 S8 같은 구형 기기에서
      // 계정 선택/리다이렉트 복귀 안정성이 더 나은 경우가 있어 우선 사용한다.
      PlanFlowOAuthProvider.google => LaunchMode.inAppBrowserView,
      PlanFlowOAuthProvider.kakao => LaunchMode.inAppBrowserView,
      PlanFlowOAuthProvider.naver => LaunchMode.inAppBrowserView,
    };
    _markPendingOAuthCallback(appProvider: appProvider, purpose: purpose);
    await OAuthCallbackHandler.persistCurrentPendingCallback();
    debugPrint(
      'OAuth launch: purpose=$purpose appProvider=$appProvider '
      'supabaseProvider=$supabaseProvider host=${uri.host} path=${uri.path} '
      'scopes=${oauthScopesFor(appProvider) ?? 'default'} '
      'queryParams=${queryParams?.keys.join(',') ?? 'none'}',
    );
    return launchUrl(
      uri,
      mode: launchMode,
      webOnlyWindowName: '_self',
    );
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
      debugPrint('Profile sync skipped: $error');
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
      PlanFlowOAuthProvider.naver => forCalendar ? 'email,calendar' : 'email',
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
