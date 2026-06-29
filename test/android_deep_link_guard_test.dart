import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainActivity keeps custom scheme deep links out of Flutter initialRoute',
      () {
    final source = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('override fun getInitialRoute(): String'));
    expect(source, contains('intent?.data'));
    expect(source, contains('data?.scheme == "planflow"'));
    expect(source, contains('return "/"'));
    expect(source, contains('return super.getInitialRoute() ?: "/"'));
  });

  test('Flutter automatic deeplink routing remains disabled in manifest', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(manifest, contains('flutter_deeplinking_enabled'));
    expect(manifest, contains('android:value="false"'));
  });
}
