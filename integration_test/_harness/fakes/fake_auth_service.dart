import 'dart:async';
import 'dart:convert';

import 'package:planflow/services/auth_service.dart' show AuthSessionClient;
import 'package:supabase_flutter/supabase_flutter.dart';

/// [AuthSessionClient]의 결정론적 E2E fake.
///
/// 실제 seam: `lib/services/auth_service.dart:19`의 `abstract class
/// AuthSessionClient`(2곳 `@visibleForTesting` 아님 — 인터페이스 자체가
/// DI 포인트) + `lib/providers/auth_provider.dart:37`의
/// `AuthProvider({AuthSessionClient? authService, DateTime Function()?
/// clock})` 생성자. `test/providers/auth_provider_test.dart:740`의
/// `_FakeAuthService` 패턴을 재사용했다.
///
/// 실제 Supabase 네트워크 호출을 전혀 하지 않는다. 시나리오가
/// [emitSignedIn]/[emitSignedOut]으로 인증 상태 전이를 직접 제어한다.
class FakeAuthService implements AuthSessionClient {
  FakeAuthService({Session? initialSession})
      : _currentSession = initialSession;

  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();

  Session? _currentSession;

  int refreshCallCount = 0;
  int signOutCallCount = 0;
  int ensureProfileCallCount = 0;

  @override
  Session? get currentSession => _currentSession;

  @override
  User? get currentUser => _currentSession?.user;

  @override
  Stream<AuthState> get authStateChanges => _controller.stream;

  @override
  Future<void> refreshSession() async {
    refreshCallCount += 1;
  }

  @override
  Future<void> ensureProfile([User? user]) async {
    ensureProfileCallCount += 1;
  }

  @override
  Future<void> signOut() async {
    signOutCallCount += 1;
    _currentSession = null;
    _controller.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  /// 로그인 완료 시나리오를 시뮬레이션한다.
  void emitSignedIn(Session session) {
    _currentSession = session;
    _controller.add(AuthState(AuthChangeEvent.signedIn, session));
  }

  void emitSignedOut() {
    _currentSession = null;
    _controller.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  Future<void> dispose() => _controller.close();
}

/// [FakeAuthService]가 다루는 고정 형태의 [Session]/[User] 픽스처를
/// 만드는 헬퍼. `test/providers/auth_provider_test.dart`의 `_session`/
/// `_user` 빌더 패턴을 재사용했다(만료 시각을 파싱 가능한 JWT 형태로
/// 넣을 수 있게 하는 이유는 그 파일의 주석 참고).
class FixtureSession {
  FixtureSession._();

  static Session build({
    String userId = 'e2e-fixture-user',
    String? email = 'e2e@example.test',
    String provider = 'email',
    DateTime? expiresAt,
  }) {
    final user = buildUser(userId: userId, email: email, provider: provider);
    return Session(
      accessToken:
          expiresAt == null ? 'access-token' : _fakeAccessToken(expiresAt),
      refreshToken: 'refresh-token',
      tokenType: 'bearer',
      user: user,
    );
  }

  static User buildUser({
    required String userId,
    String? email,
    String provider = 'email',
    Map<String, dynamic> userMetadata = const <String, dynamic>{
      'name': 'E2E Fixture User',
    },
  }) {
    return User(
      id: userId,
      appMetadata: <String, dynamic>{'provider': provider},
      userMetadata: userMetadata,
      aud: 'authenticated',
      email: email,
      createdAt: '2026-01-01T00:00:00Z',
      role: 'authenticated',
      updatedAt: '2026-01-01T00:00:00Z',
    );
  }

  /// gotrue의 `Session.expiresAt`는 accessToken을 JWT로 파싱해 payload의
  /// `exp`(초 단위 UNIX epoch)를 읽는다. 서명 검증은 하지 않으므로 `.`으로
  /// 구분된 3파트 문자열 형태만 맞추면 만료 시각을 자유롭게 제어할 수 있다.
  static String _fakeAccessToken(DateTime expiresAt) {
    final expSeconds = expiresAt.millisecondsSinceEpoch ~/ 1000;
    final payload = base64Url.encode(
      utf8.encode(jsonEncode(<String, dynamic>{'exp': expSeconds})),
    );
    return 'header.$payload.sig';
  }
}
