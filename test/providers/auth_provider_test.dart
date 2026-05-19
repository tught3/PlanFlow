import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUpAll(() {
    AppEnv.markSupabaseInitialized();
  });

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  test('starts with the restored session snapshot without waiting for refresh',
      () async {
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-1', email: 'user@example.com'),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.hasResolvedInitialSession, isTrue);
    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'user-1');
    expect(provider.email, 'user@example.com');
    expect(service.refreshCount, 0);

    provider.dispose();
  });

  test('keeps the existing user when refresh fails during sync', () async {
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-2', email: 'stay@example.com'),
      refreshError: const AuthException(
        'network failure',
        statusCode: '500',
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    final signedIn = await provider.syncCurrentSession();

    expect(signedIn, isTrue);
    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'user-2');
    expect(provider.email, 'stay@example.com');
    expect(service.refreshCount, 1);

    provider.dispose();
  });
}

Session _session({
  required String userId,
  required String email,
}) {
  final user = User(
    id: userId,
    appMetadata: const <String, dynamic>{'provider': 'email'},
    userMetadata: const <String, dynamic>{'name': 'Test User'},
    aud: 'authenticated',
    email: email,
    createdAt: '2026-05-19T00:00:00Z',
    role: 'authenticated',
    updatedAt: '2026-05-19T00:00:00Z',
  );

  return Session(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: user,
  );
}

class _FakeAuthService implements AuthSessionClient {
  _FakeAuthService({
    required Session? currentSession,
    this.refreshError,
  })  : _currentSession = currentSession,
        _currentUser = currentSession?.user;

  final AuthException? refreshError;
  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();
  Session? _currentSession;
  User? _currentUser;
  int refreshCount = 0;

  @override
  Session? get currentSession => _currentSession;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<AuthState> get authStateChanges => _controller.stream;

  @override
  Future<void> refreshSession() async {
    refreshCount += 1;
    if (refreshError != null) {
      throw refreshError!;
    }
  }

  @override
  Future<void> ensureProfile([User? user]) async {}

  @override
  Future<void> signOut() async {
    _currentSession = null;
    _currentUser = null;
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
