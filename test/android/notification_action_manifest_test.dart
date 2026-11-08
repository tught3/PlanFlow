import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background notification actions have one internal Android receiver',
      () {
    final xml =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final receivers = RegExp(
            r'<receiver\b[^>]*android:name="com\.dexterous\.flutterlocalnotifications\.ActionBroadcastReceiver"[^>]*/>')
        .allMatches(xml)
        .toList();
    expect(receivers, hasLength(1));
    expect(receivers.single.group(0), contains('android:exported="false"'));
  });
}
