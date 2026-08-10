import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';

/// Firebase Remote Config 래퍼.
///
/// 네트워크 실패가 있어도 앱 부팅을 막지 않도록
/// 기본값을 먼저 적용하고, fetch/activate는 best-effort로만 수행한다.
class RemoteConfigService {
  RemoteConfigService._();

  static FirebaseRemoteConfig? get _remoteConfig {
    if (Firebase.apps.isEmpty) {
      return null;
    }
    return FirebaseRemoteConfig.instance;
  }

  static bool _initialized = false;

  static const String _kGptModel = 'gpt_model';
  static const String _kBriefingEnabled = 'briefing_enabled';
  static const String _kEarlyBirdBannerVisible = 'early_bird_banner_visible';
  static const String _kEarlyBirdMessage = 'early_bird_message';
  static const String _kMaxVoiceDurationSeconds = 'max_voice_duration_seconds';
  static const String _kMinRequiredVersion = 'min_required_version';
  static const String _kRewardedAdEnabled = 'rewarded_ad_enabled';
  static const String _kRewardedAdUnitIdAndroid = 'rewarded_ad_unit_id_android';
  static const String _kGroupBackupRetentionDays =
      'group_backup_retention_days';
  static const String _kRewardAdVoiceConversationEnabled =
      'reward_ad_voice_conversation_enabled';
  static const String _kVoiceConversationFreeTrialCount =
      'voice_conversation_free_trial_count';
  static const String _kRewardAdFailurePolicy = 'reward_ad_failure_policy';
  static const String _kVoiceConversationButtonEnabled =
      'voice_conversation_button_enabled';
  static const String _kVoiceConversationInitialFreeCount =
      'voice_conversation_initial_free_count';
  static const String _kVoiceConversationDailyFreeCount =
      'voice_conversation_daily_free_count';

  /// [voiceConversationInitialFreeCount]의 코드 기본값(콘솔 미설정 시 최종 폴백).
  static const int kVoiceConversationInitialFreeCountDefault = 3;

  /// [voiceConversationDailyFreeCount]의 코드 기본값(콘솔 미설정 시 최종 폴백).
  static const int kVoiceConversationDailyFreeCountDefault = 0;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    final remoteConfig = _remoteConfig;
    if (remoteConfig == null) {
      _initialized = true;
      return;
    }

