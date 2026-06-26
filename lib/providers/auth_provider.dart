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

class AuthProvider extends ChangeNotifier {
  AuthProvider({
    AuthSessionClient? authService,
  }) : _providedAuthService = authService;

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
          authState.session == null &&
          !PlanFlowAuthLocalStorage.isSessionRemovalAllowed &&
          hasAccountSnapshot) {
        debugPrint(
          'Auth signedOut recover: explicitSignOut=false hasSnapshot=true',
        );
        _setSessionStatus(AuthSessionStatus.recovering);
        unawaited(syncCurrentSession());
        return;
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
      debugPrint(
        'auth_bootstrap phase=refresh_failed '
        'hasSnapshotUser=${snapshotUser != null} '
        'errorType=${error.runtimeType}',
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
    await _syncProfileAndApplyUser(
      service,
      fallbackUser,
      sessionStatus: fallbackUser != null
          ? AuthSessionStatus.reauthRequired
          : AuthSessionStatus.signedOut,
      resolvesInitialSession: true,
    );
  }

  Future<void> _refreshSessionOnce(AuthSessionClient service) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    // 네트워크 지연 시 무한 대기 방지: 타임아웃 추가.
    // 타임아웃 발생 시 TimeoutException이 throw되어 호출부 catch 블록에서 처리됨.
    // _bootstrapInitialSession catch → _syncProfileAndApplyUser(resolvesInitialSession: true)
    // 로 이어져 hasResolvedInitialSession = true가 보장됨.
    final refresh =
        service.refreshSession().timeout(const Duration(seconds: 10));
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
