import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/ad_runtime_policy.dart';

void main() {
  test('ads runtime policy supports Android only', () {
    expect(
      isAdsRuntimeSupported(isWeb: false, platform: TargetPlatform.android),
      isTrue,
    );
    expect(
      isAdsRuntimeSupported(isWeb: false, platform: TargetPlatform.iOS),
      isFalse,
    );
    expect(
      isAdsRuntimeSupported(isWeb: true, platform: TargetPlatform.android),
      isFalse,
    );
    expect(
      isAdsRuntimeSupported(isWeb: false, platform: TargetPlatform.macOS),
      isFalse,
    );
    expect(
      isAdsRuntimeSupported(isWeb: false, platform: TargetPlatform.windows),
      isFalse,
    );
    expect(
      isAdsRuntimeSupported(isWeb: false, platform: TargetPlatform.linux),
      isFalse,
    );
  });

  test('AdService and every public UMP entry point use the central guard', () {
    final adService = File('lib/services/ad_service.dart').readAsStringSync();
    final consentService =
        File('lib/services/ad_consent_service.dart').readAsStringSync();

    for (final entryPoint in <String>[
      'AdService.initialize',
      'AdService.showForParseSchedule',
      'AdService.preloadForUserInitiatedRewardedAd',
      'AdService.showForVoiceConversationWithOutcome',
    ]) {
      expect(
        adService,
        matches(
          RegExp(
            r"unsupportedAdsRuntimeDiagnostic\(\s*'" +
                RegExp.escape(entryPoint) +
                r"'\s*,?\s*\)",
          ),
        ),
      );
    }
    for (final entryPoint in <String>[
      'AdConsentService.ensureReady',
      'AdConsentService.retryAfterUserAction',
    ]) {
      expect(
        consentService,
        matches(
          RegExp(
            r"unsupportedAdsRuntimeDiagnostic\(\s*'" +
                RegExp.escape(entryPoint) +
                r"'\s*,?\s*\)",
          ),
        ),
      );
    }
    expect(consentService, contains('isAdsRuntimeSupported() &&'));
    expect(
        consentService, contains('Future<bool> get canRequestAdsLive async'));
    expect(consentService,
        contains('Future<bool> get privacyOptionsRequired async'));
    expect(consentService,
        contains('Future<bool> showPrivacyOptionsForm() async'));
    expect(adService, contains('await MobileAds.instance.initialize();'));
    expect(consentService,
        contains('ConsentInformation.instance.requestConsentInfoUpdate'));
    expect(consentService,
        contains('ConsentForm.loadAndShowConsentFormIfRequired'));
  });

  test('production iOS plist has no AdMob app ID', () {
    final plist = File(
        'ios${Platform.pathSeparator}Runner${Platform.pathSeparator}Info.plist');
    expect(plist.existsSync(), isTrue);
    expect(
        plist.readAsStringSync(), isNot(contains('GADApplicationIdentifier')));
  });
}