    await remoteConfig.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(hours: 1),
      ),
    );

    await remoteConfig.setDefaults(
      <String, Object>{
        _kGptModel: 'gpt-4o-mini',
        _kBriefingEnabled: true,
        _kEarlyBirdBannerVisible: true,
        _kEarlyBirdMessage: '지금 등록하면 PRO 기능을 먼저 경험할 수 있어요.',
        _kMaxVoiceDurationSeconds: 60,
        _kMinRequiredVersion: 0,
        _kRewardedAdEnabled: false,
        _kRewardedAdUnitIdAndroid: '',
        _kGroupBackupRetentionDays: 30,
        _kRewardAdVoiceConversationEnabled: true,
        _kVoiceConversationFreeTrialCount: 3,
        _kRewardAdFailurePolicy: 'retry',
        _kVoiceConversationButtonEnabled: true,
        _kVoiceConversationInitialFreeCount:
            kVoiceConversationInitialFreeCountDefault,
        _kVoiceConversationDailyFreeCount:
            kVoiceConversationDailyFreeCountDefault,
      },
    );

    try {
      await remoteConfig.fetchAndActivate();
    } catch (_) {
      // 네트워크가 없어도 앱은 기본값으로 계속 부팅한다.
    }

    _initialized = true;
  }

  static String get gptModel =>
      _remoteConfig?.getString(_kGptModel) ?? 'gpt-4o-mini';

  static bool get briefingEnabled =>
      _remoteConfig?.getBool(_kBriefingEnabled) ?? true;

  static bool get earlyBirdBannerVisible =>
      _remoteConfig?.getBool(_kEarlyBirdBannerVisible) ?? true;

  static String get earlyBirdMessage =>
      _remoteConfig?.getString(_kEarlyBirdMessage) ??
      '지금 등록하면 PRO 기능을 먼저 경험할 수 있어요.';

  static int getInt(String key, {int defaultValue = 0}) {
    try {
      return _remoteConfig?.getInt(key) ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  static int get maxVoiceDurationSeconds =>
      _remoteConfig?.getInt(_kMaxVoiceDurationSeconds) ?? 60;

  static int get minRequiredVersion => getInt(_kMinRequiredVersion);

  /// 리워드 광고 마스터 스위치. 기본값 false (출시 초기 OFF).
  static bool get rewardedAdEnabled =>
      _remoteConfig?.getBool(_kRewardedAdEnabled) ?? false;

  /// 운영 광고 단위 ID. Remote Config 콘솔에서 설정. 비어 있거나 형식이
  /// 잘못되면 AdService가 폴백 없이 리워드 광고를 비활성화한다(release 한정,
  /// debug/profile은 항상 Google 테스트 ID 사용).
  static String get rewardedAdUnitIdAndroid =>
      _remoteConfig?.getString(_kRewardedAdUnitIdAndroid) ?? '';

  /// 그룹 백업 보관 기간(일). 기본 30일.
  static int get groupBackupRetentionDays =>
      getInt(_kGroupBackupRetentionDays, defaultValue: 30);

  /// 음성 대화 모드 광고 자체 활성화. 기본 true.
  static bool get rewardAdVoiceConversationEnabled =>
      _remoteConfig?.getBool(_kRewardAdVoiceConversationEnabled) ?? true;

  /// 광고 없이 무료 사용 가능 횟수. 기본 3회.
  static int get voiceConversationFreeTrialCount =>
      getInt(_kVoiceConversationFreeTrialCount, defaultValue: 3);

  /// 광고 실패 시 정책. 음성 대화는 항상 재시도(retry)로 fail-closed 한다.
  static String get rewardAdFailurePolicy =>
      _remoteConfig?.getString(_kRewardAdFailurePolicy) ?? 'retry';

  /// 홈 화면 음성 대화 진입 버튼 표시 여부. 기본 true.
  static bool get voiceConversationButtonEnabled =>
      _remoteConfig?.getBool(_kVoiceConversationButtonEnabled) ?? true;

  /// 키가 콘솔에서 실제로 fetch된 값(ValueSource.valueRemote)일 때만 그
  /// 값을 반환한다. Firebase Remote Config의 getInt()는 콘솔에 키가 아예
  /// 없어도(미설정) 0을 반환하므로(null이 아님), source를 확인하지 않으면
  /// "미설정"과 "명시적으로 0"을 구분할 수 없다.
  static int? _getIntIfRemote(String key) {
    final remoteConfig = _remoteConfig;
    if (remoteConfig == null) {
      return null;
    }
    try {
      final value = remoteConfig.getValue(key);
      if (value.source != ValueSource.valueRemote) {
        return null;
      }
      return value.asInt();
    } catch (_) {
      return null;
    }
  }

  /// 최초 누적 무료 대화 횟수 판단 우선순위를 결정하는 순수 함수.
  ///
  /// 1) 신규 키(`voice_conversation_initial_free_count`)가 콘솔에서 실제로
  ///    fetch됐으면(source == valueRemote) 그 값을 그대로 채택한다(0 포함).
  /// 2) 신규 키가 미설정이면 레거시 키
  ///    (`voice_conversation_free_trial_count`)가 콘솔에서 실제로
  ///    fetch됐을 때만 그 값을 하위호환 폴백으로 채택한다.
  /// 3) 둘 다 없으면 코드 기본값([kVoiceConversationInitialFreeCountDefault])
  ///    으로 폴백한다.
  static int resolveInitialFreeCount({
    required bool newKeySet,
    required int newKeyValue,
    required bool legacyKeySet,
    required int legacyKeyValue,
  }) {
    if (newKeySet) {
      return newKeyValue;
    }
    if (legacyKeySet) {
      return legacyKeyValue;
    }
    return kVoiceConversationInitialFreeCountDefault;
  }

  /// 일일 무료 대화 횟수 판단 우선순위를 결정하는 순수 함수.
  ///
  /// 레거시 키가 없으므로 신규 키가 콘솔에서 실제로 fetch됐을 때만(0 포함)
  /// 그 값을 채택하고, 미설정이면 코드 기본값
  /// ([kVoiceConversationDailyFreeCountDefault])으로 폴백한다.
  static int resolveDailyFreeCount({
    required bool newKeySet,
    required int newKeyValue,
  }) {
    if (newKeySet) {
      return newKeyValue;
    }
    return kVoiceConversationDailyFreeCountDefault;
  }

  /// 최초 누적 무료 대화 횟수. 콘솔 미설정 시 레거시 키
  /// ([voiceConversationFreeTrialCount])를 거쳐 기본값
  /// [kVoiceConversationInitialFreeCountDefault]로 폴백한다.
  static int get voiceConversationInitialFreeCount {
    final newValue = _getIntIfRemote(_kVoiceConversationInitialFreeCount);
    final legacyValue = _getIntIfRemote(_kVoiceConversationFreeTrialCount);
    return resolveInitialFreeCount(
      newKeySet: newValue != null,
      newKeyValue: newValue ?? 0,
      legacyKeySet: legacyValue != null,
      legacyKeyValue: legacyValue ?? 0,
    );
  }

  /// 일일 무료 대화 횟수. 콘솔 미설정 시 기본값
  /// [kVoiceConversationDailyFreeCountDefault]로 폴백한다.
  static int get voiceConversationDailyFreeCount {
    final newValue = _getIntIfRemote(_kVoiceConversationDailyFreeCount);
    return resolveDailyFreeCount(
      newKeySet: newValue != null,
      newKeyValue: newValue ?? 0,
    );
  }
}
