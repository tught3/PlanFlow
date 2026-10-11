import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets(
      'startup resolution follows config validity and waits for auth event',
      (tester) async {
    final validConfig = AppEnv.hasValidSupabaseConfig;
    final wasReady = AppEnv.isSupabaseReady;
    final priorPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    AppEnv.markSupabaseInitialized();
    final client = _WidgetQaAuthClient();
    final provider = AuthProvider(authService: client);
    var notifications = 0;
    provider.addListener(() => notifications++);
    Timer? delayedSignIn;

    try {
      // Invalid configuration proves the unchanged production getter shortcut.
      // Valid configuration must remain unresolved before and after start.
      expect(provider.hasResolvedInitialSession, !validConfig);
      provider.start();
      await tester.pump();
      expect(provider.hasAttemptedStartupSync, isTrue);
      expect(client.listenerAttached, isTrue);

      if (!validConfig) {
        expect(provider.hasResolvedInitialSession, isTrue);
        expect(provider.sessionStatus, AuthSessionStatus.unresolved);
        expect(client.refreshCount, 0);
        // Let AuthProvider's public 2s first-event wait complete so its timer
        // is not leaked from this widget test.
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(provider.hasResolvedInitialSession, isTrue);
        expect(provider.sessionStatus, AuthSessionStatus.signedOut);
        expect(client.refreshCount, 1);
        return;
      }

      expect(provider.hasResolvedInitialSession, isFalse);
      expect(provider.sessionStatus, AuthSessionStatus.unresolved);
      delayedSignIn = Timer(
        const Duration(milliseconds: 1600),
        () => client.emitSignedIn(_session()),
      );
      await tester.pump(const Duration(milliseconds: 1300));
      expect(provider.hasResolvedInitialSession, isFalse);
      expect(provider.hasActiveSession, isFalse);
      expect(client.listenerAttached, isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(client.refreshCount, 1);
      expect(provider.hasResolvedInitialSession, isTrue);
      expect(provider.hasActiveSession, isTrue);
      expect(provider.userId, 'widget-qa-user');
      expect(notifications, greaterThan(0));
    } finally {
      delayedSignIn?.cancel();
      provider.dispose();
      await client.dispose();
      SharedPreferencesAsyncPlatform.instance = priorPreferences;
      if (!wasReady) AppEnv.resetSupabaseInitializationState();
    }
  });
}

class _WidgetQaAuthClient implements AuthSessionClient {
  final StreamController<AuthState> _events =
      StreamController<AuthState>.broadcast(sync: true);
  Session? _session;
  int refreshCount = 0;

  bool get listenerAttached => _events.hasListener;

  @override
  Session? get currentSession => _session;
  @override
  User? get currentUser => _session?.user;
  @override
  Stream<AuthState> get authStateChanges => _events.stream;
  @override
  Future<void> refreshSession() async {
    refreshCount++;
  }

  @override
  Future<void> ensureProfile([User? user]) async {}
  @override
  Future<void> signOut() async {
    _session = null;
  }

  void emitSignedIn(Session session) {
    _session = session;
    _events.add(AuthState(AuthChangeEvent.signedIn, session));
  }

  Future<void> dispose() => _events.close();
}

Session _session() {
  final user = User(
    id: 'widget-qa-user',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );
  return Session(
    accessToken: 'local-test-token',
    tokenType: 'bearer',
    user: user,
    refreshToken: 'local-test-refresh',
    expiresIn: 3600,
  );
}
