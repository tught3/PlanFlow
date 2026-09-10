import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/app_permission_service.dart';

void main() {
  final root = Directory.current.path;
  final onboarding = File(
    '$root/lib/screens/onboarding/permission_onboarding_screen.dart',
  );
  final permissions = File('$root/lib/services/app_permission_service.dart');
  final notifications = File('$root/lib/services/notification_service.dart');
  final appDelegate = File('$root/ios/Runner/AppDelegate.swift');
  final infoPlist = File('$root/ios/Runner/Info.plist');

  test('maps every iOS native terminal response without treating it as granted',
      () {
    expect(
        AppPermissionStatus.fromNative('granted'), AppPermissionStatus.granted);
    expect(
        AppPermissionStatus.fromNative('denied'), AppPermissionStatus.denied);
    expect(AppPermissionStatus.fromNative('settingsRequired'),
        AppPermissionStatus.settingsRequired);
    expect(AppPermissionStatus.fromNative('restricted'),
        AppPermissionStatus.restricted);
    expect(
        AppPermissionStatus.fromNative('timeout'), AppPermissionStatus.timeout);
    expect(AppPermissionStatus.fromNative('unexpected'),
        AppPermissionStatus.error);
  });

  test('keeps the iOS onboarding path target-specific and ordered', () {
    final source = onboarding.readAsStringSync();
    final iosStart =
        source.indexOf('if (defaultTargetPlatform == TargetPlatform.iOS) {');
    final iosReturn = source.indexOf('return <_PermissionStep>[', iosStart);
    final iosSteps = source.substring(
      iosReturn,
      source.indexOf('return <_PermissionStep>[', iosReturn + 1),
    );

    final microphone = iosSteps.indexOf("key: 'microphone'");
    final speech = iosSteps.indexOf("key: 'speechRecognition'");
    final notification = iosSteps.indexOf("key: 'notification'");
    final location = iosSteps.indexOf("key: 'location'");
    final calendar = iosSteps.indexOf("key: 'calendar'");
    expect(
        <int>[microphone, speech, notification, location, calendar]
            .every((index) => index >= 0),
        isTrue);
    expect(
        microphone < speech &&
            speech < notification &&
            notification < location &&
            location < calendar,
        isTrue);

    expect(source,
        contains('if (defaultTargetPlatform != TargetPlatform.iOS) ...['));
    expect(source, contains('snapshot.speechRecognitionGranted'));
    expect(source, contains('isIosTerminalStatus(status)'));
    expect(source, contains('shouldResumeAfterSettings'));
  });

  test('binds real iOS permission APIs and all required purpose strings', () {
    final permissionSource = permissions.readAsStringSync();
    final notificationSource = notifications.readAsStringSync();
    final delegateSource = appDelegate.readAsStringSync();
    final plist = infoPlist.readAsStringSync();

    expect(permissionSource,
        contains("MethodChannel('planflow/ios_permissions')"));
    expect(permissionSource, contains(".timeout(const Duration(seconds: 12))"));
    expect(
        notificationSource, contains('IOSFlutterLocalNotificationsPlugin>()'));
    expect(notificationSource, contains('await ios?.checkPermissions()'));
    expect(notificationSource, contains('requestAlertPermission: false'));
    expect(delegateSource, contains('PlanFlowPermissionChannel.register'));
    expect(delegateSource, contains('requestRecordPermission'));
    expect(delegateSource, contains('SFSpeechRecognizer.requestAuthorization'));
    expect(delegateSource, contains('requestWhenInUseAuthorization'));
    expect(delegateSource, contains('requestFullAccessToEvents'));
    expect(delegateSource, contains('openSettingsURLString'));
    for (final key in <String>[
      'NSMicrophoneUsageDescription',
      'NSSpeechRecognitionUsageDescription',
      'NSLocationWhenInUseUsageDescription',
      'NSCalendarsUsageDescription',
      'NSCalendarsFullAccessUsageDescription',
    ]) {
      expect(plist, contains('<key>$key</key>'));
    }
  });
}
