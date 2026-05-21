import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/supabase_auth_options.dart';
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

    test('removes both stable and legacy session keys on sign out', () async {
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
        prefs.containsKey(PlanFlowAuthLocalStorage.persistSessionKey),
        isFalse,
      );
      expect(prefs.containsKey('sb-project-auth-token'), isFalse);
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
