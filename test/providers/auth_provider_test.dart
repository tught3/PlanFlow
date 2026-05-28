import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/supabase_auth_options.dart';
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

  test('shares an in-flight refresh between bootstrap and sync calls',
      () async {
    final refreshGate = Completer<void>();
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-4', email: 'once@example.com'),
      refreshCompleter: refreshGate,
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await service.firstRefreshStarted.future;
    final signedInFuture = provider.syncCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(service.refreshCount, 1);

    refreshGate.complete();
    final signedIn = await signedInFuture;
    await Future<void>.delayed(Duration.zero);

    expect(signedIn, isTrue);
    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'user-4');
    expect(service.refreshCount, 1);

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

  test('ignores non-explicit signed out event while a user is active',
      () async {
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-5', email: 'keep@example.com'),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.isSignedIn, isTrue);

    service.emitSignedOut();
    await Future<void>.delayed(Duration.zero);

    expect(provider.isSignedIn, isTrue);
    expect(provider.userId, 'user-5');

    provider.dispose();
    await service.dispose();
  });

  test('applies signed out event during explicit sign out', () async {
    final service = _FakeAuthService(
      currentSession: _session(userId: 'user-6', email: 'out@example.com'),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.isSignedIn, isTrue);

    await PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(() async {
      service.emitSignedOut();
      await Future<void>.delayed(Duration.zero);
    });

    expect(provider.isSignedIn, isFalse);
    expect(provider.userId, isNull);

    provider.dispose();
    await service.dispose();
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

    expect(provider.email, 'naver-user@example.com');
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

    expect(provider.email, 'nested-naver@example.com');
    expect(provider.accountIdentifier, 'nested-naver@example.com');
    expect(provider.accountDisplayName, 'nested-naver@example.com');
    expect(provider.socialAccountInfoIncomplete, isFalse);

    provider.dispose();
  });

  test('uses social user metadata email when user email is empty', () async {
    final service = _FakeAuthService(
      currentSession: _session(
        userId: 'naver-user',
        email: null,
        provider: 'custom:naver',
        userMetadata: const <String, dynamic>{
          'email': 'metadata-naver@example.com',
          'name': '네이버사용자',
        },
      ),
    );
    final provider = AuthProvider(authService: service);

    provider.start();
    await Future<void>.delayed(Duration.zero);

    expect(provider.email, 'metadata-naver@example.com');
    expect(provider.accountDisplayName, 'metadata-naver@example.com');
    expect(provider.socialAccountInfoIncomplete, isFalse);

    provider.dispose();
  });

  test('prefers deep nested identity email over identity display name',
      () async {
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
              'profile': <String, dynamic>{
                'name': '네이버사용자',
                'user': <String, dynamic>{
                  'email': 'deep-naver@example.com',
                },
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

    expect(provider.email, 'deep-naver@example.com');
    expect(provider.accountDisplayName, 'deep-naver@example.com');
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
    this.refreshCompleter,
  })  : _currentSession = currentSession,
        _currentUser = currentSession?.user;

  final AuthException? refreshError;
  final Completer<void>? refreshCompleter;
  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();
  Session? _currentSession;
  User? _currentUser;
  int refreshCount = 0;
  final Completer<void> firstRefreshStarted = Completer<void>();

  @override
  Session? get currentSession => _currentSession;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<AuthState> get authStateChanges => _controller.stream;

  @override
  Future<void> refreshSession() async {
    refreshCount += 1;
    if (!firstRefreshStarted.isCompleted) {
      firstRefreshStarted.complete();
    }
    await refreshCompleter?.future;
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

  void emitSignedOut() {
    _currentSession = null;
    _currentUser = null;
    _controller.add(
      const AuthState(AuthChangeEvent.signedOut, null),
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
