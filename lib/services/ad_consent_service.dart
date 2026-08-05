import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'remote_config_service.dart';

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

  bool _initialized = false;
  bool _available = false;

  bool get isAvailable => _available;

  /// 광고 활성화 여부 (마스터 스위치 OFF면 비활성).
  /// - EEA에서 동의 거부 시에도 false 반환 (광고 미표시).
  /// - 동기 컨텍스트(UI 게이트)에서도 사용 가능하도록 캐시된 _available을 즉시 반환.
  /// - 라이브 UMP 상태(ConsentInformation.instance.canRequestAds)가 필요하면
  ///   [canRequestAdsLive]를 사용할 것.
  bool get canRequestAds {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (!_initialized) {
      return false;
    }
    return _available;
  }

  /// 라이브 UMP 상태 조회 (Future).
  /// - 동기 게이트가 어렵거나 초기화 후 변동이 있었을 때 사용.
  /// - 실패 시 [_available] 폴백.
  Future<bool> get canRequestAdsLive async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (!_initialized) {
      return false;
    }
    try {
      return await ConsentInformation.instance.canRequestAds();
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
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (!RemoteConfigService.rewardedAdEnabled) {
      _available = false;
      return;
    }
    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          // 1단계 성공 → EEA 사용자에게 동의 폼 표시 (비-EEA는 즉시 콜백 발화).
          final completer = Completer<void>();
          try {
            await ConsentForm.loadAndShowConsentFormIfRequired(
              (FormError? formError) {
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
            // 폼이 닫힌 뒤 UMP의 라이브 상태로 _available 결정.
            try {
              _available = await ConsentInformation.instance.canRequestAds();
            } catch (_) {
              _available = false;
            }
          } catch (error, stackTrace) {
            debugPrint(
              'AdConsentService loadAndShowConsentFormIfRequired failed: $error',
            );
            debugPrintStack(stackTrace: stackTrace);
            _available = false;
          }
        },
        (FormError error) {
          debugPrint(
            'AdConsentService UMP failure: ${error.errorCode} ${error.message}',
          );
          _available = false;
        },
      );
    } catch (error, stackTrace) {
      debugPrint('AdConsentService initialize failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _available = false;
    }
  }

  /// GDPR/EEA 사용자에게 동의 폼을 띄워야 하는지.
  bool get requiresConsentForm => RemoteConfigService.rewardedAdEnabled;

  /// 사용자가 "개인정보 옵션" 폼을 열 수 있는 상태인지 (EEA/규제 지역).
  /// UMP ConsentInformation.privacyOptionsRequirementStatus 래퍼.
  /// - true: 설정 화면에 "광고 개인정보 설정" 진입 버튼 표시.
  /// - false: 비-EEA 또는 이미 동의 완료 → 버튼 숨김.
  /// - Remote Config 마스터 스위치 OFF면 항상 false.
  Future<bool> get privacyOptionsRequired async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    try {
      return ConsentInformation.instance.privacyOptionsRequirementStatus ==
          ConsentStatus.required;
    } catch (_) {
      return false;
    }
  }

  /// 사용자 요청 시 개인정보 옵션 폼 표시.
  /// - EEA/규제 지역 + 동의 상태 변경을 원하는 경우 사용.
  /// - 광고 흐름과 분리된 1회성 호출.
  Future<bool> showPrivacyOptionsForm() async {
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
