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
}
