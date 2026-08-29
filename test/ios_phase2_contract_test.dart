import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/notification_route_contract.dart';
import 'package:planflow/services/widget_schedule_contract.dart';

void main() {
  test('widget payload round-trips the canonical fields', () {
    final event = WidgetScheduleEvent(
      id: 'e1',
      title: '회의',
      start: DateTime.utc(2026, 9, 1, 9),
      end: DateTime.utc(2026, 9, 1, 10),
      important: true,
      continuous: false,
      recurring: true,
      team: true,
      displayColor: '#6750A4',
      route: '/event/detail/e1',
    );
    final payload = WidgetSchedulePayload(
      schemaVersion: WidgetSchedulePayload.currentSchemaVersion,
      generatedAt: DateTime.utc(2026, 8, 29),
      events: [event],
      dayCounts: const {'2026-09-01': 1},
      holidays: const ['2026-09-03'],
    );
    final restored = WidgetSchedulePayload.decode(payload.encode());
    expect(restored.schemaVersion, 1);
    expect(restored.events.single.toJson(), event.toJson());
    expect(restored.dayCounts['2026-09-01'], 1);
  });

  test('legacy widget events can be dual-written as canonical JSON', () {
    final payload = WidgetSchedulePayload.fromLegacyRawEvents(
      rawEvents: [
        {
          'id': 'e2',
          'title': '팀 회의',
          'start_at': '2026-09-01T09:00:00.000Z',
          'end_at': '2026-09-01T10:00:00.000Z',
          'is_critical': false,
          'is_multi_day': false,
          'is_recurring': true,
          'is_team': true,
        },
      ],
      generatedAt: DateTime.utc(2026, 8, 29),
    );
    expect(payload.events.single.displayColor, '#7B560B');
    expect(payload.events.single.route, 'planflow://schedule/e2');
  });

  test('notification routes preserve existing scheme and map new routes', () {
    final date = DateTime.now().add(const Duration(days: 1));
    final dateText = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    expect(
        NotificationRouteContract.canonicalPath(
          NotificationRouteContract.schedule('a b'),
        ),
        '/event/detail/a b');
    expect(NotificationRouteContract.schedule('e1').toString(),
        'planflow://schedule/e1');
    expect(
        NotificationRouteContract.canonicalPath(
          NotificationRouteContract.day(date),
        ),
        '/calendar?date=$dateText');
    expect(
      NotificationRouteContract.day(date).toString(),
      'planflow://day/$dateText',
    );
    expect(
        NotificationRouteContract.canonicalPath(
          Uri.parse('planflow://voice-launcher'),
        ),
        isNull);
  });
}
