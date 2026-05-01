import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';

void main() {
  test('TravelTimeBufferService prefers coordinates when both signals exist',
      () {
    const service = TravelTimeBufferService();

    final estimate = service.estimate(
      latitude: 37.5665,
      longitude: 126.978,
      locationText: 'Seoul Station',
    );

    expect(estimate.source, TravelTimeBufferSource.coordinates);
    expect(estimate.minutes, greaterThan(0));
  });

  test(
      'TravelTimeBufferService uses text heuristic when coordinates are absent',
      () {
    const service = TravelTimeBufferService();

    final estimate =
        service.estimate(locationText: 'Incheon Airport Terminal 2');

    expect(estimate.source, TravelTimeBufferSource.locationText);
    expect(estimate.minutes, inInclusiveRange(10, 75));
  });

  test('TravelTimeBufferService falls back to a stable default buffer', () {
    const service = TravelTimeBufferService();

    final estimate = service.estimate();

    expect(estimate.source, TravelTimeBufferSource.defaultFallback);
    expect(estimate.buffer, const Duration(minutes: 15));
  });
}
