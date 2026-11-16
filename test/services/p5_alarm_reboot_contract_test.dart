import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/services/alarm_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a past briefing is skipped after reboot', () {
    final now = DateTime.utc(2026, 11, 12, 1);
    expect(
      isBriefingAlarmStale(
        now,
        now.subtract(const Duration(hours: 3)).toIso8601String(),
      ),
      isTrue,
    );
    expect(
      isBriefingAlarmStale(
        now,
        now.subtract(const Duration(minutes: 14)).toIso8601String(),
      ),
      isFalse,
    );
    expect(isBriefingAlarmStale(now, null), isFalse);
  });

  test('cancels legacy ids and eight local dates for all three alarm kinds',
      () async {
    SharedPreferences.setMockInitialValues({});
    final notifications = _CancellationNotificationService();
    final before = planflowLocal(DateTime.now());
    await notifications.cancelEventNotifications('series');
    final after = planflowLocal(DateTime.now());

    Set<int> expectedIds(DateTime day) {
      String suffix(int offset) {
        final date = DateTime(day.year, day.month, day.day + offset);
        return date.toIso8601String().substring(0, 10).replaceAll('-', '');
      }

      return {
        for (final kind in const ['push', 'critical', 'departure']) ...[
          notifications.notificationIdFor('series:$kind'),
          for (var offset = 0; offset < 8; offset++)
            notifications.notificationIdFor('series:$kind:${suffix(offset)}'),
        ],
      };
    }

    expect(
      notifications.cancelled,
      anyOf(equals(expectedIds(before)), equals(expectedIds(after))),
    );
  });

  test('every alarm-manager one-shot explicitly reschedules on reboot', () {
    const files = [
      'alarm_service.dart',
      'calendar_auto_sync_service.dart',
      'critical_alarm_preflight_service.dart',
      'departure_alarm_service.dart',
    ];
    for (final file in files) {
      final source = File('lib/services/$file').readAsStringSync();
      final calls = 'AndroidAlarmManager.oneShotAt('.allMatches(source).length;
      expect(calls, isPositive, reason: file);
      expect('rescheduleOnReboot: true'.allMatches(source).length, calls,
          reason: file);
    }
  });
}

class _CancellationNotificationService extends NotificationService {
  final cancelled = <int>{};

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<void> cancelSmartPreparationAlarms(String eventId) async {}

  @override
  Future<void> cancelPreActionAlarms(String eventId) async {}
}
