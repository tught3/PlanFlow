import 'package:planflow/services/ad_service.dart';

/// [AdService]의 결정론적 E2E fake.
///
/// 실제 seam: `lib/services/ad_service.dart`의 3곳 `@visibleForTesting`
/// 최상위 함수(`runRewardedAdLifecycle`,
/// `shouldRetryRemoteConfigForRewardedUnit`,
/// `shouldDisableVoiceConversationAdsAfterRemoteConfigRetry`)는 순수 함수라
/// 이 fake와 무관하고, 실제 DI 포인트는 `AdService` 생성자
/// (`rewardState`/`consentService`/`dynamicAdsInitializer`, 약 274번째
/// 줄)와 공개 인스턴스 메서드 오버라이드다.
/// `test/services/ad_service_test.dart:624`의 `_SpyAdService extends
/// AdService` 패턴(서브클래싱 override)을 그대로 재사용했다 — AdMob SDK
/// (`google_mobile_ads`)를 직접 대체할 인터페이스가 없으므로, 실제
/// 광고 표시 흐름(`showForParseSchedule`/`showForVoiceConversationWithOutcome`)
/// 자체를 오버라이드해 SDK 호출을 없앤다.
class FakeAdService extends AdService {
  FakeAdService({
    this.rewardResult = true,
    this.outcome,
  }) : super(dynamicAdsInitializer: () async => null);

  /// [showForParseSchedule]가 반환할 값.
  bool rewardResult;

  /// [showForVoiceConversationWithOutcome]이 반환할 값. null이면
  /// [rewardResult]로부터 rewarded/dismissedWithoutReward를 파생한다.
  VoiceConversationAdOutcome? outcome;

  int showForParseScheduleCallCount = 0;
  int showForVoiceConversationCallCount = 0;
  final List<String> parseScheduleRequestIds = <String>[];
  final List<String> voiceConversationRequestIds = <String>[];

  @override
  Future<void> initialize() async {
    // 실제 SDK 초기화(Firebase/AdMob) 없이 즉시 완료된 것으로 간주한다.
  }

  @override
  Future<bool> showForParseSchedule({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async {
    showForParseScheduleCallCount += 1;
    parseScheduleRequestIds.add(requestId);
    onProgress?.call('loading');
    onProgress?.call('shown');
    onProgress?.call(rewardResult ? 'completed' : 'cancelled');
    return rewardResult;
  }

  @override
  Future<VoiceConversationAdOutcome> showForVoiceConversationWithOutcome({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async {
    showForVoiceConversationCallCount += 1;
    voiceConversationRequestIds.add(requestId);
    onProgress?.call('loading');
    onProgress?.call('shown');
    onProgress?.call(rewardResult ? 'completed' : 'cancelled');
    return outcome ??
        VoiceConversationAdOutcome(
          rewardResult
              ? VoiceConversationAdOutcomeKind.rewarded
              : VoiceConversationAdOutcomeKind.dismissedWithoutReward,
        );
  }
}
