import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;

  File file(String path) => File(
      '${root.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}');

  String read(String path) => file(path).readAsStringSync();

  String? plistValue(String plist, String key) {
    final match = RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist);
    return match?.group(1);
  }

  test('production Runner has exactly one strict, non-test AdMob app ID', () {
    final plist = file('ios/Runner/Info.plist');
    expect(plist.existsSync(), isTrue);
    final text = plist.readAsStringSync();
    expect(RegExp('GADApplicationIdentifier').allMatches(text), hasLength(1));
    final appId = plistValue(text, 'GADApplicationIdentifier');
    final hasValidShape =
        appId != null && RegExp(r'^ca-app-pub-[0-9]+~[0-9]+$').hasMatch(appId);
    final isNotPublicTestId =
        appId != 'ca-app-pub-3940256099942544~1458002511' &&
            appId != 'ca-app-pub-3940256099942544~3347511713';
    expect(hasValidShape, isTrue);
    expect(isNotPublicTestId, isTrue);
  });

  test('Runner App ID differs from Android manifest without exposing either ID', () {
    final runnerId = plistValue(read('ios/Runner/Info.plist'),
        'GADApplicationIdentifier');
    final android = read('android/app/src/main/AndroidManifest.xml');
    final androidId = RegExp(
      r'com\.google\.android\.gms\.ads\.APPLICATION_ID[\s\S]*?android:value="([^"]+)"',
    ).firstMatch(android)?.group(1);
    final hasValidAndroidShape = androidId != null &&
        RegExp(r'^ca-app-pub-[0-9]+~[0-9]+$').hasMatch(androidId);
    final idsDiffer =
        runnerId != null && androidId != null && runnerId != androidId;
    expect(hasValidAndroidShape, isTrue);
    expect(idsDiffer, isTrue);
  });

  test('Google Mobile Ads registration requires a valid Runner App ID', () {
    final registrant = read('ios/Runner/GeneratedPluginRegistrant.m');
    if (registrant.contains('google_mobile_ads')) {
      final runnerId = plistValue(read('ios/Runner/Info.plist'),
          'GADApplicationIdentifier');
      final hasValidRunnerShape = runnerId != null &&
          RegExp(r'^ca-app-pub-[0-9]+~[0-9]+$').hasMatch(runnerId);
      expect(hasValidRunnerShape, isTrue);
    }
  });

  test('Widget production plist has no AdMob app ID', () {
    final widget = read('ios/PlanFlowWidget/Info.plist');
    expect(widget, isNot(contains('GADApplicationIdentifier')));
  });

  test(
      'E2E injection is temporary and restores committed production plist',
      () {
    final script = file('scripts/ios/e2e_xctest_flow.sh').readAsStringSync();
    final productionId =
        plistValue(read('ios/Runner/Info.plist'), 'GADApplicationIdentifier');

    expect(script, contains('GADApplicationIdentifier'));
    expect(script, contains('ca-app-pub-3940256099942544~1458002511'));
    expect(script, contains('runner_plist_backup'));
    expect(script, contains('cp -p'));
    expect(script, contains('PlistBuddy'));
    expect(script, contains('restore_runner_plist'));
    expect(script, contains("trap 'on_exit \"\$?\"' EXIT"));
    expect(script, contains(r'''rm -f -- "$runner_plist_backup"'''));
    final e2eDoesNotContainProductionId =
        productionId != null && !script.contains(productionId);
    expect(e2eDoesNotContainProductionId, isTrue);
    expect(script, isNot(contains(r'''echo "$E2E_ADMOB_TEST_APP_ID"''')));
    expect(
        script, isNot(contains(r'''printf '%s\n' "$E2E_ADMOB_TEST_APP_ID"''')));
  });

  test('ATT (App Tracking Transparency) is not integrated', () {
    // Verify no app_tracking_transparency package dependency
    final pubspec = read('pubspec.yaml');
    expect(pubspec, isNot(contains('app_tracking_transparency')));

    // Verify no ATT API calls in codebase
    final dartFiles = Directory('${root.path}${Platform.pathSeparator}lib')
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    for (final dartFile in dartFiles) {
      final content = dartFile.readAsStringSync();
      expect(content, isNot(contains('ATTrackingManager')),
          reason:
              'ATTrackingManager found in ${dartFile.path}; ATT must not be used');
      expect(content, isNot(contains('requestTrackingAuthorization')),
          reason:
              'requestTrackingAuthorization found in ${dartFile.path}; ATT must not be used');
    }

    // Verify Info.plist has all required permission purpose strings
    final plist = read('ios/Runner/Info.plist');
    final requiredKeys = [
      'NSMicrophoneUsageDescription',
      'NSSpeechRecognitionUsageDescription',
      'NSLocationWhenInUseUsageDescription',
      'NSCalendarsUsageDescription',
      'NSCalendarsFullAccessUsageDescription',
      'NSPhotoLibraryUsageDescription',
      'NSPhotoLibraryAddUsageDescription',
    ];

    for (final key in requiredKeys) {
      final value = plistValue(plist, key);
      expect(value, isNotNull,
          reason: '$key is missing from ios/Runner/Info.plist');
      expect(value!.isNotEmpty, isTrue,
          reason: '$key in Info.plist is empty or malformed');
    }

    // App does not use ATT (no ATTrackingManager / IDFA access), so the
    // tracking purpose string must be absent, not present.
    expect(plistValue(plist, 'NSUserTrackingUsageDescription'), isNull,
        reason:
            'NSUserTrackingUsageDescription must not appear in ios/Runner/Info.plist; ATT is not integrated');
  });
}
