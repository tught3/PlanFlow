import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readProjectFile(String relativePath) {
    return File(
      '${Directory.current.path}${Platform.pathSeparator}$relativePath',
    ).readAsStringSync();
  }

  test('startup explicitly enables edge-to-edge and leaves orientation to Android', () {
    final main = readProjectFile('lib/main.dart');
    final edgeToEdge = main.indexOf(
      'await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);',
    );

    expect(edgeToEdge, greaterThanOrEqualTo(0));
    expect(main, isNot(contains('SystemChrome.setPreferredOrientations')));
  });

  test('MainActivity keeps phones portrait-only and permits tablet rotation', () {
    final mainActivity = readProjectFile(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    );

    expect(
      RegExp(
        r'smallestScreenWidthDp\s*<\s*600[\s\S]*?'
        r'SCREEN_ORIENTATION_PORTRAIT[\s\S]*?'
        r'SCREEN_ORIENTATION_UNSPECIFIED',
      ).hasMatch(mainActivity),
      isTrue,
    );
    expect(
      RegExp(
        r'override fun onCreate\(savedInstanceState: Bundle\?\)[\s\S]*?'
        r'updateRequestedOrientation\(\)',
      ).hasMatch(mainActivity),
      isTrue,
    );
  });

  test('location requests use cancellable current-location API only', () {
    final mainActivity = readProjectFile(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    );

    expect(mainActivity, contains('LocationManagerCompat.getCurrentLocation'));
    expect(mainActivity, contains('CancellationSignal'));
    expect(mainActivity, isNot(contains('requestSingleUpdate')));
    expect(mainActivity, isNot(contains('onStatusChanged')));
  });

  test('release build shrinks code and resources with optimized defaults', () {
    final gradle = readProjectFile('android/app/build.gradle.kts');

    expect(
      RegExp(
        r'release\s*\{[\s\S]*?isMinifyEnabled\s*=\s*true[\s\S]*?'
        r'isShrinkResources\s*=\s*true[\s\S]*?'
        r'getDefaultProguardFile\("proguard-android-optimize\.txt"\)',
      ).hasMatch(gradle),
      isTrue,
    );
  });

  test('resource shrinking preserves the dynamically addressed notification icon', () {
    final keep = readProjectFile('android/app/src/main/res/raw/keep.xml');

    expect(keep, contains('tools:keep="@drawable/ic_stat_planflow"'));
  });

  test('manifest permits resizable tablets without orientation restrictions', () {
    final manifest = readProjectFile('android/app/src/main/AndroidManifest.xml');
    final activity = RegExp(
      r'<activity\s+android:name="\.MainActivity"[\s\S]*?</activity>',
    ).firstMatch(manifest)?.group(0);

    expect(activity, isNotNull);
    expect(activity, contains('android:resizeableActivity="true"'));
    expect(activity, isNot(contains('android:screenOrientation')));
    expect(activity, isNot(contains('|orientation')));
  });

  test('MainActivity does not add unapproved BitmapFactory decoding', () {
    final mainActivity = readProjectFile(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    );

    expect(mainActivity, isNot(contains('BitmapFactory.decode')));
  });
}
