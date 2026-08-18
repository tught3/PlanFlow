import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../core/supabase_auth_options.dart';
import '../services/auth_service.dart';
import '../services/naver_calendar_permission_service.dart';

final AuthProvider authProvider = AuthProvider();

enum AuthSessionStatus {
  unresolved,
  recovering,
  active,
  reauthRequired,
  signedOut,
}

/// `refreshSession()` 호출이 gotrue rate limit(429) 쿨다운 때문에 생략됐음을
/// 알리는 전용 예외.
///
/// 쿨다운 중에 정상 반환하면 호출부가 `currentSession == null`을 보고 세션을
/// reauthRequired로 강등해 오히려 로그인 팝업을 유발하므로, 반드시 예외로
/// 알려 [AuthProvider._isTransientRefreshFailure]가 일시적 실패로 분류하게 한다.
class AuthRefreshCooldownException implements Exception {
  const AuthRefreshCooldownException(this.retryAt);

  /// 이 시각 이후에 다시 네트워크 갱신을 시도할 수 있다.
  final DateTime retryAt;

  @override
  String toString() => 'AuthRefreshCooldownException(retryAt: $retryAt)';
}

class AuthProvider extends ChangeNotifier {
  AuthProvider({
    AuthSessionClient? authService,
    DateTime Function()? clock,
  })  : _providedAuthService = authService,
        _clock = clock ?? DateTime.now;

  /// 세션 잔여 수명이 이 값을 초과하면 네트워크 갱신을 생략한다.
  /// gotrue가 자체 자동갱신 타이머(10초 주기, 만료 30초 전 갱신)를 이미
  /// 돌리고 있으므로 앱 레벨 수동 갱신은 이 구간에서 잉여 호출이다.
  static const Duration refreshSkipRemainingLifetime = Duration(minutes: 5);

  /// 세션 만료 시각을 알 수 없을 때(JWT 파싱 불가 등) 적용하는 최소 갱신 간격.
  static const Duration refreshMinInterval = Duration(seconds: 60);

  /// 429(rate limit)를 맞은 뒤 네트워크 갱신을 완전히 멈추는 기간.
  static const Duration refreshRateLimitCooldown = Duration(seconds: 60);

  final DateTime Function() _clock;
  DateTime? _lastSuccessfulRefreshAt;
  DateTime? _rateLimitedUntil;

  StreamSubscription<AuthState>? _subscription;
  final AuthSessionClient? _providedAuthService;
  AuthSessionClient? _authService;
  Completer<AuthState>? _firstAuthEventCompleter;
  Completer<void>? _initialSessionResolvedCompleter;
  String? _userId;
  String? _email;
  String? _displayName;
  String? _provider;
  String? _accountIdentifier;
  bool _socialAccountInfoIncomplete = false;
  bool _isPasswordRecovery = false;
  bool _started = false;
  bool _hasResolvedInitialSession = false;
  Future<void>? _refreshInFlight;
  AuthSessionStatus _sessionStatus = AuthSessionStatus.unresolved;
  // syncCurrentSession() 최초 호출 여부 추적.
  // false 동안은 signedOut 상태에서도 라우터가 로그인 화면 리다이렉트를 보류한다.
  bool _hasAttemptedStartupSync = false;

  String? get userId => _userId;
  String? get email => _email;
  String? get displayName => _displayName;
  String? get provider => _provider;
  String? get accountIdentifier => _accountIdentifier;
  AuthSessionStatus get sessionStatus => _sessionStatus;
  bool get hasAccountSnapshot => _userId != null;
  bool get hasAttemptedStartupSync => _hasAttemptedStartupSync;
  bool get hasActiveSession =>
      _sessionStatus == AuthSessionStatus.active && _userId != null;
  bool get needsReauthentication =>
      _sessionStatus == AuthSessionStatus.reauthRequired;
  bool get socialAccountInfoIncomplete => _socialAccountInfoIncomplete;
  bool get isNaverAccount => _providerKey == 'naver';
  bool get isGoogleAccount => _providerKey == 'google';
  String get accountDisplayName =>
      _email ?? _displayName ?? _accountIdentifier ?? providerLabel;
  String get providerLabel {
    return switch (_providerKey) {
      'google' => 'Google 로그인됨',
      'kakao' => '카카오 로그인됨',
      'naver' => '네이버 로그인됨',
      'email' => '이메일 로그인됨',
      _ => '로그인됨',
    };
  }

