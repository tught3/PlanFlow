import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    calls.clear();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mockPlugin({
    required bool requestResult,
    required bool statusResult,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'requestPermissions':
          return requestResult;
        case 'checkPermissions':
          return <String, Object>{'isEnabled': statusResult};
        default:
          return null;
      }
    });
  }

  test('reports an iOS notification permission that is already granted',
      () async {
    mockPlugin(requestResult: true, statusResult: true);

    final status = await NotificationService().checkPermissionStatus();

    expect(status.notificationsEnabled, isTrue);
    expect(calls.map((call) => call.method), <String>[
      'initialize',
      'checkPermissions',
    ]);
  });

  test('returns the explicit granted request result without another prompt',
      () async {
    mockPlugin(requestResult: true, statusResult: true);

    final granted = await NotificationService().requestNotificationPermission();

    expect(granted, isTrue);
    expect(calls.map((call) => call.method), <String>[
      'initialize',
      'requestPermissions',
    ]);
  });

  test('returns false when the iOS notification request is denied', () async {
    mockPlugin(requestResult: false, statusResult: false);

    final granted = await NotificationService().requestNotificationPermission();

    expect(granted, isFalse);
    expect(calls.map((call) => call.method), <String>[
      'initialize',
      'requestPermissions',
    ]);
  });

  test('does not request iOS notification permission during initialization',
      () async {
    mockPlugin(requestResult: true, statusResult: true);

    await NotificationService().initialize();

    expect(calls.map((call) => call.method), <String>['initialize']);
    final initialize = calls.single;
    final settings = initialize.arguments as Map<dynamic, dynamic>;
    expect(settings['requestAlertPermission'], isFalse);
    expect(settings['requestBadgePermission'], isFalse);
    expect(settings['requestSoundPermission'], isFalse);
  });
}
