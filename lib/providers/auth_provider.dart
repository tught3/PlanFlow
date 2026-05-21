import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../services/auth_service.dart';
import '../services/naver_calendar_permission_service.dart';

final AuthProvider authProvider = AuthProvider();

class AuthProvider extends ChangeNotifier {
  AuthProvider({
    AuthSessionClient? authService,
  }) : _providedAuthService = authService;

  StreamSubscription<AuthState>? _subscription;
  final AuthSessionClient? _providedAuthService;
  AuthSessionClient? _authService;
  Completer<AuthState>? _firstAuthEventCompleter;
  String? _userId;
  String? _email;
  String? _displayName;
  String? _provider;
  bool _isPasswordRecovery = false;
  bool _started = false;
  bool _hasResolvedInitialSession = false;

  String? get userId => _userId;
  String? get email => _email;
  String? get displayName => _displayName;
  String? get provider => _provider;
  String get providerLabel {
    return switch (_provider?.toLowerCase()) {
      'google' => 'Google 로그인됨',
      'kakao' => '카카오 로그인됨',
      'naver' || 'custom:naver' => '네이버 로그인됨',
      'email' => '이메일 로그인됨',
      _ => '로그인됨',
    };
  }

  bool get isSignedIn => _userId != null;
  bool get isPasswordRecovery => _isPasswordRecovery;
  bool get hasResolvedInitialSession =>
      !AppEnv.isSupabaseReady || _hasResolvedInitialSession;

  AuthSessionClient get _service =>
      _authService ??= _providedAuthService ?? AuthService();

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    if (!AppEnv.isSupabaseReady) {
      _hasResolvedInitialSession = true;
      notifyListeners();
      return;
    }
    final service = _service;
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
      await _syncProfileAndApplyUser(service, authState.session?.user);
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('Auth state listener error: $error');
    });
    unawaited(_bootstrapInitialSession());
  }

  Future<bool> syncCurrentSession() async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final service = _service;
    final snapshotUser = service.currentSession?.user ?? service.currentUser;
    final hadSignedInUser = isSignedIn;
    unawaited(
      NaverCalendarPermissionService().captureCurrentProviderToken(),
    );
    try {
      await service.refreshSession();
    } catch (error) {
      debugPrint('Session refresh skipped: $error');
      if (snapshotUser != null) {
        await _syncProfileAndApplyUser(
          service,
          snapshotUser,
          resolvesInitialSession: true,
        );
        return true;
      }
      if (hadSignedInUser) {
        _markInitialSessionResolved();
        return true;
      }
    }
    await _syncProfileAndApplyUser(
      service,
      service.currentSession?.user ?? service.currentUser ?? snapshotUser,
      resolvesInitialSession: true,
    );
    return isSignedIn;
  }

  void setUser(String? userId) {
    _userId = userId;
    notifyListeners();
  }

  void clearPasswordRecovery() {
    if (!_isPasswordRecovery) {
      return;
    }
    _isPasswordRecovery = false;
    notifyListeners();
  }

  void _applyUser(User? user) {
    _userId = user?.id;
    _email = user?.email;
    _displayName = _displayNameFrom(user);
    _provider = _providerFrom(user);
    notifyListeners();
  }

  String? _displayNameFrom(User? user) {
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    for (final key in const ['name', 'full_name', 'user_name', 'nickname']) {
      final value = metadata[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
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
    return null;
  }

  void _markInitialSessionResolved() {
    if (_hasResolvedInitialSession) {
      return;
    }
    _hasResolvedInitialSession = true;
    notifyListeners();
  }

  Future<void> _syncProfileAndApplyUser(
    AuthSessionClient service,
    User? user, {
    bool resolvesInitialSession = false,
  }) async {
    if (user == null) {
      _applyUser(null);
      if (resolvesInitialSession) {
        _markInitialSessionResolved();
      }
      return;
    }

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
    final snapshotUser = service.currentSession?.user ?? service.currentUser;
    if (snapshotUser == null) {
      try {
        await _firstAuthEventCompleter?.future.timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {}
    }
    await _syncProfileAndApplyUser(
      service,
      service.currentSession?.user ?? service.currentUser ?? snapshotUser,
      resolvesInitialSession: true,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
