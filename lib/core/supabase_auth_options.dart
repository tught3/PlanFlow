import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlanFlowAuthLocalStorage extends LocalStorage {
  PlanFlowAuthLocalStorage({
    required this.legacyPersistSessionKey,
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        resetOnError: false,
      ),
    ),
  })  : _preferencesOverride = preferences,
        _secureStorage = secureStorage;

  static const persistSessionKey = 'planflow:supabase_auth_session:v1';
  static const _secureSessionKey = 'planflow_supabase_auth_session_v1';
  static bool _allowSessionRemoval = false;

  final String? legacyPersistSessionKey;
  final SharedPreferences? _preferencesOverride;
  final FlutterSecureStorage? _secureStorage;

  late SharedPreferences _preferences;
  bool _initialized = false;

  static bool get isSessionRemovalAllowed => _allowSessionRemoval;

  static Future<T> runWithSessionRemovalAllowed<T>(
    Future<T> Function() action,
  ) async {
    final previous = _allowSessionRemoval;
    _allowSessionRemoval = true;
    try {
      return await action();
    } finally {
      _allowSessionRemoval = previous;
    }
  }

  static String legacyKeyForSupabaseUrl(String supabaseUrl) {
    final host = Uri.parse(supabaseUrl).host;
    final projectRef = host.split('.').first;
    return 'sb-$projectRef-auth-token';
  }

  @override
  Future<void> initialize() async {
    _preferences =
        _preferencesOverride ?? await SharedPreferences.getInstance();
    _initialized = true;
  }

  @override
  Future<bool> hasAccessToken() async {
    await _ensureInitialized();
    if (_readSharedSession() != null) {
      return true;
    }
    final secureSession = await _readSecureSession();
    return secureSession != null && secureSession.trim().isNotEmpty;
  }

  @override
  Future<String?> accessToken() async {
    await _ensureInitialized();
    final sharedSession = _readSharedSession();
    if (sharedSession != null) {
      await _mirrorToPrimaryStores(sharedSession);
      return sharedSession;
    }

    final secureSession = await _readSecureSession();
    if (secureSession != null && secureSession.trim().isNotEmpty) {
      await _mirrorToPrimaryStores(secureSession);
      return secureSession;
    }
    return null;
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    await _ensureInitialized();
    await _preferences.setString(persistSessionKey, persistSessionString);
    await _writeSecureSession(persistSessionString);
  }

  @override
  Future<void> removePersistedSession() async {
    await _ensureInitialized();
    if (!_allowSessionRemoval) {
      debugPrint(
        'PlanFlow auth session removal suppressed: explicitSignOut=false',
      );
      return;
    }
    debugPrint('PlanFlow auth session removal allowed: explicitSignOut=true');
    await _preferences.remove(persistSessionKey);
    final legacyKey = legacyPersistSessionKey;
    if (legacyKey != null && legacyKey.isNotEmpty) {
      await _preferences.remove(legacyKey);
    }
    await _deleteSecureSession();
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  String? _readSharedSession() {
    final primarySession = _preferences.getString(persistSessionKey);
    if (primarySession != null && primarySession.trim().isNotEmpty) {
      return primarySession;
    }

    final legacyKey = legacyPersistSessionKey;
    if (legacyKey == null || legacyKey.isEmpty) {
      return null;
    }
    final legacySession = _preferences.getString(legacyKey);
    if (legacySession != null && legacySession.trim().isNotEmpty) {
      return legacySession;
    }
    return null;
  }

  Future<void> _mirrorToPrimaryStores(String session) async {
    await _preferences.setString(persistSessionKey, session);
    await _writeSecureSession(session);
  }

  Future<String?> _readSecureSession() async {
    try {
      return await _secureStorage?.read(key: _secureSessionKey);
    } catch (error) {
      debugPrint('PlanFlow auth secure session read skipped: $error');
      return null;
    }
  }

  Future<void> _writeSecureSession(String session) async {
    try {
      await _secureStorage?.write(key: _secureSessionKey, value: session);
    } catch (error) {
      debugPrint('PlanFlow auth secure session backup skipped: $error');
    }
  }

  Future<void> _deleteSecureSession() async {
    try {
      await _secureStorage?.delete(key: _secureSessionKey);
    } catch (error) {
      debugPrint('PlanFlow auth secure session cleanup skipped: $error');
    }
  }
}

FlutterAuthClientOptions buildPlanFlowAuthOptions({
  required String supabaseUrl,
  bool detectSessionInUri = false,
}) {
  return FlutterAuthClientOptions(
    detectSessionInUri: detectSessionInUri,
    localStorage: PlanFlowAuthLocalStorage(
      legacyPersistSessionKey:
          PlanFlowAuthLocalStorage.legacyKeyForSupabaseUrl(supabaseUrl),
    ),
    pkceAsyncStorage: SharedPreferencesGotrueAsyncStorage(),
  );
}
