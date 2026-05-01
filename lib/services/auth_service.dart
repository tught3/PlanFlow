import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/env.dart';

enum PlanFlowOAuthProvider {
  google,
  kakao,
  naver,
}

class AuthService {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  User? get currentUser => _client.auth.currentUser;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await ensureProfile(response.user);
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
      await ensureProfile(response.user);
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
    final response = await _client.auth.getOAuthSignInUrl(
      provider: oauthProvider,
      redirectTo: AppEnv.authRedirectUrl,
      scopes:
          provider == PlanFlowOAuthProvider.kakao ? 'profile_nickname' : null,
    );

    return launchUrl(
      Uri.parse(response.url),
      mode: LaunchMode.inAppBrowserView,
      webOnlyWindowName: '_self',
    );
  }

  Future<void> signOut() {
    return _client.auth.signOut();
  }

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

  OAuthProvider _oauthProvider(PlanFlowOAuthProvider provider) {
    return switch (provider) {
      PlanFlowOAuthProvider.google => OAuthProvider.google,
      PlanFlowOAuthProvider.kakao => OAuthProvider.kakao,
      PlanFlowOAuthProvider.naver => const OAuthProvider('custom:naver'),
    };
  }
}
