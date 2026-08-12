import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';

void main() {
  tearDown(() {
    VoiceConversationEntitlementService.instance.delegateForTest = null;
    AppEnv.resetSupabaseInitializationState();
  });

  group('buildVoiceConversationPeekParams', () {
    test('일일 무료 정책(daily=1)이 그대로 RPC 파라미터로 전달된다', () {
      final params = buildVoiceConversationPeekParams(
        initialLimit: 3,
        dailyLimit: 1,
      );

      expect(params, <String, dynamic>{
        'p_initial_limit': 3,
        'p_daily_limit': 1,
      });
    });

    test('일일 무료가 꺼진 값(daily=0)도 하드코딩 없이 그대로 전달된다', () {
      final params = buildVoiceConversationPeekParams(
        initialLimit: 3,
        dailyLimit: 0,
      );

      expect(params['p_daily_limit'], 0);
    });
  });

  group('buildVoiceConversationConsumeParams', () {
    test('sessionId와 일일 무료 정책(daily=1)이 그대로 RPC 파라미터로 전달된다', () {
      final params = buildVoiceConversationConsumeParams(
        sessionId: 'session-xyz',
        initialLimit: 3,
        dailyLimit: 1,
      );

      expect(params, <String, dynamic>{
        'p_session_id': 'session-xyz',
        'p_initial_limit': 3,
        'p_daily_limit': 1,
      });
    });
  });

  group('VoiceConversationEntitlementService.peek', () {
    test('delegate가 주입되면 delegate 결과를 그대로 반환한다', () async {
      VoiceConversationEntitlementService.instance.delegateForTest =
          _FakeDelegate(
        peekResult: const VoiceConversationEntitlementPeek(
          initialRemaining: 2,
          dailyRemaining: 1,
          requiresAd: false,
        ),
      );

      final result = await VoiceConversationEntitlementService.instance.peek();

      expect(result, isNotNull);
      expect(result!.initialRemaining, 2);
      expect(result.dailyRemaining, 1);
      expect(result.requiresAd, isFalse);
    });

    test('delegate가 null을 반환하면 그대로 null을 전달한다(fail-open)', () async {
      VoiceConversationEntitlementService.instance.delegateForTest =
          _FakeDelegate(peekResult: null);

      final result = await VoiceConversationEntitlementService.instance.peek();

      expect(result, isNull);
    });

    test('Supabase 미준비 상태에서는 delegate 없이도 null을 반환한다', () async {
      AppEnv.resetSupabaseInitializationState();

      final result = await VoiceConversationEntitlementService.instance.peek();

      expect(result, isNull);
    });
  });

  group('VoiceConversationEntitlementService.consume', () {
    test('delegate가 주입되면 delegate 결과를 그대로 반환한다', () async {
      VoiceConversationEntitlementService.instance.delegateForTest =
          _FakeDelegate(
        consumeResult: const VoiceConversationConsumeResult(
          source: 'initial_free',
          initialRemaining: 1,
          dailyRemaining: 1,
        ),
      );

      final result = await VoiceConversationEntitlementService.instance
          .consume('session-1');

      expect(result, isNotNull);
      expect(result!.source, 'initial_free');
      expect(result.initialRemaining, 1);
      expect(result.dailyRemaining, 1);
    });

    test('delegate가 예외성 실패(null)를 반환하면 그대로 null을 전달한다(fail-open)', () async {
      VoiceConversationEntitlementService.instance.delegateForTest =
          _FakeDelegate(consumeResult: null);

      final result = await VoiceConversationEntitlementService.instance
          .consume('session-2');

      expect(result, isNull);
    });

    test('Supabase 미준비 상태에서는 delegate 없이도 null을 반환한다(사용자 명령 차단 없음)',
        () async {
      AppEnv.resetSupabaseInitializationState();

      final result = await VoiceConversationEntitlementService.instance
          .consume('session-3');

      expect(result, isNull);
    });
  });

  group('VoiceConversationSessionIdGenerator', () {
    test('연속 호출은 서로 다른 sessionId를 생성한다', () {
      final ids = List<String>.generate(
        20,
        (_) => VoiceConversationSessionIdGenerator.next(),
      );

      expect(ids.toSet().length, ids.length);
    });

    test('sessionId는 비어있지 않은 문자열이다', () {
      final id = VoiceConversationSessionIdGenerator.next();

      expect(id, isNotEmpty);
      expect(id, startsWith('voice_conv_session_'));
    });
  });

  group('VoiceConversationEntryGrant', () {
    test('생성자로 전달한 필드를 그대로 보존한다', () {
      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-abc',
        source: EntitlementSource.dailyFree,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 1,
      );

      expect(grant.sessionId, 'session-abc');
      expect(grant.source, EntitlementSource.dailyFree);
      expect(grant.initialRemainingAtGate, 0);
      expect(grant.dailyRemainingAtGate, 1);
      expect(grant.toString(), contains('session-abc'));
    });
  });
}

class _FakeDelegate implements VoiceConversationEntitlementDelegate {
  _FakeDelegate({this.peekResult, this.consumeResult});

  final VoiceConversationEntitlementPeek? peekResult;
  final VoiceConversationConsumeResult? consumeResult;

  @override
  Future<VoiceConversationEntitlementPeek?> peek() async => peekResult;

  @override
  Future<VoiceConversationConsumeResult?> consume(String sessionId) async =>
      consumeResult;
}
