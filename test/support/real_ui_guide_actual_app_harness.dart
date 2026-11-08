// Host-only QA. HTTP overrides do not fence files or direct sockets.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';

class RealUiGuideActualAppHarness {
  final requests = <String>[];
  final nativeCalls = <String>[];
  final denied = <String>[];
  final backend = _Backend();
  final progress = _Progress();
  HttpOverrides? _priorHttp;
  SharedPreferencesAsyncPlatform? _priorPrefs;
  http.Client? _http;
  bool _installed = false;
  static const channels = <String>[
    'com.llfbandit.app_links/messages',
    'dev.fluttercommunity.plus/app_links/messages',
    'es.antonborri.home_widget',
    'es.antonborri.home_widget/channel',
    'receive_sharing_intent/messages',
    'dexterous.com/flutter/local_notifications',
    'plugin.flutter.io/speech_to_text',
    'plugins.builttoroam.com/device_calendar',
    'plugins.flutter.io/device_calendar',
    'plugins.it_nomads.com/flutter_secure_storage',
    'planflow/alarm_service',
  ];
  Future<void> install() async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    if (binding.runtimeType != AutomatedTestWidgetsFlutterBinding) {
      throw StateError('Only automated host widget binding authorized');
    }
    if (!const bool.fromEnvironment('PLANFLOW_GUIDE_QA')) {
      throw StateError('Explicit PLANFLOW_GUIDE_QA=true required');
    }
    if (AppEnv.isSupabaseReady) throw StateError('Existing app environment');
    var exists = false;
    try {
      Supabase.instance;
      exists = true;
    } on AssertionError {/* uninitialized */}
    if (exists) throw StateError('Existing Supabase singleton');
    _priorHttp = HttpOverrides.current;
    _priorPrefs = SharedPreferencesAsyncPlatform.instance;
    HttpOverrides.global = _DenyHttp(denied);
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) {
      // Unknown channels have the host binding's null handler, never a device.
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        nativeCalls.add('$name/${call.method}');
        throw PlatformException(code: 'qa-denied', message: name);
      });
    }
    _http = MockClient((request) async {
      final entry = '${request.method} ${request.url}';
      requests.add(entry);
      final u = request.url;
      if (u.host == 'planflow-actual-mount.invalid' &&
          request.method == 'GET' &&
          u.path.startsWith('/rest/v1/') &&
          const [
            'users',
            'events',
            'user_settings',
            'groups',
            'group_members',
            'group_events'
          ].contains(u.pathSegments.last)) {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      // Deny all writes, auth, AI, quota, RPC and unknown endpoints. Never forward.
      denied.add(entry);
      return http.Response('{"message":"host QA denied"}', 403,
          headers: {'content-type': 'application/json'}, request: request);
    });
    await Supabase.initialize(
        url: 'https://planflow-actual-mount.invalid',
        anonKey: 'local-noncredential-qa',
        httpClient: _http,
        debug: false,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage()));
    _installed = true;
    AppEnv.markSupabaseInitialized();
    final expiry =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
            1000;
    final payload = base64Url
        .encode(utf8.encode(jsonEncode({'exp': expiry})))
        .replaceAll('=', '');
    // Local future-expiring fixture, no remote sign-in or refresh.
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': 'eyJhbGciOiJub25lIn0.$payload.qa',
      'refresh_token': 'qa-local',
      'token_type': 'bearer',
      'expires_in': 86400,
      'expires_at': expiry,
      'user': {
        'id': '00000000-0000-4000-8000-000000000001',
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'qa@example.invalid',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    authProvider.start();
  }

  void assertReady() {
    if (!_installed ||
        HttpOverrides.current is! _DenyHttp ||
        TestWidgetsFlutterBinding.instance.runtimeType !=
            AutomatedTestWidgetsFlutterBinding ||
        !authProvider.isSignedIn ||
        !authProvider.hasResolvedInitialSession) {
      throw StateError(
          'Auth/backend/events/HTTP/native fences not ready; do not pump');
    }
  }

  Widget buildApp() {
    assertReady();
    return ProviderScope(overrides: [
      realUiGuideBackendProvider.overrideWithValue(backend),
      realUiGuideProgressStoreProvider.overrideWithValue(progress),
      // Retain the ACTUAL default coordinator.
    ], child: PlanFlowApp.forGuideQa());
  }

  Future<void> dispose() async {
    if (_installed) {
      authProvider.dispose();
      await Supabase.instance.dispose();
      AppEnv.resetSupabaseInitializationState();
      _installed = false;
    }
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    _http?.close();
    HttpOverrides.global = _priorHttp;
    if (_priorPrefs != null) {
      SharedPreferencesAsyncPlatform.instance = _priorPrefs!;
    }
  }
}

class _DenyHttp extends HttpOverrides {
  _DenyHttp(this.denied);
  final List<String> denied;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _HostHttpClient(denied);
}

class _Progress implements GuideProgressStore {
  final values = <String, GuideSnapshot>{};
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      values['$uid/$version'];
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    values['${snapshot.uid}/${snapshot.version}'] = snapshot;
  }
}

class _Backend implements GuideBackendPort {
  int begins = 0;
  int advances = 0;
  int authorizations = 0;
  int finishes = 0;
  final exits = <GuideExit>[];
  @override
  Future<GuideBackendState?> begin(
      {required String uid,
      required String version,
      required String requestId}) async {
    begins++;
    return const GuideBackendState(
        sessionId: 'host-qa', serverRevision: 1, step: GuideStep.intro);
  }

  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) {
    advances++;
    throw StateError('Intro/home coachmark QA must not advance backend');
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    authorizations++;
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {
    finishes++;
    exits.add(exit);
  }
}

// Allow harmless client construction, but no actual HTTP operation.
class _HostHttpClient implements HttpClient {
  _HostHttpClient(this.denied);
  final List<String> denied;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.isSetter) return null;
    denied.add('dart:io HTTP: ${call.memberName}');
    throw const SocketException('Host QA denies dart:io HTTP operation');
  }
}
