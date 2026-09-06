import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:planflow/services/ad_consent_service.dart';
import 'package:planflow/services/ad_service.dart';
import 'package:planflow/services/ad_runtime_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const umpChannelName = 'plugins.flutter.io/google_mobile_ads/ump';
  const adsChannelName = 'plugins.flutter.io/google_mobile_ads';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        MethodChannel(
          umpChannelName,
          StandardMethodCodec(UserMessagingCodec()),
        ),
        null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel(adsChannelName),
        null,
      );
    AdConsentService.instance.resetForTesting();
    AdService.instance.dispose();
  });

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

  test('unsupported iOS makes every public ads boundary a zero-call path',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var umpCalls = 0;
    var adsCalls = 0;
    var injectedInitializerCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      MethodChannel(
        umpChannelName,
        StandardMethodCodec(UserMessagingCodec()),
      ),
      (call) async {
        umpCalls += 1;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(adsChannelName),
      (call) async {
        adsCalls += 1;
        return null;
      },
    );

    final consent = AdConsentService.instance;
    final adService = AdService(
      dynamicAdsInitializer: () async {
        injectedInitializerCalls += 1;
        return null;
      },
    );

    expect(consent.canRequestAds, isFalse);
    expect(await consent.canRequestAdsLive, isFalse);
    await consent.ensureReady();
    await consent.retryAfterUserAction();
    expect(consent.requiresConsentForm, isFalse);
    expect(await consent.privacyOptionsRequired, isFalse);
    expect(await consent.showPrivacyOptionsForm(), isFalse);

    await adService.initialize();
    expect(
      await adService.showForParseSchedule(requestId: 'runtime-boundary'),
      isFalse,
    );
    expect(
      await adService.preloadForUserInitiatedRewardedAd(
        requestId: 'runtime-boundary',
      ),
      isFalse,
    );
    final voiceOutcome = await adService.showForVoiceConversationWithOutcome(
      requestId: 'runtime-boundary',
    );
    expect(voiceOutcome.kind, VoiceConversationAdOutcomeKind.disabled);

    expect(umpCalls, 0);
    expect(adsCalls, 0);
    expect(injectedInitializerCalls, 0);

    adService.dispose();
  });

  test('production iOS plist has no AdMob app ID', () {
    final plist = File(
        'ios${Platform.pathSeparator}Runner${Platform.pathSeparator}Info.plist');
    expect(plist.existsSync(), isTrue);
    expect(
        plist.readAsStringSync(), isNot(contains('GADApplicationIdentifier')));
  });
}
