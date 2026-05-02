import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../services/auth_service.dart';

final AuthProvider authProvider = AuthProvider();

class AuthProvider extends ChangeNotifier {
  AuthProvider();

  StreamSubscription<AuthState>? _subscription;
  String? _userId;
  String? _email;
  bool _isPasswordRecovery = false;
  bool _started = false;

  String? get userId => _userId;
  String? get email => _email;
  bool get isSignedIn => _userId != null;
  bool get isPasswordRecovery => _isPasswordRecovery;

  void start() {
    if (_started || !AppEnv.isSupabaseReady) {
      return;
    }
    _started = true;
    final service = AuthService();
    unawaited(_syncProfileAndApplyUser(service, service.currentUser));
    _subscription = service.authStateChanges.listen((authState) async {
      debugPrint(
        'Auth state changed: ${authState.event} '
        'user=${authState.session?.user.id ?? '<none>'}',
      );
      _isPasswordRecovery = authState.event == AuthChangeEvent.passwordRecovery;
      await _syncProfileAndApplyUser(service, authState.session?.user);
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('Auth state listener error: $error');
    });
  }

  Future<bool> syncCurrentSession({bool ensureProfile = true}) async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final service = AuthService();
    if (ensureProfile) {
      await _syncProfileAndApplyUser(service, service.currentUser);
    } else {
      _applyUser(service.currentUser);
    }
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
    notifyListeners();
  }

  Future<void> _syncProfileAndApplyUser(AuthService service, User? user) async {
    if (user == null) {
      _applyUser(null);
      return;
    }

    _applyUser(user);
    try {
      await service.ensureProfile(user);
    } catch (error) {
      debugPrint('Profile sync skipped: $error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
