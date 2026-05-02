import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';

void main() {
  test('HomeWidgetService updates next-event widget payload', () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateNextEvent(
      title: 'Team sync',
      eventId: 'event-1',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      location: 'Seoul Station',
      travelBufferMinutes: 25,
      isCritical: true,
      upcomingEvents: <HomeWidgetListEventData>[
        HomeWidgetListEventData(
          title: 'Team sync',
          startAt: DateTime.parse('2026-05-01T09:00:00Z'),
          location: 'Seoul Station',
        ),
        HomeWidgetListEventData(
          title: 'Design review',
          startAt: DateTime.parse('2026-05-01T11:00:00Z'),
        ),
      ],
      widgetName: 'next_event_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Team sync');
    expect(platform.savedValues['next_event_id'], 'event-1');
    expect(platform.savedValues['next_event_start_at'],
        '2026-05-01T09:00:00.000Z');
    expect(platform.savedValues['next_event_location'], 'Seoul Station');
    expect(platform.savedValues['next_event_travel_buffer_minutes'], 25);
    expect(platform.savedValues['next_event_is_critical'], isTrue);
    expect(platform.savedValues['event_list_1_title'], 'Team sync');
    expect(
        platform.savedValues['event_list_1_time'], '2026-05-01T09:00:00.000Z');
    expect(platform.savedValues['event_list_1_location'], 'Seoul Station');
    expect(platform.savedValues['event_list_2_title'], 'Design review');
    expect(platform.savedValues['event_list_3_title'], isNull);
    expect(platform.updatedWidgets.single, 'next_event_widget');
  });

  test('HomeWidgetService returns false when the platform is unsupported',
      () async {
    final platform = _FakeHomeWidgetPlatform(supported: false);
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateNextEvent(
      title: 'Team sync',
      widgetName: 'next_event_widget',
    );

    expect(success, isFalse);
    expect(platform.savedValues, isEmpty);
    expect(platform.updatedWidgets, isEmpty);
  });

  test('HomeWidgetService clears optional fields to avoid stale widget data',
      () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    await service.updateNextEvent(
      title: 'First event',
      eventId: 'event-1',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      location: 'Seoul Station',
      travelBufferMinutes: 25,
      widgetName: 'next_event_widget',
    );

    final success = await service.updateNextEvent(
      title: 'Second event',
      eventId: '',
      location: '',
      widgetName: 'next_event_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Second event');
    expect(platform.savedValues['next_event_id'], '');
    expect(platform.savedValues['next_event_start_at'], isNull);
    expect(platform.savedValues['next_event_location'], '');
    expect(platform.savedValues['next_event_travel_buffer_minutes'], 15);
  });
}

class _FakeHomeWidgetPlatform extends HomeWidgetPlatform {
  _FakeHomeWidgetPlatform({this.supported = true});

  final bool supported;
  final Map<String, Object?> savedValues = <String, Object?>{};
  final List<String> updatedWidgets = <String>[];
  String? appGroupId;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    if (!supported) {
      return false;
    }

    savedValues[id] = data;
    return true;
  }

  @override
  Future<bool> setAppGroupId(String groupId) async {
    if (!supported) {
      return false;
    }

    appGroupId = groupId;
    return true;
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (!supported) {
      return false;
    }

    updatedWidgets.add(name ?? '');
    return true;
  }
}
