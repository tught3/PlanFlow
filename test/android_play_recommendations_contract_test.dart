import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  test('tablet and phone orientation boundary stays on smallestScreenWidthDp',
      () {
    final mainActivity = File(
      '$root/android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    ).readAsStringSync();

    expect(mainActivity, contains('smallestScreenWidthDp >= 600'));
    expect(
      mainActivity,
      contains('WindowCompat.setDecorFitsSystemWindows(window, false)'),
    );
    expect(
      mainActivity,
      contains('ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED'),
    );
    expect(
      mainActivity,
      contains('ActivityInfo.SCREEN_ORIENTATION_PORTRAIT'),
    );
  });

  test('release build keeps resource shrinking enabled', () {
    final buildGradle = File(
      '$root/android/app/build.gradle.kts',
    ).readAsStringSync();

    expect(buildGradle, contains('release {'));
    expect(buildGradle, contains('isMinifyEnabled = true'));
    expect(buildGradle, contains('isShrinkResources = true'));
  });

  test('notification keep.xml preserves ic_stat_planflow', () {
    final keepXml = File(
      '$root/android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();

    expect(keepXml, contains('tools:keep="@drawable/ic_stat_planflow"'));
    expect(keepXml, contains('ic_stat_planflow'));
  });

  test('orientation policy is owned by the Android smallest-width boundary',
      () {
    final mainDart = File('$root/lib/main.dart').readAsStringSync();

    expect(mainDart, contains('SystemUiMode.edgeToEdge'));
    expect(mainDart, isNot(contains('setPreferredOrientations')));
    expect(mainDart, isNot(contains('DeviceOrientation.landscape')));
  });
}
