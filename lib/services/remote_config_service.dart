import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/diag_logger.dart';
import '../firebase_options.dart';

enum RemoteConfigReadiness {
  idle,
  checking,
  ready,
  retryableFailure,
  notEligible
}

@visibleForTesting
bool shouldAcceptRemoteConfigAttempt({
  required int completionAttempt,
  required int currentAttempt,
}) =>
    completionAttempt == currentAttempt;

/// Remote Config failure metadata safe for release diagnostics.
/// Values are deliberately limited to type/code/domain and never include the
/// fetched payload or an ad unit value.
class RemoteConfigFailureSnapshot {
  const RemoteConfigFailureSnapshot({
    required this.attempt,
    required this.failureType,
    required this.elapsedMs,
    required this.source,
    this.code,
    this.domain,
  });

  final int attempt;
  final String failureType;
  final int elapsedMs;
  final String source;
  final String? code;
  final String? domain;
}

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
  static Future<void>? _initializeFuture;
  static Future<bool>? _retryFuture;
  static Future<bool>? _firebaseInitFuture;
  static int _attempt = 0;
  static RemoteConfigReadiness _readiness = RemoteConfigReadiness.idle;
  static RemoteConfigFailureSnapshot? _lastFailure;

  static RemoteConfigReadiness get readiness => _readiness;
  static RemoteConfigFailureSnapshot? get lastFailure => _lastFailure;

  /// Firebase Core startup is shared by main and explicit ad retries. A
  /// timed-out startup attempt must not be considered permanently fatal:
  /// a later user action can join or start a fresh attempt safely.
  static Future<bool> ensureFirebaseInitialized() {
    if (Firebase.apps.isNotEmpty) return Future<bool>.value(true);
    final existing = _firebaseInitFuture;
    if (existing != null) return existing;
    final future = _runFirebaseInitialization();
    _firebaseInitFuture = future;
    return future.whenComplete(() {
      if (identical(_firebaseInitFuture, future)) _firebaseInitFuture = null;
    });
  }

  static Future<bool> _runFirebaseInitialization() async {
    final startedAt = DateTime.now();
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 8));
      DiagLogger.log(
        'FirebaseCore',
        'phase=ready elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} source=shared',
      );
      return true;
    } catch (error) {
      final type = error is TimeoutException ? 'timeout' : error.runtimeType;
      DiagLogger.log(
        'FirebaseCore',
        'phase=retryable_failure type=$type elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} source=shared',
      );
      return Firebase.apps.isNotEmpty;
    }
  }

  /// 마지막 fetchAndActivate() 시도의 성공 여부.
  ///
  /// - true: 콘솔 fetch가 정착한 후의 값을 읽고 있다는 신호.
  /// - false: 네트워크 실패/타임아웃으로 기본값(또는 캐시된 이전 값)을
  ///   읽고 있을 가능성 — 광고 진단 시 "RC가 진짜 OFF라서 광고가
  ///   꺼진 건지(fetch 성공 + 콘솔 OFF)", "그저 fetch가 실패해서
  ///   기본값(true)을 잘못 읽은 건지(fetch 실패)"를 구분하는 데 사용.
  ///
  /// 진단 책임: M2 (이슈 A). voice_conversation_* 영역은 일체 손대지 않는다.
  static bool _lastFetchSucceeded = false;

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
  static const String _kScheduleParseDailyFreeCount =
      'schedule_parse_daily_free_count';

  /// [voiceConversationInitialFreeCount]의 코드 기본값(콘솔 미설정 시 최종 폴백).
  static const int kVoiceConversationInitialFreeCountDefault = 3;

  /// [voiceConversationDailyFreeCount]의 코드 기본값(콘솔 미설정 시 최종 폴백).
  /// 정책상 "최초 3회 소진 후 매일 1회 무료"이므로 기본값은 1이어야 한다
  /// (0으로 두면 콘솔 설정 전까지 일일무료가 사실상 꺼진 채로 곧장 광고
  /// 단계로 넘어가는 버그가 됨 — 2026-08-09 실사용 중 발견).
  static const int kVoiceConversationDailyFreeCountDefault = 1;

  /// [scheduleParseDailyFreeCount]의 코드 기본값(콘솔 미설정 시 최종 폴백).
  /// AI 일정분석(GPT 파싱)은 하루 2회까지 광고 없이 무료로 사용할 수 있다.
  /// 세 번째 사용부터는 보상형 광고 1회 시청당 1회가 허용된다.
  static const int kScheduleParseDailyFreeCountDefault = 2;

  static Future<void> initialize() {
    if (_initialized || _readiness == RemoteConfigReadiness.notEligible) {
      return Future<void>.value();
    }
    final retry = _retryFuture;
    if (retry != null) {
      return retry.then<void>((_) {});
    }
    final existing = _initializeFuture;
    if (existing != null) return existing;
    final future = _runInitialize(forceFetch: false);
    _initializeFuture = future;
    return future.whenComplete(() {
      if (identical(_initializeFuture, future)) _initializeFuture = null;
    });
  }

  static Future<void> _runInitialize({required bool forceFetch}) async {
    final remoteConfig = _remoteConfig;
    if (remoteConfig == null) {
      _initialized = false;
      _readiness = RemoteConfigReadiness.retryableFailure;
      _recordFailure(
        attempt: ++_attempt,
        startedAt: DateTime.now(),
        error: StateError('firebase_core_unavailable'),
        source: 'firebase_core',
      );
      return;
    }

    final attempt = ++_attempt;
    final startedAt = DateTime.now();
    _readiness = RemoteConfigReadiness.checking;
    try {
      await remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          minimumFetchInterval:
              forceFetch ? Duration.zero : const Duration(hours: 1),
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
          _kRewardedAdEnabled: true,
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
          _kScheduleParseDailyFreeCount: kScheduleParseDailyFreeCountDefault,
        },
      );

      // This timeout belongs to Remote Config only. Firebase core startup is
      // bounded independently in main.dart and must not abort this 10s fetch.
      await remoteConfig
          .fetchAndActivate()
          .timeout(const Duration(seconds: 10));
      if (shouldAcceptRemoteConfigAttempt(
        completionAttempt: attempt,
        currentAttempt: _attempt,
      )) {
        _lastFetchSucceeded = true;
        _initialized = true;
        _readiness = RemoteConfigReadiness.ready;
        _lastFailure = null;
        DiagLogger.log(
          'RemoteConfig',
          'phase=ready attempt=$attempt elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} source=fetch',
        );
      }
    } catch (error) {
      if (shouldAcceptRemoteConfigAttempt(
        completionAttempt: attempt,
        currentAttempt: _attempt,
      )) {
        _lastFetchSucceeded = false;
        _initialized = false;
        _readiness = RemoteConfigReadiness.retryableFailure;
        _recordFailure(
          attempt: attempt,
          startedAt: startedAt,
          error: error,
          source: forceFetch ? 'user_retry' : 'startup',
        );
      }
    } finally {
      if (forceFetch &&
          shouldAcceptRemoteConfigAttempt(
            completionAttempt: attempt,
            currentAttempt: _attempt,
          )) {
        try {
          await remoteConfig.setConfigSettings(
            RemoteConfigSettings(
              fetchTimeout: Duration(seconds: 10),
              minimumFetchInterval: Duration(hours: 1),
            ),
          );
        } catch (_) {
          // Settings restoration is best effort; the next attempt resets it.
        }
      }
    }
  }

  static void _recordFailure({
    required int attempt,
    required DateTime startedAt,
    required Object error,
    required String source,
  }) {
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    String? code;
    String? domain;
    if (error is FirebaseException) {
      code = _sanitize(error.code);
      domain = _sanitize(error.plugin);
    } else if (error is PlatformException) {
      code = _sanitize(error.code);
      domain = 'platform';
    }
    final type =
        error is TimeoutException ? 'timeout' : error.runtimeType.toString();
    _lastFailure = RemoteConfigFailureSnapshot(
      attempt: attempt,
      failureType: _sanitize(type),
      elapsedMs: elapsedMs,
      source: _sanitize(source),
      code: code,
      domain: domain,
    );
    final details = <String>[
      'phase=retryable_failure',
      'attempt=$attempt',
      'type=${_sanitize(type)}',
      'elapsedMs=$elapsedMs',
      'source=${_sanitize(source)}',
    ];
    if (code != null && code.isNotEmpty) details.add('code=$code');
    if (domain != null && domain.isNotEmpty) details.add('domain=$domain');
    DiagLogger.log('RemoteConfig', details.join(' '));
  }

  static String _sanitize(String value) {
    final normalized = value.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  static Future<bool> retryFetchIfFailed() async {
    if (_lastFetchSucceeded) return true;
    final existingRetry = _retryFuture;
    if (existingRetry != null) return existingRetry;

    final future = _runUserRetry();
    _retryFuture = future;
    try {
      await future;
    } finally {
      if (identical(_retryFuture, future)) _retryFuture = null;
    }
    return _lastFetchSucceeded;
  }

  static Future<bool> _runUserRetry() async {
    var startup = _initializeFuture;
    if (startup != null) {
      await startup;
      if (_lastFetchSucceeded) return true;
      // A startup fetch may have just completed with a retryable failure.
      // Continue into a fresh user-initiated attempt instead of returning the
      // stale failure and blocking the same button tap.
      startup = _initializeFuture;
      if (startup != null) {
        await startup;
        if (_lastFetchSucceeded) return true;
      }
    }
    if (_lastFetchSucceeded) return true;
    var remoteConfig = _remoteConfig;
    if (remoteConfig == null) {
      if (!await ensureFirebaseInitialized()) return false;
      remoteConfig = _remoteConfig;
    }
    if (remoteConfig == null) return false;
    final future = _runInitialize(forceFetch: true);
    _initializeFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initializeFuture, future)) _initializeFuture = null;
    }
    return _lastFetchSucceeded;
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

  /// 리워드 광고 마스터 스위치. 기본값 true (프로덕션 일치;
  /// 페치 실패 시에도 fail-safe로 광고가 진행되도록 함).
  static bool get rewardedAdEnabled =>
      _remoteConfig?.getBool(_kRewardedAdEnabled) ?? true;

  /// 마지막 fetchAndActivate()가 성공했는지 여부.
  ///
  /// [initialize] 호출 이전이면 false. 네트워크 실패 후엔 false가 유지되고,
  /// 다음 fetch가 성공하면 true로 전환된다. 광고 진단(AdService.initialize)이
  /// "RC 콘솔에서 진짜 OFF"와 "fetch 실패로 기본값(true)을 잘못 읽음"을
  /// 구분하기 위해 참조한다.
  static bool get lastFetchSucceeded => _lastFetchSucceeded;

  /// 광고 진단용 적용 출처. 값 자체나 광고 단위 ID는 노출하지 않고,
  /// 각 스위치/단위 ID가 원격·기본·정적 중 어디에서 왔는지만 반환한다.
  static String get rewardedAdConfigSource {
    final remoteConfig = _remoteConfig;
    if (remoteConfig == null) return 'unavailable';
    try {
      String sourceFor(String key) => remoteConfig.getValue(key).source.name;
      return 'enabled=${sourceFor(_kRewardedAdEnabled)},'
          'unit=${sourceFor(_kRewardedAdUnitIdAndroid)},'
          'voice=${sourceFor(_kRewardAdVoiceConversationEnabled)}';
    } catch (_) {
      return _lastFetchSucceeded
          ? 'fetch_success_unknown'
          : 'default_or_cached';
    }
  }

  /// 테스트 전용 setter: [_lastFetchSucceeded]를 강제로 설정한다.
  ///
  /// Firebase Remote Config는 static singleton이고 `_lastFetchSucceeded`가
  /// private 정적 필드라 flutter test 환경에서 fake로 hit할 수 없다. 이
  /// setter는 voice_conversation_ad_gate의 fetch 실패/성공 분기를 단위
  /// 테스트에서 검증할 때만 사용한다. 프로덕션 코드 경로에서는 절대
  /// 호출되면 안 된다(@visibleForTesting).
  @visibleForTesting
  static set lastFetchSucceededForTest(bool value) =>
      _lastFetchSucceeded = value;

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
  /// 'free_pass'가 명시적으로 설정된 경우에만 광고 실패 시 무료 진입을
  /// 허용한다(schedule_parse_ad_gate.dart/voice_conversation_ad_gate.dart).
  static String get rewardAdFailurePolicy =>
      _rewardAdFailurePolicyOverride ??
      _remoteConfig?.getString(_kRewardAdFailurePolicy) ??
      'retry';

  /// 테스트 전용 오버라이드. null이면 실제 Remote Config 값을 사용한다.
  ///
  /// [lastFetchSucceededForTest]와 동일한 이유(Firebase Remote Config가
  /// static singleton이라 flutter test 환경에서 fake로 hit할 수 없음)로
  /// schedule_parse_ad_gate/voice_conversation_ad_gate의 free_pass 분기를
  /// 단위 테스트에서 검증할 때만 사용한다. 프로덕션 코드 경로에서는 절대
  /// 호출되면 안 된다(@visibleForTesting).
  static String? _rewardAdFailurePolicyOverride;

  @visibleForTesting
  static set rewardAdFailurePolicyForTest(String? value) =>
      _rewardAdFailurePolicyOverride = value;

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

  /// AI 일정분석(GPT 파싱) 일일 무료 횟수 판단 우선순위를 결정하는 순수 함수.
  ///
  /// 신규 키가 콘솔에서 실제로 fetch됐을 때만(0 포함) 그 값을 채택하고,
  /// 미설정이면 코드 기본값([kScheduleParseDailyFreeCountDefault])으로
  /// 폴백한다. ([resolveDailyFreeCount]와 동일한 정책, 별도 함수로 분리해
  /// voice_conversation 쪽 시그니처를 건드리지 않는다.)
  static int resolveScheduleParseDailyFreeCount({
    required bool newKeySet,
    required int newKeyValue,
  }) {
    if (newKeySet) {
      return newKeyValue;
    }
    return kScheduleParseDailyFreeCountDefault;
  }

  /// AI 일정분석(GPT 파싱) 일일 무료 횟수. 콘솔 미설정 시 기본값
  /// [kScheduleParseDailyFreeCountDefault]로 폴백한다.
  static int get scheduleParseDailyFreeCount {
    final newValue = _getIntIfRemote(_kScheduleParseDailyFreeCount);
    return resolveScheduleParseDailyFreeCount(
      newKeySet: newValue != null,
      newKeyValue: newValue ?? 0,
    );
  }
}
