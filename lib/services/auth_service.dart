import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/diag_logger.dart';
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
  static const String _diagAuthTag = 'NAVER_AUTH';
  static const String _diagTokenTag = 'NAVER_TOKEN';

  final SupabaseClient _client;

  static void _logNaverCalendarAuth(String message) {
    debugPrint('[$_naverCalendarLogTag] auth ${logSafeText(message)}');
  }

  static void _diagAuth(String message) {
    DiagLogger.log(_diagAuthTag, logSafeText(message));
  }

  static void _diagToken(String message) {
    DiagLogger.log(_diagTokenTag, logSafeText(message));
  }

  static String _tokenDiagnostic(String? token) {
    return DiagLogger.describeToken(token);
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
    final effectiveForCalendar =
        provider == PlanFlowOAuthProvider.naver ? false : forCalendar;
    if (provider == PlanFlowOAuthProvider.naver) {
      _diagAuth(
        'signInWithOAuth start provider=naver forCalendar=$effectiveForCalendar '
        'forceConsent=$forceConsent '
        'sessionPresent=${_client.auth.currentSession != null} '
        'userPresent=${_client.auth.currentUser != null}',
      );
      _diagToken(
        'signInWithOAuth currentSessionProvider '
        '${_tokenDiagnostic(_client.auth.currentSession?.providerToken)}',
      );
      _diagAuth(
        'providerToken present='
        '${_client.auth.currentSession?.providerToken?.isNotEmpty == true}',
      );
      _logNaverCalendarAuth(
        'signInWithOAuth start forCalendar=$effectiveForCalendar '
        'forceConsent=$forceConsent '
        'sessionPresent=${_client.auth.currentSession != null}',
      );
    }
    final uri = await buildOAuthSignInUri(
      provider,
      forceConsent: forceConsent,
      forCalendar: effectiveForCalendar,
    );
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    if (provider == PlanFlowOAuthProvider.naver) {
      _diagAuth(
        'signInWithOAuth urlBuilt provider=naver host=${uri.host} '
        'path=${uri.path} queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=${oauthScopesFor(provider, forCalendar: effectiveForCalendar) ?? 'default'}',
      );
      _logNaverCalendarAuth(
        'signInWithOAuth built uri host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=${oauthScopesFor(provider, forCalendar: effectiveForCalendar) ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    return _launchOAuthUrl(
      uri: uri,
      appProvider: provider,
      supabaseProvider: _oauthProvider(provider),
      queryParams: queryParams,
      purpose: effectiveForCalendar ? 'calendar-link' : 'sign-in',
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
      _diagAuth(
        'buildOAuthSignInUri request provider=naver '
        'forCalendar=$forCalendar forceConsent=$forceConsent '
        'scopes=${scopes ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
      _logNaverCalendarAuth(
        'buildOAuthSignInUri request forCalendar=$forCalendar '
        'forceConsent=$forceConsent scopes=${scopes ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    try {
      final response = await _client.auth.getOAuthSignInUrl(
        provider: oauthProvider,
        redirectTo: AppEnv.authRedirectUrl,
        scopes: scopes,
        queryParams: queryParams,
      );
      return Uri.parse(response.url);
    } catch (error) {
      if (provider == PlanFlowOAuthProvider.naver) {
        _diagAuth(
          'buildOAuthSignInUri exception type=${error.runtimeType} '
          'error=${logSafeText(error)}',
        );
      }
      rethrow;
    }
  }

  Future<bool> recheckNaverAccountConsent() {
    return signInWithOAuth(
      PlanFlowOAuthProvider.naver,
      forceConsent: true,
    );
  }

  Future<bool> connectCalendarProvider(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    if (provider == PlanFlowOAuthProvider.naver) {
      _diagAuth(
        'connectCalendarProvider start provider=naver '
        'sessionPresent=${_client.auth.currentSession != null} '
        'userPresent=${_client.auth.currentUser != null}',
      );
      _diagToken(
        'connectCalendarProvider currentSessionProvider '
        '${_tokenDiagnostic(_client.auth.currentSession?.providerToken)}',
      );
      _diagAuth(
        'providerToken present='
        '${_client.auth.currentSession?.providerToken?.isNotEmpty == true}',
      );
      _logNaverCalendarAuth(
        'connectCalendarProvider start sessionPresent=${_client.auth.currentSession != null} '
        'currentUserPresent=${_client.auth.currentUser != null}',
      );
    }
    if (_client.auth.currentSession == null) {
      if (provider == PlanFlowOAuthProvider.naver) {
        _logNaverCalendarAuth(
          'connectCalendarProvider naver unsupported: CalDAV is required',
        );
        return false;
      }
      return signInWithOAuth(
        provider,
        forCalendar: true,
      );
    }

    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'connectCalendarProvider naver unsupported: CalDAV is required',
      );
      return false;
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
      if (provider == PlanFlowOAuthProvider.naver) {
        _diagAuth('connectCalendarProvider exception type=unknown');
      }
      rethrow;
    }
  }

  Future<bool> reconnectNaverCalendar() {
    return Future<bool>.value(false);
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
    final launchMode = switch (appProvider) {
      PlanFlowOAuthProvider.google => LaunchMode.externalApplication,
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
      _diagAuth(
        'launchOAuthUrl start purpose=$purpose provider=naver '
        'mode=$launchMode host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=$effectiveScopes '
        'sessionPresent=${_client.auth.currentSession != null} '
        'userPresent=${_client.auth.currentUser != null}',
      );
      _logNaverCalendarAuth(
        'launchOAuthUrl purpose=$purpose mode=$launchMode '
        'host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=$effectiveScopes '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    _markPendingOAuthCallback(appProvider: appProvider, purpose: purpose);
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _diagAuth('launchOAuthUrl pendingMarked purpose=$purpose provider=naver');
    }
    await OAuthCallbackHandler.persistCurrentPendingCallback();
    final bool launched;
    try {
      launched = await launchUrl(
        uri,
        mode: launchMode,
        webOnlyWindowName: '_self',
      );
    } catch (error) {
      if (appProvider == PlanFlowOAuthProvider.naver) {
        _diagAuth(
          'launchOAuthUrl exception type=${error.runtimeType} '
          'error=${logSafeText(error)}',
        );
      }
      rethrow;
    }
    if (!launched) {
      if (appProvider == PlanFlowOAuthProvider.naver) {
        _diagAuth('launchOAuthUrl failed launched=false provider=naver');
        _logNaverCalendarAuth('launchOAuthUrl failed launched=false');
      }
      OAuthCallbackHandler.clearPendingCallback();
    }
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _diagAuth('launchOAuthUrl result launched=$launched provider=naver');
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
