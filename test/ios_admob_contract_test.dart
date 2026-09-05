import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;

  File file(String path) => File(
      '${root.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}');

  test('production iOS plist has no AdMob app ID', () {
    final plist = file('ios/Runner/Info.plist');
    expect(plist.existsSync(), isTrue);
    expect(
        plist.readAsStringSync(), isNot(contains('GADApplicationIdentifier')));
  });

  test(
      'E2E script injects only the public Google test app ID and restores plist',
      () {
    final script = file('scripts/ios/e2e_xctest_flow.sh').readAsStringSync();

    expect(script, contains('GADApplicationIdentifier'));
    expect(script, contains('ca-app-pub-3940256099942544~1458002511'));
    expect(script, contains('runner_plist_backup'));
    expect(script, contains('cp -p'));
    expect(script, contains('PlistBuddy'));
    expect(script, contains('restore_runner_plist'));
    expect(script, contains("trap 'on_exit \"\$?\"' EXIT"));
    expect(script, contains(r'''rm -f -- "$runner_plist_backup"'''));
    expect(script, isNot(contains('3753374909078516~3814311401')));
    expect(script, isNot(contains(r'''echo "$E2E_ADMOB_TEST_APP_ID"''')));
    expect(
        script, isNot(contains(r'''printf '%s\n' "$E2E_ADMOB_TEST_APP_ID"''')));
  });
}
