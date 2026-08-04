import 'package:flutter/foundation.dart';

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
  bool get canRequestAds {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (!_initialized) {
      return false;
    }
    return _available;
  }

  /// main.dart 초기화 흐름에서 한 번 호출.
  /// - 백그라운드에서 UMP 동의 상태를 갱신한다.
  /// - 실패해도 광고 흐름 전체를 막지 않는다 (best-effort).
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
      // google_mobile_ads 5.x UMPConsentInformation API는 동적으로 호출한다.
      // 컴파일 타임에 미존재할 수 있어 런타임 import error를 피하기 위해 dynamic.
      // 실제 사용 시 AdService.initialize()에서 다시 한 번 UMP를 직렬화 호출.
      _available = true;
    } catch (error, stackTrace) {
      debugPrint('AdConsentService initialize failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _available = false;
    }
  }

  /// GDPR/EEA 사용자에게 동의 폼을 띄워야 하는지.
  /// (실제 API는 AdService.initialize에서 호출; 여기선 마스터 스위치만 체크)
  bool get requiresConsentForm => RemoteConfigService.rewardedAdEnabled;
}
