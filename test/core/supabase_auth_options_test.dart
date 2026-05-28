import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/supabase_auth_options.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('PlanFlowAuthLocalStorage', () {
    test('uses a stable PlanFlow session key', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final storage = PlanFlowAuthLocalStorage(
        legacyPersistSessionKey: 'sb-project-auth-token',
        secureStorage: null,
      );

      await storage.initialize();
      await storage.persistSession('session-json');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PlanFlowAuthLocalStorage.persistSessionKey),
        'session-json',
      );
      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), 'session-json');
    });

    test('migrates the legacy Supabase storage key when present', () async {
      SharedPreferences.setMockInitialValues(
        const <String, Object>{'sb-project-auth-token': 'legacy-session-json'},
      );
      final storage = PlanFlowAuthLocalStorage(
        legacyPersistSessionKey: 'sb-project-auth-token',
        secureStorage: null,
      );

      await storage.initialize();

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), 'legacy-session-json');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PlanFlowAuthLocalStorage.persistSessionKey),
        'legacy-session-json',
      );
    });

    test('does not remove persisted session without explicit sign out',
        () async {
      SharedPreferences.setMockInitialValues(
        const <String, Object>{
          PlanFlowAuthLocalStorage.persistSessionKey: 'session-json',
          'sb-project-auth-token': 'legacy-session-json',
        },
      );
      final storage = PlanFlowAuthLocalStorage(
        legacyPersistSessionKey: 'sb-project-auth-token',
        secureStorage: null,
      );

      await storage.initialize();
      await storage.removePersistedSession();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PlanFlowAuthLocalStorage.persistSessionKey),
        'session-json',
      );
      expect(prefs.getString('sb-project-auth-token'), 'legacy-session-json');
    });

    test('removes both stable and legacy session keys on explicit sign out',
        () async {
      SharedPreferences.setMockInitialValues(
        const <String, Object>{
          PlanFlowAuthLocalStorage.persistSessionKey: 'session-json',
          'sb-project-auth-token': 'legacy-session-json',
        },
      );
      final storage = PlanFlowAuthLocalStorage(
        legacyPersistSessionKey: 'sb-project-auth-token',
        secureStorage: null,
      );

      await storage.initialize();
      await PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
        storage.removePersistedSession,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(PlanFlowAuthLocalStorage.persistSessionKey),
        isFalse,
      );
      expect(prefs.containsKey('sb-project-auth-token'), isFalse);
    });

    test('mirrors secure session backup into shared preferences', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final secureStorage = _FakeSecureStorage(
        initialValues: const <String, String>{
          'planflow_supabase_auth_session_v1': 'secure-session-json',
        },
      );
      final storage = PlanFlowAuthLocalStorage(
        legacyPersistSessionKey: 'sb-project-auth-token',
        secureStorage: secureStorage,
      );

      await storage.initialize();

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), 'secure-session-json');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PlanFlowAuthLocalStorage.persistSessionKey),
        'secure-session-json',
      );
    });

    test(
        'auth options install stable local storage and keep app link handling off',
        () {
      final options = buildPlanFlowAuthOptions(
        supabaseUrl: 'https://project.supabase.co',
      );

      expect(options.detectSessionInUri, isFalse);
      expect(options.localStorage, isA<PlanFlowAuthLocalStorage>());
      expect(
          options.pkceAsyncStorage, isA<SharedPreferencesGotrueAsyncStorage>());
    });
  });
}

class _FakeSecureStorage implements FlutterSecureStorage {
  _FakeSecureStorage({Map<String, String> initialValues = const {}})
      : _values = Map<String, String>.from(initialValues);

  final Map<String, String> _values;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
