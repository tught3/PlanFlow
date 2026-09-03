import 'package:planflow/services/voice_conversation_entitlement.dart';

/// [VoiceConversationEntitlementDelegate]의 결정론적 E2E fake.
///
/// 실제 seam: `lib/services/voice_conversation_entitlement.dart`의
/// `VoiceConversationEntitlementService.delegateForTest` setter +
/// `abstract class VoiceConversationEntitlementDelegate`.
/// `fake_schedule_parse_entitlement.dart`와 동일 패턴(별도 RPC/카운터를
/// 쓰는 독립 엔타이틀먼트 서비스).
///
/// 사용법:
/// ```dart
/// final fake = FakeVoiceConversationEntitlementDelegate();
/// VoiceConversationEntitlementService.instance.delegateForTest = fake;
/// addTearDown(() =>
///     VoiceConversationEntitlementService.instance.delegateForTest = null);
/// ```
class FakeVoiceConversationEntitlementDelegate
    implements VoiceConversationEntitlementDelegate {
  FakeVoiceConversationEntitlementDelegate({
    this.initialRemaining = 3,
    this.dailyRemaining = 2,
    this.requiresAd = false,
  });

  /// [peek]/[consume]이 반환할 최초 누적 무료 잔여 횟수.
  int initialRemaining;

  /// [peek]/[consume]이 반환할 일일 무료 잔여 횟수.
  int dailyRemaining;

  /// [peek]이 반환할 requiresAd 플래그.
  bool requiresAd;

  int peekCallCount = 0;
  final List<String> consumedSessionIds = <String>[];

  @override
  Future<VoiceConversationEntitlementPeek?> peek() async {
    peekCallCount += 1;
    return VoiceConversationEntitlementPeek(
      initialRemaining: initialRemaining,
      dailyRemaining: dailyRemaining,
      requiresAd: requiresAd,
    );
  }

  @override
  Future<VoiceConversationConsumeResult?> consume(String sessionId) async {
    consumedSessionIds.add(sessionId);
    var source = 'ad_required';
    if (initialRemaining > 0) {
      initialRemaining -= 1;
      source = 'initial_free';
    } else if (dailyRemaining > 0) {
      dailyRemaining -= 1;
      source = 'daily_free';
    }
    return VoiceConversationConsumeResult(
      source: source,
      initialRemaining: initialRemaining,
      dailyRemaining: dailyRemaining,
    );
  }
}
