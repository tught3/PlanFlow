import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';

void main() {
  test('schedules departure alarm from live route estimate plus safety margin',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '성심당',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isTrue);
    expect(result.travelMinutes, 90);
    expect(result.notifyAt, DateTime(2026, 5, 8, 10));
    expect(notifications.titles.single, '지금 출발 준비');
    expect(notifications.bodies.single, contains('대전 성심당'));
    expect(notifications.bodies.single, contains('90분'));
    expect(notifications.payloads.single, 'departure:event-1');
  });

  test('skips events without geocoded destination', () async {
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      notificationService: _FakeNotificationService(),
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '성심당',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isFalse);
    expect(result.skippedReason, 'missing_destination');
  });
}

class _FakeTravelTimeBufferService extends TravelTimeBufferService {
  _FakeTravelTimeBufferService({required this.routeEstimate});

  final TravelTimeBufferEstimate routeEstimate;

  @override
  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
  }) async {
    return routeEstimate;
  }
}

class _FakeNotificationService extends NotificationService {
  final titles = <String>[];
  final bodies = <String>[];
  final payloads = <String?>[];

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    titles.add(title);
    bodies.add(body);
    payloads.add(payload);
  }
}
