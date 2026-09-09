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
}