  /// 설정 화면에서 이메일 옆 괄호로 보여줄 "무엇으로 로그인했는지" 라벨.
  /// 연결(linking) 계정은 primary provider 기준이라 단일 provider 사용자에 정확하다.
  String? get loginMethodLabel {
    return switch (_providerKey) {
      'google' => '구글 간편로그인',
      'kakao' => '카카오 간편로그인',
      'naver' => '네이버 간편로그인',
      'email' => '이메일 로그인',
      _ => null,
    };
  }

  /// 계정 식별자(이메일/이름)가 있을 때만 "식별자 (로그인 방식)" 형태로 조합한다.
  /// 식별자가 없어 providerLabel로 대체되는 경우엔 중복을 피해 라벨만 보여준다.
  String get accountDisplayWithMethod {
    final method = loginMethodLabel;
    final hasIdentifier =
        _email != null || _displayName != null || _accountIdentifier != null;
    if (method == null || !hasIdentifier) {
      return accountDisplayName;
    }
    return '$accountDisplayName ($method)';
  }

  bool get isSignedIn => hasActiveSession;
  bool get isPasswordRecovery => _isPasswordRecovery;
  bool get hasResolvedInitialSession {
    if (!AppEnv.hasValidSupabaseConfig) {
      return true;
    }
    if (!AppEnv.isSupabaseReady && !_started) {
      return false;
    }
    return _hasResolvedInitialSession;
  }

  AuthSessionClient get _service =>
      _authService ??= _providedAuthService ?? AuthService();

  Future<bool> waitForInitialSessionResolution({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (hasResolvedInitialSession) {
      return true;
    }
    final completer = _initialSessionResolvedCompleter;
    if (completer == null) {
      return hasResolvedInitialSession;
    }
    try {
      await completer.future.timeout(timeout);
    } catch (e) { debugPrint('AuthProvider 세션 대기 타임아웃 무시: $e'); }
    return hasResolvedInitialSession;
  }

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    if (!AppEnv.isSupabaseReady) {
      _hasAttemptedStartupSync = true;
      _initialSessionResolvedCompleter ??= Completer<void>();
      _completeInitialSessionResolution();
      _setSessionStatus(AuthSessionStatus.signedOut, notify: false);
      _hasResolvedInitialSession = true;
      notifyListeners();
      return;
    }
    final service = _service;
    _initialSessionResolvedCompleter ??= Completer<void>();
    _firstAuthEventCompleter = Completer<AuthState>();
    _subscription = service.authStateChanges.listen((authState) async {
      final firstAuthEventCompleter = _firstAuthEventCompleter;
      if (firstAuthEventCompleter != null &&
          !firstAuthEventCompleter.isCompleted) {
        firstAuthEventCompleter.complete(authState);
      }
      debugPrint(
        'Auth state changed: ${authState.event} '
        'user=${authState.session?.user.id ?? '<none>'}',
      );
      _isPasswordRecovery = authState.event == AuthChangeEvent.passwordRecovery;
      if (authState.session != null) {
        unawaited(
          NaverCalendarPermissionService().captureCurrentProviderToken(),
        );
      }
      if (authState.event == AuthChangeEvent.signedOut &&
          authState.session == null) {
        if (PlanFlowAuthLocalStorage.isExplicitSignOutInProgress) {
          // 사용자 주도 로그아웃은 권위적으로 처리한다: 복구하지 않고 아래 공통 경로로 떨어져
          // _applyUser(null) + signedOut을 적용해 스냅샷(provider/email)을 확정 초기화한다.
          PlanFlowAuthLocalStorage.endExplicitSignOut();
        } else if (!PlanFlowAuthLocalStorage.isSessionRemovalAllowed &&
            hasAccountSnapshot) {
          debugPrint(
            'Auth signedOut recover: explicitSignOut=false hasSnapshot=true',
          );
          _setSessionStatus(AuthSessionStatus.recovering);
          unawaited(syncCurrentSession());
          return;
        }
      }
      await _syncProfileAndApplyUser(
        service,
        authState.session?.user,
        sessionStatus: authState.session != null
            ? AuthSessionStatus.active
            : AuthSessionStatus.signedOut,
      );
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('Auth state listener error: $error');
    });
    unawaited(_bootstrapInitialSession());
  }

