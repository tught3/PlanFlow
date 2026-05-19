import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/env.dart';

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

  final SupabaseClient _client;

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

  Future<bool> signInWithOAuth(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    return _launchOAuthUrl(
      appProvider: provider,
      supabaseProvider: oauthProvider,
      urlFactory: () => _client.auth.getOAuthSignInUrl(
        provider: oauthProvider,
        redirectTo: AppEnv.authRedirectUrl,
      ),
      purpose: 'sign-in',
    );
  }

  Future<bool> connectCalendarProvider(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    if (_client.auth.currentSession == null) {
      return signInWithOAuth(provider);
    }

    return _launchOAuthUrl(
      appProvider: provider,
      supabaseProvider: oauthProvider,
      urlFactory: () => _client.auth.getLinkIdentityUrl(
        oauthProvider,
        redirectTo: AppEnv.authRedirectUrl,
      ),
      purpose: 'calendar-link',
    );
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

  Future<bool> _launchOAuthUrl({
    required PlanFlowOAuthProvider appProvider,
    required OAuthProvider supabaseProvider,
    required Future<OAuthResponse> Function() urlFactory,
    required String purpose,
  }) async {
    final launchMode =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? LaunchMode.externalApplication
            : LaunchMode.inAppBrowserView;
    final response = await urlFactory();
    final uri = Uri.parse(response.url);
    debugPrint(
      'OAuth launch: purpose=$purpose appProvider=$appProvider '
      'supabaseProvider=${response.provider} host=${uri.host} path=${uri.path}',
    );
    return launchUrl(
      uri,
      mode: launchMode,
      webOnlyWindowName: '_self',
    );
  }

  @override
  Future<void> signOut() {
    return _client.auth.signOut();
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
      PlanFlowOAuthProvider.naver => const OAuthProvider('custom:naver'),
    };
  }
}
