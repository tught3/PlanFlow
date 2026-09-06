import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/analytics_service.dart';
import '../core/diag_logger.dart';
import 'ad_runtime_policy.dart';
import 'remote_config_service.dart';

enum ConsentReadiness { idle, checking, ready, retryableFailure, notEligible }

/// Google UMP(User Messaging Platform) 동의 관리.
///
/// GDPR/EEA 사용자는 동의 폼을 표시해야 한다. 비-EEA는 자동 처리된다.
///
/// 1차 배포 정책:
/// - Remote Config `rewarded_ad_enabled`가 false이면 UMP를 띄우지 않는다.
/// - EEA 추정은 UMP 내부 로직에 맡긴다 (ConsentInformation).
/// - 동의 결과는 어디에도 저장하지 않고 UMP가 자체 persistent store로 보관한다.
class AdConsentService {
  AdConsentService._();

  static final AdConsentService instance = AdConsentService._();

  bool _available = false;
  ConsentReadiness _readiness = ConsentReadiness.idle;
  Future<void>? _inFlight;
  int _attemptGeneration = 0;

  static const Duration _initializationTimeout = Duration(seconds: 4);

  bool get isAvailable => _available;
  ConsentReadiness get readiness => _readiness;

  /// 광고 활성화 여부 (마스터 스위치 OFF면 비활성).
  /// - EEA에서 동의 거부 시에도 false 반환 (광고 미표시).
  /// - 동기 컨텍스트(UI 게이트)에서도 사용 가능하도록 캐시된 _available을 즉시 반환.
  /// - 라이브 UMP 상태(ConsentInformation.instance.canRequestAds)가 필요하면
  ///   [canRequestAdsLive]를 사용할 것.
  bool get canRequestAds {
    if (!isAdsRuntimeSupported()) {
      return false;
    }
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (_readiness != ConsentReadiness.ready) {
      return false;
    }
    return _available;
  }

  /// 라이브 UMP 상태 조회 (Future).
  /// - 동기 게이트가 어렵거나 초기화 후 변동이 있었을 때 사용.
  /// - 실패 시 [_available] 폴백.
  Future<bool> get canRequestAdsLive async {
    if (!isAdsRuntimeSupported()) {
      return false;
    }
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (_readiness != ConsentReadiness.ready &&
        _readiness != ConsentReadiness.retryableFailure) {
      return false;
    }
    try {
      final available = await ConsentInformation.instance.canRequestAds();
      // UMP guidance allows an existing consent decision to remain usable
      // even when the latest update failed. Promote that live result so the
      // ad SDK is not blocked by a transient retryable failure.
      if (available && _readiness == ConsentReadiness.retryableFailure) {
        _available = true;
        _readiness = ConsentReadiness.ready;
      }
      return available;
    } catch (_) {
      return _available;
    }
  }

  /// main.dart 초기화 흐름에서 한 번 호출.
  /// - 백그라운드에서 UMP 동의 상태를 갱신한다.
  /// - 실패해도 광고 흐름 전체를 막지 않는다 (best-effort).
  ///
  /// UMP 3단계 시퀀스:
  /// 1. `requestConsentInfoUpdate` — UMP 동의 정보 갱신 요청 (Platform 채널).
  /// 2. onSuccess에서 `ConsentForm.loadAndShowConsentFormIfRequired` 호출 —
  ///    EEA 사용자에게는 동의 폼을 띄우고, 비-EEA/이미 동의된 사용자는
  ///    즉시 콜백이 발화되어 폼을 표시하지 않는다.
  /// 3. 폼이 닫힌 후 `ConsentInformation.canRequestAds()`로 광고 요청 가능 여부를
  ///    실측해 `_available`에 반영한다. 이 시점 이전에 `_available=true`를
  ///    설정하면 EEA 사용자가 동의 폼을 보기 전에 광고가 노출될 수 있다.
  Future<void> initialize() async {
    await ensureReady(userInitiated: false);
  }

