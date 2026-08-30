import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');

  test('canonical iOS identity is consistent across native and Dart config',
      () {
    const runnerBundle = 'com.fluxstudio.planflow';
    const widgetBundle = '$runnerBundle.PlanFlowWidget';
    const appGroup = 'group.com.fluxstudio.planflow';

    final identity =
        file('ios/Flutter/PlanFlow-Identity.xcconfig').readAsStringSync();
    final project =
        file('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final firebase = file('lib/firebase_options.dart').readAsStringSync();
    final runnerInfo = file('ios/Runner/Info.plist').readAsStringSync();
    final widgetInfo = file('ios/PlanFlowWidget/Info.plist').readAsStringSync();
    final runnerEntitlements =
        file('ios/Runner/PlanFlow.entitlements').readAsStringSync();
    final widgetEntitlements =
        file('ios/PlanFlowWidget/PlanFlowWidget.entitlements')
            .readAsStringSync();

    expect(identity, contains('PLANFLOW_IOS_BUNDLE_ID = $runnerBundle'));
    expect(identity, contains('PLANFLOW_IOS_APP_GROUP = $appGroup'));
    expect(project,
        contains(r'PRODUCT_BUNDLE_IDENTIFIER = "$(PLANFLOW_IOS_BUNDLE_ID)"'));
    expect(
        project,
        contains(
            r'PRODUCT_BUNDLE_IDENTIFIER = "$(PLANFLOW_IOS_WIDGET_BUNDLE_ID)"'));
    expect(firebase, contains("iosBundleId: '$runnerBundle'"));
    expect(runnerInfo, contains('<string>planflow</string>'));
    expect(widgetInfo, contains(r'$(PLANFLOW_IOS_APP_GROUP)'));
    expect(runnerEntitlements, contains(r'$(PLANFLOW_IOS_APP_GROUP)'));
    expect(widgetEntitlements, contains(r'$(PLANFLOW_IOS_APP_GROUP)'));
    expect(file('ios/Runner/GoogleService-Info.plist').existsSync(), isFalse);
    expect(widgetBundle, endsWith('.PlanFlowWidget'));
  });

  test('Firebase validation is fail-closed and never commits the real plist',
      () {
    final script =
        file('scripts/verify-ios-firebase-config.sh').readAsStringSync();
    expect(script, contains('BLOCKED_FIREBASE_CONFIG'));
    expect(script, contains('PROJECT_ID'));
    expect(script, contains('BUNDLE_ID'));
    expect(script, contains('GOOGLE_APP_ID'));
    expect(script, contains('plutil -lint'));
    expect(script, contains(r'^1:[0-9]+:ios:[A-Za-z0-9_-]+$'));
    expect(script, contains('expected_project="planflow-27fd8"'));
    expect(script, contains('expected_bundle="com.fluxstudio.planflow"'));
    expect(script, isNot(contains('PLANFLOW_FIREBASE_PROJECT_ID')));
    expect(script, isNot(contains('PLANFLOW_IOS_BUNDLE_ID')));
    expect(script, isNot(contains('AIza')));
    expect(file('ios/Runner/GoogleService-Info.plist').existsSync(), isFalse);
    final fixtures =
        file('scripts/test-verify-ios-firebase-config.sh').readAsStringSync();
    expect(fixtures,
        contains('SKIP: Firebase plist fixture tests require macOS plutil'));
    expect(fixtures, contains('missing.plist'));
    expect(fixtures, contains('malformed.plist'));
    expect(fixtures, contains('valid.plist'));
  });
}
