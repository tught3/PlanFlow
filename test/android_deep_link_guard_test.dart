import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainActivity prevents planflow deep links from becoming initial route',
      () {
    final mainActivity = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    ).readAsStringSync();

    expect(mainActivity, contains('override fun getInitialRoute()'));
    expect(mainActivity, contains('data?.scheme == "planflow"'));
    expect(mainActivity, contains('return "/"'));
    expect(mainActivity, contains('super.getInitialRoute() ?: "/"'));
  });

  test('Flutter deep linking stays disabled for custom planflow scheme', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(manifest, contains('flutter_deeplinking_enabled'));
    expect(manifest, contains('android:value="false"'));
    expect(manifest, contains('android:scheme="planflow"'));
  });
}
