import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/region_settings.dart';

void main() {
  setUp(() {
    PlanFlowRegionController.instance.reset();
  });

  test('planflowLocal maps UTC instants to fixed Korean wall time', () {
    final local = planflowLocal(DateTime.utc(2026, 5, 4, 15, 30));

    expect(local.year, 2026);
    expect(local.month, 5);
    expect(local.day, 5);
    expect(local.hour, 0);
    expect(local.minute, 30);
  });

  test('local wall time round-trips through UTC for the selected region', () {
    final utc = planflowLocalDateTimeToUtc(DateTime(2026, 5, 10, 10, 30));
    final local = planflowLocal(utc);

    expect(utc, DateTime.utc(2026, 5, 10, 1, 30));
    expect(local, DateTime(2026, 5, 10, 10, 30));
  });

  test('event day intersection treats end boundary as exclusive', () {
    final startAt = DateTime.utc(2026, 5, 4, 15);
    final endAt = DateTime.utc(2026, 5, 5, 15);

    expect(
      planflowEventIntersectsLocalDay(
        startAt: startAt,
        endAt: endAt,
        day: DateTime(2026, 5, 5),
      ),
      isTrue,
    );
    expect(
      planflowEventIntersectsLocalDay(
        startAt: startAt,
        endAt: endAt,
        day: DateTime(2026, 5, 6),
      ),
      isFalse,
    );
  });
}
