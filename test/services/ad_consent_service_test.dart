import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/consent_information.dart';
import 'package:google_mobile_ads/src/ump/consent_request_parameters.dart';
import 'package:google_mobile_ads/src/ump/form_error.dart';
import 'package:planflow/services/ad_consent_service.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConsentInformation extends ConsentInformation {
  _FakeConsentInformation(this.failure);

  final FormError failure;

  @override
  void requestConsentInfoUpdate(
    ConsentRequestParameters params,
    OnConsentInfoUpdateSuccessListener successListener,
    OnConsentInfoUpdateFailureListener failureListener,
  ) {
    failureListener(failure);
  }

  @override
  Future<bool> isConsentFormAvailable() async => false;

  @override
  Future<ConsentStatus> getConsentStatus() async => ConsentStatus.unknown;

  @override
  Future<void> reset() async {}

  @override
  Future<bool> canRequestAds() async => false;

  @override
  Future<PrivacyOptionsRequirementStatus>
      getPrivacyOptionsRequirementStatus() async =>
          PrivacyOptionsRequirementStatus.notRequired;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('UMP FormError path emits one ad_load_failed analytics event', () async {
    expect(RemoteConfigService.rewardedAdEnabled, isTrue);

    final originalConsentInformation = ConsentInformation.instance;
    final originalDebugPrint = debugPrint;
    final messages = <String>[];

    ConsentInformation.instance = _FakeConsentInformation(
      FormError(errorCode: 123, message: 'test-error'),
    );
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        messages.add(message);
      }
    };

    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await AdConsentService.instance.retryAfterUserAction();
    } finally {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      ConsentInformation.instance = originalConsentInformation;
      debugPrint = originalDebugPrint;
      await AdConsentService.instance.retryAfterUserAction();
      debugDefaultTargetPlatformOverride = null;
    }

    final analyticsEvents = messages
        .where((message) =>
            message.contains('Analytics event skipped (ad_load_failed)'))
        .toList();

    expect(analyticsEvents, hasLength(1));
    expect(AdConsentService.instance.isAvailable, isFalse);
    expect(AdConsentService.instance.canRequestAds, isFalse);
  });
}