  /// Ensures UMP is ready. A user initiated request may retry one transient
  /// failure; background startup must never create an endless retry loop.
  Future<void> ensureReady({bool userInitiated = false}) async {
    if (!isAdsRuntimeSupported()) {
      _available = false;
      _readiness = ConsentReadiness.notEligible;
      DiagLogger.log(
        'RewardedAdConsent',
        unsupportedAdsRuntimeDiagnostic('AdConsentService.ensureReady'),
      );
      return;
    }
    if (_readiness == ConsentReadiness.ready ||
        _readiness == ConsentReadiness.notEligible) {
      return;
    }
    final existing = _inFlight;
    if (existing != null) {
      await existing;
      return;
    }
    if (_readiness == ConsentReadiness.retryableFailure && !userInitiated) {
      return;
    }
    final generation = ++_attemptGeneration;
    final future = _runConsentAttempt(generation);
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<void> _runConsentAttempt(int generation) async {
    _readiness = ConsentReadiness.checking;
    _available = false;
    DiagLogger.log(
      'RewardedAdConsent',
      'phase=checking attempt=$generation '
          'rcFetch=${RemoteConfigService.lastFetchSucceeded} '
          'rcSource=${RemoteConfigService.rewardedAdConfigSource} '
          'rcEnabled=${RemoteConfigService.rewardedAdEnabled}',
    );
    if (!RemoteConfigService.rewardedAdEnabled) {
      _available = false;
      _readiness = ConsentReadiness.notEligible;
      DiagLogger.log(
        'RewardedAdConsent',
        'phase=not_eligible attempt=$generation reason=rc_disabled',
      );
      return;
    }
    // requestConsentInfoUpdate는 콜백 기반(void 반환)이라 자체적으로는
    // await할 수 없다. 3단계 시퀀스가 전부 끝난 뒤에야 initialize()의
    // Future가 완료되도록 outerCompleter로 감싼다 — 이걸 빼먹으면
    // _available이 아직 기본값(false)인 채로 initialize()가 먼저
    // 반환해버려, 호출부(AdService)가 "동의 미획득"으로 오판하고
    // 광고 초기화를 조기 종료하는 경쟁 상태가 발생한다.
    final outerCompleter = Completer<void>();
    bool settled = false;
    void completeUnavailable(
      Object error, [
      StackTrace? stackTrace,
      String? analyticsReason,
    ]) {
      if (settled) return;
      settled = true;
      if (generation != _attemptGeneration) {
        if (!outerCompleter.isCompleted) outerCompleter.complete();
        return;
      }
      _available = false;
      _readiness = ConsentReadiness.retryableFailure;
      DiagLogger.log(
        'RewardedAdConsent',
        'phase=retryable_failure attempt=$generation '
            'reason=${analyticsReason ?? error.runtimeType}',
      );
      debugPrint('AdConsentService initialize failed: $error');
      if (stackTrace != null) {
        debugPrintStack(stackTrace: stackTrace);
      }
      unawaited(
        AnalyticsService.logAdLoadFailed(
          reason: analyticsReason ?? 'ump_init_error_${error.runtimeType}',
          requestId: 'consent_init',
        ),
      );
      if (!outerCompleter.isCompleted) {
        outerCompleter.complete();
      }
    }

    void completeAvailable(bool available) {
      if (settled) return;
      settled = true;
      if (generation != _attemptGeneration) {
        if (!outerCompleter.isCompleted) outerCompleter.complete();
        return;
      }
      _available = available;
      _readiness =
          available ? ConsentReadiness.ready : ConsentReadiness.notEligible;
      DiagLogger.log(
        'RewardedAdConsent',
        'phase=${available ? 'ready' : 'not_eligible'} '
            'attempt=$generation available=$available',
      );
      if (!outerCompleter.isCompleted) {
        outerCompleter.complete();
      }
    }

    runZonedGuarded(() {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          // The platform API is callback-based and can invoke this success
          // callback after our bounded attempt has timed out or after a newer
          // user-initiated attempt superseded it. Never start a consent form
          // for an obsolete attempt.
          if (generation != _attemptGeneration || settled) return;
          // 1단계 성공 → EEA 사용자에게 동의 폼 표시 (비-EEA는 즉시 콜백 발화).
          final completer = Completer<void>();
          try {
            if (generation != _attemptGeneration || settled) return;
            await ConsentForm.loadAndShowConsentFormIfRequired(
              (FormError? formError) {
                if (generation != _attemptGeneration || settled) {
                  if (!completer.isCompleted) completer.complete();
                  return;
                }
                if (formError != null) {
                  debugPrint(
                    'AdConsentService consentForm failure: '
                    '${formError.errorCode} ${formError.message}',
                  );
                }
                if (!completer.isCompleted) {
                  completer.complete();
                }
              },
            );
            await completer.future;
            if (generation != _attemptGeneration || settled) return;
            // 폼이 닫힌 뒤 UMP의 라이브 상태로 _available 결정.
            try {
              final available =
                  await ConsentInformation.instance.canRequestAds();
              completeAvailable(available);
            } catch (_) {
              completeAvailable(false);
            }
          } catch (error, stackTrace) {
            debugPrint(
              'AdConsentService loadAndShowConsentFormIfRequired failed: $error',
            );
            debugPrintStack(stackTrace: stackTrace);
            completeUnavailable(error, stackTrace);
          } finally {
            if (generation == _attemptGeneration && !settled) {
              completeAvailable(false);
            }
          }
        },
        (FormError error) {
          debugPrint(
            'AdConsentService UMP failure: ${error.errorCode} ${error.message}',
          );
          // completeUnavailable가 reason을 한 번만 기록한다.
          completeUnavailable(
            StateError('UMP form error ${error.errorCode}: ${error.message}'),
            null,
            'ump_form_error_${error.errorCode}',
          );
        },
      );
    }, (error, stackTrace) {
      // google_mobile_ads exposes requestConsentInfoUpdate as async void and
      // catches only PlatformException. MissingPluginException therefore
      // arrives here instead of the surrounding try/catch.
      completeUnavailable(error, stackTrace);
    });
    await outerCompleter.future.timeout(
      _initializationTimeout,
      onTimeout: () => completeUnavailable(
        TimeoutException('UMP consent initialization timed out'),
      ),
    );
  }

  /// 사용자 액션(예: 설정에서 재시도 버튼) 이후 UMP 동의를 한 번 더 시도.
  ///
  /// - 기존 [_initialized]/[_available] 플래그를 리셋한 뒤 [initialize]를
  ///   재호출해 UMP 동의 폼을 다시 띄울 수 있는 상태로 만든다.
  /// - 사용자가 EEA/규제 지역에서 동의를 거부했거나 광고 옵션을 변경하려 할 때
  ///   AdService가 호출한다.
  ///
  /// 진단 책임: M3 (이슈 A). 호출자/에러 경로 외 다른 코드는 일체 미수정.
  Future<void> retryAfterUserAction() async {
    if (!isAdsRuntimeSupported()) {
      _available = false;
      _readiness = ConsentReadiness.notEligible;
      DiagLogger.log(
        'RewardedAdConsent',
        unsupportedAdsRuntimeDiagnostic(
            'AdConsentService.retryAfterUserAction'),
      );
      return;
    }
    // An explicit user action is allowed to re-evaluate even a prior
    // notEligible result (for example after changing privacy options).
    _readiness = ConsentReadiness.idle;
    _available = false;
    await ensureReady(userInitiated: true);
  }

  @visibleForTesting
  void resetForTesting() {
    _inFlight = null;
    _attemptGeneration++;
    _available = false;
    _readiness = ConsentReadiness.idle;
  }

  /// GDPR/EEA 사용자에게 동의 폼을 띄워야 하는지.
  bool get requiresConsentForm =>
      isAdsRuntimeSupported() && RemoteConfigService.rewardedAdEnabled;

  /// 사용자가 "개인정보 옵션" 폼을 열 수 있는 상태인지 (EEA/규제 지역).
  /// UMP ConsentInformation.privacyOptionsRequirementStatus 래퍼.
  /// - true: 설정 화면에 "광고 개인정보 설정" 진입 버튼 표시.
  /// - false: 비-EEA 또는 이미 동의 완료 → 버튼 숨김.
  /// - Remote Config 마스터 스위치 OFF면 항상 false.
  Future<bool> get privacyOptionsRequired async {
    if (!isAdsRuntimeSupported()) {
      return false;
    }
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    try {
      return (await ConsentInformation.instance
              .getPrivacyOptionsRequirementStatus()) ==
          PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  /// 사용자 요청 시 개인정보 옵션 폼 표시.
  /// - EEA/규제 지역 + 동의 상태 변경을 원하는 경우 사용.
  /// - 광고 흐름과 분리된 1회성 호출.
  Future<bool> showPrivacyOptionsForm() async {
    if (!isAdsRuntimeSupported()) {
      return false;
    }
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    final completer = Completer<void>();
    try {
      await ConsentForm.showPrivacyOptionsForm(
        (FormError? error) {
          if (error != null) {
            completer.completeError(
              StateError(
                'privacy_options_failed: ${error.errorCode} ${error.message}',
              ),
            );
          } else {
            completer.complete();
          }
        },
      );
      await completer.future;
      return true;
    } catch (error, stackTrace) {
      debugPrint('AdConsentService.showPrivacyOptionsForm failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }
}
