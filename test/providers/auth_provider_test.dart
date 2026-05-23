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

  test('refreshes the restored session snapshot before startup resolves',
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
    expect(service.refreshCount, 1);

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
    expect(service.refreshCount, 2);

    provider.dispose();
  });

  test('waits briefly for delayed auth recovery before showing signed out',
      () async {
    final service = _FakeAuthService(currentSession: null);
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.hasResolvedInitialSession, isFalse);
    expect(provider.isSignedIn, isFalse);

    service.emitSession(
      _session(userId: 'restored-user', email: 'restored@example.com'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(provider.hasResolvedInitialSession, isTrue);
    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'restored-user');

    provider.dispose();
    await service.dispose();
  });

  test('shows provider label when social account has no email', () async {
    final service = _FakeAuthService(
      currentSession: _session(
        userId: 'naver-user',
        email: null,
        provider: 'custom:naver',
        userMetadata: const <String, dynamic>{},
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.email, isNull);
    expect(provider.displayName, isNull);
    expect(provider.provider, 'custom:naver');
    expect(provider.providerLabel, '네이버 로그인됨');
    expect(provider.accountDisplayName, '네이버 로그인됨');
    expect(provider.socialAccountInfoIncomplete, isTrue);

    provider.dispose();
  });

  test('keeps restored startup user when refresh has a transient failure',
      () async {
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-3', email: 'keep@example.com'),
      refreshError: const AuthException(
        'temporary network failure',
        statusCode: '503',
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.hasResolvedInitialSession, isTrue);
    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'user-3');
    expect(provider.email, 'keep@example.com');
    expect(service.refreshCount, 1);

    provider.dispose();
  });

  test('uses social identity data when user email is empty', () async {
    final service = _FakeAuthService(
      currentSession: _session(
        userId: 'naver-user',
        email: null,
        provider: 'custom:naver',
        userMetadata: const <String, dynamic>{},
        identities: const <UserIdentity>[
          UserIdentity(
            id: 'identity-row',
            userId: 'naver-user',
            identityData: <String, dynamic>{
              'email': 'naver-user@example.com',
              'nickname': '네이버사용자',
            },
            identityId: 'naver-subject',
            provider: 'custom:naver',
            createdAt: '2026-05-19T00:00:00Z',
            lastSignInAt: '2026-05-19T00:00:00Z',
          ),
        ],
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.email, isNull);
    expect(provider.accountIdentifier, 'naver-user@example.com');
    expect(provider.accountDisplayName, 'naver-user@example.com');
    expect(provider.socialAccountInfoIncomplete, isFalse);

    provider.dispose();
  });

  test('uses nested Naver response email when user email is empty', () async {
    final service = _FakeAuthService(
      currentSession: _session(
        userId: 'naver-user',
        email: null,
        provider: 'custom:naver',
        userMetadata: const <String, dynamic>{},
        identities: const <UserIdentity>[
          UserIdentity(
            id: 'identity-row',
            userId: 'naver-user',
            identityData: <String, dynamic>{
              'response': <String, dynamic>{
                'email': 'nested-naver@example.com',
                'nickname': '네이버중첩사용자',
              },
            },
            identityId: 'naver-subject',
            provider: 'custom:naver',
            createdAt: '2026-05-19T00:00:00Z',
            lastSignInAt: '2026-05-19T00:00:00Z',
          ),
        ],
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.email, isNull);
    expect(provider.accountIdentifier, 'nested-naver@example.com');
    expect(provider.accountDisplayName, 'nested-naver@example.com');
    expect(provider.socialAccountInfoIncomplete, isFalse);

    provider.dispose();
  });
}

Session _session({
  required String userId,
  required String? email,
  String provider = 'email',
  Map<String, dynamic> userMetadata = const <String, dynamic>{
    'name': 'Test User',
  },
  List<UserIdentity>? identities,
}) {
  final user = User(
    id: userId,
    appMetadata: <String, dynamic>{'provider': provider},
    userMetadata: userMetadata,
    aud: 'authenticated',
    email: email,
    createdAt: '2026-05-19T00:00:00Z',
    role: 'authenticated',
    updatedAt: '2026-05-19T00:00:00Z',
    identities: identities,
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

  void emitSession(Session session) {
    _currentSession = session;
    _currentUser = session.user;
    _controller.add(
      AuthState(AuthChangeEvent.tokenRefreshed, session),
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
