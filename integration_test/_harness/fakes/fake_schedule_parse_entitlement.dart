import 'package:planflow/services/schedule_parse_entitlement.dart';

/// [ScheduleParseEntitlementDelegate]의 결정론적 E2E fake.
///
/// 실제 seam: `lib/services/schedule_parse_entitlement.dart`의
/// `ScheduleParseEntitlementService.delegateForTest` setter(테스트/QA
/// 백도어) + `abstract class ScheduleParseEntitlementDelegate`. Supabase
/// RPC(`schedule_parse_entitlement_peek`/`consume_schedule_parse_free_usage`)를
/// 전혀 호출하지 않는다.
///
/// 사용법:
/// ```dart
/// final fake = FakeScheduleParseEntitlementDelegate();
/// ScheduleParseEntitlementService.instance.delegateForTest = fake;
/// addTearDown(() =>
///     ScheduleParseEntitlementService.instance.delegateForTest = null);
/// ```
class FakeScheduleParseEntitlementDelegate
    implements ScheduleParseEntitlementDelegate {
  FakeScheduleParseEntitlementDelegate({
    this.dailyRemaining = 2,
    this.requiresAd = false,
  });

  /// [peek]/[consume]이 반환할 일일 잔여 횟수. [consume]을 호출할 때마다
  /// 1씩 자동 차감된다(0 미만으로는 내려가지 않음).
  int dailyRemaining;

  /// [peek]이 반환할 requiresAd 플래그.
  bool requiresAd;

  int peekCallCount = 0;
  final List<String> consumedSessionIds = <String>[];

  @override
  Future<ScheduleParseEntitlementPeek?> peek() async {
    peekCallCount += 1;
    return ScheduleParseEntitlementPeek(
      dailyRemaining: dailyRemaining,
      requiresAd: requiresAd,
    );
  }

  @override
  Future<ScheduleParseConsumeResult?> consume(String sessionId) async {
    consumedSessionIds.add(sessionId);
    if (dailyRemaining > 0) {
      dailyRemaining -= 1;
    }
    return ScheduleParseConsumeResult(
      source: dailyRemaining >= 0 ? 'daily_free' : 'ad_required',
      dailyRemaining: dailyRemaining,
    );
  }
}
