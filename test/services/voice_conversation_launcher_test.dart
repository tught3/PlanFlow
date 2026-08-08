import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';
import 'package:planflow/services/voice_conversation_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  tearDown(() {
    VoiceConversationAdGate.instance.delegateForTest = null;
  });

  group('resolveAutoStart', () {
    test('Supabase 미준비 상태에서는 false로 폴백한다', () async {
      AppEnv.resetSupabaseInitializationState();

      final result = await VoiceConversationLauncher.resolveAutoStart(
        'user-1',
        repository: const _FakeSettingsRepository(voiceAutoStart: true),
      );

      expect(result, isFalse);
    });

    test('userId가 null이면 false로 폴백한다', () async {
      AppEnv.markSupabaseInitialized();

      final result = await VoiceConversationLauncher.resolveAutoStart(
        null,
        repository: const _FakeSettingsRepository(voiceAutoStart: true),
      );

      expect(result, isFalse);
    });

    test('userId가 빈 문자열이면 false로 폴백한다', () async {
      AppEnv.markSupabaseInitialized();

      final result = await VoiceConversationLauncher.resolveAutoStart(
        '   ',
        repository: const _FakeSettingsRepository(voiceAutoStart: true),
      );

      expect(result, isFalse);
    });

    test('repository가 예외를 던지면 false로 폴백한다', () async {
      AppEnv.markSupabaseInitialized();
      final repository = _ThrowingSettingsRepository();

      final result = await VoiceConversationLauncher.resolveAutoStart(
        'user-1',
        repository: repository,
      );

      expect(result, isFalse);
      expect(
        repository.callCount,
        1,
        reason: 'Supabase가 준비된 상태라면 repository가 실제로 호출돼야 한다'
            '(Supabase 미준비로 조기 반환된 것과 구분).',
      );
    });

    test('repository가 voiceAutoStart 값을 그대로 반환한다', () async {
      AppEnv.markSupabaseInitialized();

      final result = await VoiceConversationLauncher.resolveAutoStart(
        'user-1',
        repository: const _FakeSettingsRepository(voiceAutoStart: true),
      );

      expect(result, isTrue);
    });
  });

  group('open', () {
    testWidgets('autoStart=true이면 대화모드 라우트에 autoStart=1 쿼리가 붙는다', (
      tester,
    ) async {
      AppEnv.markSupabaseInitialized();
      VoiceConversationAdGate.instance.delegateForTest =
          const _AllowAllVoiceConversationAdGateDelegate();

      String? capturedLocation;
      final router = GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => VoiceConversationLauncher.open(
                    context,
                    userIdOverride: 'user-1',
                    repository: const _FakeSettingsRepository(
                      voiceAutoStart: true,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) {
              capturedLocation = state.uri.toString();
              return const Text('대화모드 화면', textDirection: TextDirection.ltr);
            },
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(theme: buildPlanFlowTheme(), routerConfig: router),
      );
      await tester.pump();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(capturedLocation, isNotNull);
      expect(capturedLocation, contains('autoStart=1'));
      expect(find.text('대화모드 화면'), findsOneWidget);
    });

    testWidgets('autoStart=false이면 쿼리 없이 대화모드 라우트로 push한다', (tester) async {
      AppEnv.markSupabaseInitialized();
      VoiceConversationAdGate.instance.delegateForTest =
          const _AllowAllVoiceConversationAdGateDelegate();

      String? capturedLocation;
      final router = GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => VoiceConversationLauncher.open(
                    context,
                    userIdOverride: 'user-1',
                    repository: const _FakeSettingsRepository(
                      voiceAutoStart: false,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) {
              capturedLocation = state.uri.toString();
              return const Text('대화모드 화면', textDirection: TextDirection.ltr);
            },
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(theme: buildPlanFlowTheme(), routerConfig: router),
      );
      await tester.pump();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(capturedLocation, isNotNull);
      expect(capturedLocation, isNot(contains('autoStart=1')));
      expect(find.text('대화모드 화면'), findsOneWidget);
    });
  });
}

/// voiceAutoStart 회귀 테스트용 fake. Supabase 호출 없이 고정 설정값을
/// 반환한다.
class _FakeSettingsRepository extends SettingsRepository {
  const _FakeSettingsRepository({required this.voiceAutoStart});

  final bool voiceAutoStart;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    return UserSettingsModel(
      id: 'settings-$userId',
      userId: userId,
      voiceAutoStart: voiceAutoStart,
    );
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}

class _ThrowingSettingsRepository extends SettingsRepository {
  int callCount = 0;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    callCount += 1;
    throw StateError('boom');
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    throw StateError('boom');
  }
}

/// 광고 게이트 정책(무료횟수/광고표시)을 완전히 우회하고 항상 즉시 진입을
/// 허용하는 fake delegate.
class _AllowAllVoiceConversationAdGateDelegate
    implements VoiceConversationAdGateDelegate {
  const _AllowAllVoiceConversationAdGateDelegate();

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    onEnterAllowed(
      const VoiceConversationEntryGrant(
        sessionId: 'test-session',
        source: EntitlementSource.remoteDisabled,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 0,
      ),
    );
  }
}
