import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/app_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('planflow/ios_permissions');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void respondWith(Object? Function(String method) response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response(call.method);
    });
  }

  test('uses the native microphone status rather than an Android fallback',
      () async {
    respondWith((method) =>
        method == 'requestMicrophonePermission' ? 'granted' : 'denied');

    final granted = await AppPermissionService().requestMicrophonePermission();

    expect(granted, isTrue);
    expect(calls.single.method, 'requestMicrophonePermission');
  });

  test('keeps determined non-granted iOS statuses explicit', () async {
    respondWith((method) {
      switch (method) {
        case 'requestSpeechRecognitionPermission':
          return 'settingsRequired';
        case 'requestCalendarPermission':
          return 'restricted';
        default:
          return 'error';
      }
    });
    final service = AppPermissionService();

    final speech = await service.requestSpeechRecognitionPermissionStatus();
    final calendar = await service.requestCalendarPermissionStatus();

    expect(speech, AppPermissionStatus.settingsRequired);
    expect(calendar, AppPermissionStatus.restricted);
    expect(calls.map((call) => call.method), <String>[
      'requestSpeechRecognitionPermission',
      'requestCalendarPermission',
    ]);
  });

  test('turns a native exception into an explicit error state', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'native-error');
    });

    final status =
        await AppPermissionService().requestLocationPermissionStatus();

    expect(status, AppPermissionStatus.error);
  });
}
