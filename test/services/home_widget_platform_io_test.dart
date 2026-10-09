import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/home_widget_platform_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('home_widget');
  final calls = <Map<Object?, Object?>>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveWidgetData') {
        calls.add((call.arguments as Map).cast<Object?, Object?>());
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Map<Object?, Object?> lastSaved() => calls.last;

  test('iOS nullable widget values are native property-list safe', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final platform = createHomeWidgetPlatformImpl();

    await platform.saveWidgetData('next_event_id', null);
    expect(lastSaved()['data'], '');

    await platform.saveWidgetData('next_event_travel_buffer_minutes', null);
    expect(lastSaved()['data'], 0);

    await platform.saveWidgetData('next_event_start_at', null);
    expect(lastSaved()['data'], '');

    // Group calendar optional names use this same bridge and must clear rather
    // than aborting a later native write with NSNull.
    await platform.saveWidgetData('gw_123_name', null);
    expect(lastSaved()['data'], '');

    await platform.saveWidgetData('next_event_id', 'event-123');
    expect(lastSaved()['data'], 'event-123');
    expect(calls, hasLength(5));
  });

  test('Android null keeps the plugin removal contract', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = createHomeWidgetPlatformImpl();

    await platform.saveWidgetData('next_event_id', null);

    expect(lastSaved()['data'], isNull);
    expect(lastSaved()['id'], 'next_event_id');
  });
}