  Future<bool> syncCurrentSession() async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    // 최초 호출 시 플래그 설정 (notify 없이 — 직후 recovering 상태 전환이 notify함)
    if (!_hasAttemptedStartupSync) {
      _hasAttemptedStartupSync = true;
    }
    final service = _service;
    final inFlightRefresh = _refreshInFlight;
    if (inFlightRefresh != null) {
      await inFlightRefresh;
      final inFlightSession = service.currentSession;
      final inFlightUser = inFlightSession?.user ?? service.currentUser;
      if (inFlightUser != null) {
        await _syncProfileAndApplyUser(
          service,
          inFlightUser,
          sessionStatus: inFlightSession != null
              ? AuthSessionStatus.active
              : AuthSessionStatus.reauthRequired,
          resolvesInitialSession: true,
        );
        return inFlightSession != null;
      }
    }
    if (!_hasResolvedInitialSession) {
      final resolved = await waitForInitialSessionResolution();
      final bootstrapSession = service.currentSession;
      final bootstrapUser = bootstrapSession?.user ?? service.currentUser;
      if (bootstrapUser != null) {
        await _syncProfileAndApplyUser(
          service,
          bootstrapUser,
          sessionStatus: bootstrapSession != null
              ? AuthSessionStatus.active
              : AuthSessionStatus.reauthRequired,
          resolvesInitialSession: true,
        );
        return bootstrapSession != null;
      }
      if (!resolved) {
        debugPrint('Session refresh deferred: initial auth unresolved');
      }
      await _syncProfileAndApplyUser(
        service,
        null,
        sessionStatus: AuthSessionStatus.signedOut,
        resolvesInitialSession: true,
      );
      return false;
    }
    final snapshotSession = service.currentSession;
    final snapshotUser = snapshotSession?.user ?? service.currentUser;
    final hadAccountSnapshot = hasAccountSnapshot;
    _setSessionStatus(AuthSessionStatus.recovering);
    unawaited(
      NaverCalendarPermissionService().captureCurrentProviderToken(),
    );
    try {
      await _refreshSessionOnce(service);
    } catch (error) {
      debugPrint('Session refresh skipped: $error');
      if (snapshotSession != null && snapshotUser != null) {
        await _syncProfileAndApplyUser(
          service,
          snapshotUser,
          sessionStatus: AuthSessionStatus.active,
          resolvesInitialSession: true,
        );
        return true;
      }
      final fallbackUser = snapshotUser;
      if (fallbackUser != null) {
        await _syncProfileAndApplyUser(
          service,
          fallbackUser,
          sessionStatus: AuthSessionStatus.reauthRequired,
          resolvesInitialSession: true,
        );
        return false;
      }
      if (hadAccountSnapshot) {
        _markReauthRequired(resolvesInitialSession: true);
        return false;
      }
    }
    final activeUser = service.currentSession?.user;
    if (activeUser != null) {
      await _syncProfileAndApplyUser(
        service,
        activeUser,
        sessionStatus: AuthSessionStatus.active,
        resolvesInitialSession: true,
      );
      return true;
    }
    final fallbackUser = service.currentUser ?? snapshotUser;
    if (fallbackUser != null) {
      await _syncProfileAndApplyUser(
        service,
        fallbackUser,
        sessionStatus: AuthSessionStatus.reauthRequired,
        resolvesInitialSession: true,
      );
      return false;
    }
    if (hadAccountSnapshot) {
      _markReauthRequired(resolvesInitialSession: true);
      return false;
    }
    await _syncProfileAndApplyUser(
      service,
      null,
      sessionStatus: AuthSessionStatus.signedOut,
      resolvesInitialSession: true,
    );
    return false;
  }

  void setUser(String? userId) {
    _userId = userId;
    _setSessionStatus(
      userId == null ? AuthSessionStatus.signedOut : AuthSessionStatus.active,
      notify: false,
    );
    notifyListeners();
  }

  void clearPasswordRecovery() {
    if (!_isPasswordRecovery) {
      return;
    }
    _isPasswordRecovery = false;
    notifyListeners();
  }

  void markPasswordRecovery() {
    if (_isPasswordRecovery) {
      return;
    }
    _isPasswordRecovery = true;
    notifyListeners();
  }

  void _applyUser(User? user) {
    // 로그아웃 확정(user == null) 또는 다른 계정의 새 세션 적용 시 스로틀 상태를
    // 초기화한다. 이전 계정의 타임스탬프가 새 세션 판정에 새어들면 안 된다.
    if (user == null || user.id != _userId) {
      _lastSuccessfulRefreshAt = null;
      _rateLimitedUntil = null;
    }
    _userId = user?.id;
    _email = _emailFrom(user);
    _displayName = _displayNameFrom(user);
    _provider = _providerFrom(user);
    _accountIdentifier = _accountIdentifierFrom(user);
    _socialAccountInfoIncomplete = _isSocialAccountInfoIncomplete(user);
    _logSocialAccountDiagnostics(user);
    notifyListeners();
  }

  void _setSessionStatus(
    AuthSessionStatus status, {
    bool notify = true,
  }) {
    if (_sessionStatus == status) {
      return;
    }
    _sessionStatus = status;
    if (notify) {
      notifyListeners();
    }
  }

  void _markReauthRequired({bool resolvesInitialSession = false}) {
    _setSessionStatus(AuthSessionStatus.reauthRequired, notify: false);
    if (resolvesInitialSession) {
      _hasResolvedInitialSession = true;
    }
    notifyListeners();
  }

  String? _emailFrom(User? user) {
    final directEmail = user?.email?.trim();
    if (directEmail != null && directEmail.isNotEmpty) {
      return directEmail;
    }
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final metadataEmail = _firstStringValue(metadata, const ['email']);
    if (metadataEmail != null) {
      return metadataEmail;
    }
    for (final identity in user?.identities ?? const <UserIdentity>[]) {
      final data = identity.identityData ?? const <String, dynamic>{};
      final identityEmail = _firstStringValue(data, const ['email']);
      if (identityEmail != null) {
        return identityEmail;
      }
    }
    return null;
  }

  String? _displayNameFrom(User? user) {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    return _firstStringValue(
      metadata,
      const ['name', 'full_name', 'user_name', 'nickname'],
    );
  }

  String? _providerFrom(User? user) {
    final metadata = user?.appMetadata ?? const <String, dynamic>{};
    final provider = metadata['provider']?.toString().trim();
    if (provider != null && provider.isNotEmpty) {
      return provider;
    }
    final providers = metadata['providers'];
    if (providers is Iterable && providers.isNotEmpty) {
      final first = providers.first.toString().trim();
      if (first.isNotEmpty) {
        return first;
      }
    }
    final identities = user?.identities ?? const <UserIdentity>[];
    for (final identity in identities) {
      final provider = identity.provider.trim();
      if (provider.isNotEmpty) {
        return provider;
      }
    }
    return null;
  }

  String get _providerKey {
    final provider = _provider?.toLowerCase().trim();
    if (provider == null || provider.isEmpty) {
      return '';
    }
    if (provider.contains('naver')) {
      return 'naver';
    }
    return provider;
  }

  String? _accountIdentifierFrom(User? user) {
    if (user == null) {
      return null;
    }
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final resolvedEmail = _emailFrom(user);
    if (resolvedEmail != null) {
      return resolvedEmail;
    }
    final metadataIdentifier = _firstStringValue(
      metadata,
      const ['name', 'full_name', 'user_name', 'nickname'],
    );
    if (metadataIdentifier != null) {
      return metadataIdentifier;
    }
    for (final identity in user.identities ?? const <UserIdentity>[]) {
      final data = identity.identityData ?? const <String, dynamic>{};
      final identityIdentifier = _firstStringValue(
        data,
        const ['email', 'name', 'nickname', 'sub', 'id'],
      );
      if (identityIdentifier != null) {
        return identityIdentifier;
      }
      final identityId = identity.identityId.trim();
      if (identityId.isNotEmpty) {
        return identity.provider.toLowerCase().contains('naver')
            ? '네이버 ID $identityId'
            : identityId;
      }
    }
    return null;
  }

  bool _isSocialAccountInfoIncomplete(User? user) {
    if (user == null) {
      return false;
    }
    final provider = _providerKey;
    if (provider != 'naver' && provider != 'kakao' && provider != 'google') {
      return false;
    }
    return (user.email == null || user.email!.trim().isEmpty) &&
        (_displayName == null || _displayName!.trim().isEmpty) &&
        (_accountIdentifier == null || _accountIdentifier!.trim().isEmpty);
  }

  String? _firstStringValue(
    Map<String, dynamic> data,
    List<String> preferredKeys,
  ) {
    for (final key in preferredKeys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    for (final nestedKey in const ['response', 'profile', 'user']) {
      final nested = data[nestedKey];
      if (nested is Map) {
        final nestedData = Map<String, dynamic>.from(nested);
        final value = _firstStringValue(nestedData, preferredKeys);
        if (value != null) {
          return value;
        }
      }
    }

    return null;
  }

  void _logSocialAccountDiagnostics(User? user) {
    if (user == null) {
      return;
    }
    final provider = _providerKey;
    if (provider != 'naver' && provider != 'kakao' && provider != 'google') {
      return;
    }
    final identities = user.identities ?? const <UserIdentity>[];
    final hasIdentityEmail = identities.any((identity) {
      final data = identity.identityData ?? const <String, dynamic>{};
      return _firstStringValue(data, const ['email']) != null;
    });
    debugPrint(
      'Social auth profile: provider=$provider '
      'hasEmail=${user.email?.trim().isNotEmpty == true} '
      'metadataKeys=${user.userMetadata?.keys.join(',') ?? 'none'} '
      'appMetadataKeys=${user.appMetadata.keys.join(',')} '
      'identityCount=${identities.length} '
      'identityProviders=${identities.map((e) => e.provider).join(',')} '
      'hasIdentityEmail=$hasIdentityEmail '
      'incomplete=$_socialAccountInfoIncomplete',
    );
  }

  void _markInitialSessionResolved() {
    if (_hasResolvedInitialSession) {
      return;
    }
    _hasResolvedInitialSession = true;
    _completeInitialSessionResolution();
    notifyListeners();
  }

  void _completeInitialSessionResolution() {
    final completer = _initialSessionResolvedCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete();
  }

  Future<void> _syncProfileAndApplyUser(
    AuthSessionClient service,
    User? user, {
    required AuthSessionStatus sessionStatus,
    bool resolvesInitialSession = false,
  }) async {
    if (user == null) {
      _setSessionStatus(sessionStatus, notify: false);
      _applyUser(null);
      if (resolvesInitialSession) {
        _markInitialSessionResolved();
      }
      return;
    }

    _setSessionStatus(sessionStatus, notify: false);
    _applyUser(user);
    try {
      await service.ensureProfile(user);
    } catch (error) {
      debugPrint('Profile sync skipped: $error');
    } finally {
      if (resolvesInitialSession) {
        _markInitialSessionResolved();
      }
    }
  }

  Future<void> _bootstrapInitialSession() async {
    final service = _service;
    _hasAttemptedStartupSync = true;
    var snapshotUser = service.currentSession?.user ?? service.currentUser;
    if (snapshotUser == null) {
      try {
        await _firstAuthEventCompleter?.future.timeout(
          const Duration(seconds: 2),
        );
      } catch (e) { debugPrint('AuthProvider 세션 대기 타임아웃 무시: $e'); }
      snapshotUser = service.currentSession?.user ?? service.currentUser;
    }

    var refreshFailedTransiently = false;
    try {
      debugPrint(
        'auth_bootstrap phase=refresh_start '
        'hasSnapshotUser=${snapshotUser != null}',
      );
      await _refreshSessionOnce(service);
      debugPrint(
        'auth_bootstrap phase=refresh_success '
        'hasSession=${service.currentSession != null}',
      );
    } catch (error) {
      refreshFailedTransiently = _isTransientRefreshFailure(error);
      debugPrint(
        'auth_bootstrap phase=refresh_failed '
        'hasSnapshotUser=${snapshotUser != null} '
        'errorType=${error.runtimeType} '
        'transient=$refreshFailedTransiently',
      );
    }
    final activeUser = service.currentSession?.user;
    if (activeUser != null) {
      await _syncProfileAndApplyUser(
        service,
        activeUser,
        sessionStatus: AuthSessionStatus.active,
        resolvesInitialSession: true,
      );
      return;
    }
    final fallbackUser = service.currentUser ?? snapshotUser;
    // 네트워크/타임아웃 등 일시적 갱신 실패는 syncCurrentSession()의 방어 로직
    // (249-257줄 부근)과 동일하게 캐시된 사용자를 만료로 강등하지 않는다.
    // 진짜 인증 실패(401/invalid refresh token 등)만 reauthRequired로 분류한다.
    if (refreshFailedTransiently && fallbackUser != null) {
      await _syncProfileAndApplyUser(
        service,
        fallbackUser,
        sessionStatus: AuthSessionStatus.active,
        resolvesInitialSession: true,
      );
      return;
    }
    await _syncProfileAndApplyUser(
      service,
      fallbackUser,
      sessionStatus: fallbackUser != null
          ? AuthSessionStatus.reauthRequired
          : AuthSessionStatus.signedOut,
      resolvesInitialSession: true,
    );
  }

  /// 세션 갱신 실패가 "진짜 만료"가 아니라 네트워크/타임아웃 같은 일시적
  /// 실패인지 판정한다. gotrue의 `_callRefreshToken`은
  /// [AuthRetryableFetchException]일 때만 세션을 보존하고 그 외
  /// [AuthException](예: 401 invalid refresh token)에는 세션을 제거하므로,
  /// 그 구분을 그대로 따른다. 우리 쪽 10초 타임아웃(`_refreshSessionOnce`)이
  /// 던지는 [TimeoutException]도 같은 일시적 실패로 취급한다.
  ///
  /// 이 함수의 실제 소비 지점은 [_bootstrapInitialSession] 한 곳뿐이며,
  /// [syncCurrentSession]은 이미 별도의 스냅샷 보존 로직(에러 타입 무관하게
  /// snapshotSession이 있으면 active 유지)을 갖고 있어 이 함수를 쓰지 않는다.
  bool _isTransientRefreshFailure(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    if (error is AuthRetryableFetchException) {
      return true;
    }
    if (error is AuthRefreshCooldownException) {
      return true;
    }
    // 429는 gotrue가 세션을 지워버리는 원인일 뿐 "진짜 만료"가 아니다.
    if (_isRateLimitError(error)) {
      return true;
    }
    return false;
  }

  /// 이미 충분히 유효한 세션에 대한 네트워크 갱신을 생략할지 판정한다.
  ///
  /// `refreshSession()`은 만료 여부와 무관하게 호출마다 네트워크 요청을 보내는데,
  /// 앱 안에 이 호출로 이어지는 지점이 여러 곳이라 화면 전환/앱 재개가 겹치면
  /// gotrue의 rate limit(429)을 맞고, gotrue는 429를 재시도불가 실패로 보고
  /// 로컬 세션을 즉시 제거한다(= 사용자가 보는 "세션 만료" 팝업).
  /// gotrue 자체 자동갱신 타이머가 만료 직전 갱신을 이미 담당하므로 생략은 안전하다.
  bool _shouldSkipNetworkRefresh(Session? session, DateTime now) {
    if (session == null) {
      return false;
    }
    final expiresAtSeconds = session.expiresAt;
    if (expiresAtSeconds != null) {
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        expiresAtSeconds * 1000,
      );
      return expiresAt.difference(now) > refreshSkipRemainingLifetime;
    }
    final lastRefreshedAt = _lastSuccessfulRefreshAt;
    if (lastRefreshedAt != null &&
        now.difference(lastRefreshedAt) < refreshMinInterval) {
      return true;
    }
    return false;
  }

  /// gotrue rate limit(429) 판정. [_refreshSessionOnce]의 쿨다운 설정과
  /// [_isTransientRefreshFailure]의 분류가 같은 조건을 쓰도록 한 곳에 모은다.
  bool _isRateLimitError(Object error) {
    if (error is! AuthException) {
      return false;
    }
    return error.statusCode == '429' || error.code == 'over_request_rate_limit';
  }

  Future<void> _refreshSessionOnce(AuthSessionClient service) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final now = _clock();
    final rateLimitedUntil = _rateLimitedUntil;
    if (rateLimitedUntil != null) {
      if (now.isBefore(rateLimitedUntil)) {
        // 쿨다운 중에는 네트워크를 아예 건드리지 않는다. 정상 반환하면
        // 호출부가 세션 없음으로 오판하므로 일시적 실패로 알린다.
        return Future<void>.error(
          AuthRefreshCooldownException(rateLimitedUntil),
          StackTrace.current,
        );
      }
      _rateLimitedUntil = null;
    }

    if (_shouldSkipNetworkRefresh(service.currentSession, now)) {
      // 현재 세션을 그대로 쓰는 정상 흐름. throw하면 downstream이 세션없음으로
      // 오판할 수 있으므로 성공으로 반환한다.
      return Future<void>.value();
    }

    // 네트워크 지연 시 무한 대기 방지: 타임아웃 추가.
    // 타임아웃 발생 시 TimeoutException이 throw되어 호출부 catch 블록에서 처리됨.
    // _bootstrapInitialSession catch → _syncProfileAndApplyUser(resolvesInitialSession: true)
    // 로 이어져 hasResolvedInitialSession = true가 보장됨.
    final refresh = service
        .refreshSession()
        .timeout(const Duration(seconds: 10))
        .then<void>(
      (_) {
        // 성공한 갱신만 스로틀 키로 기록한다(실패를 기록하면 재시도가 막힌다).
        _lastSuccessfulRefreshAt = _clock();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_isRateLimitError(error)) {
          _rateLimitedUntil = _clock().add(refreshRateLimitCooldown);
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _refreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshInFlight, refresh)) {
        _refreshInFlight = null;
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
