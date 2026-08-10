import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  test('RemoteViews widgets cannot launch Glance trampoline', () {
    final manifest = File(
      '$root/android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains(
        'androidx.glance.appwidget.action.ActionTrampolineActivity',
      ),
    );
    expect(manifest, contains('tools:node="remove"'));
  });

  test('Glance and Play Services Auth versions stay on safe pins', () {
    final build = File('$root/android/build.gradle.kts').readAsStringSync();
    expect(build, contains('androidx.glance:glance-appwidget:1.1.1'));
    expect(
      build,
      contains('com.google.android.gms:play-services-auth:21.5.1'),
    );
  });

  test('startup shell never starts interactive Google account picker', () {
    final shell =
        File('$root/lib/screens/shell_screen.dart').readAsStringSync();
    expect(shell, isNot(contains('syncGoogleCalendar(interactive: true)')));
    expect(shell, contains('interactive sign-in deferred'));

    final oauth = File(
      '$root/lib/services/oauth_callback_handler.dart',
    ).readAsStringSync();
    expect(oauth, isNot(contains('syncGoogleCalendar(interactive: true)')));
  });
}
