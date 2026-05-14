import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  group('NotificationService', () {
    test('uses exact scheduling when exact alarm permission is available', () {
      final mode = NotificationService.reminderScheduleModeForStatus(
        const NotificationPermissionStatus(
          notificationsEnabled: true,
          exactAlarmsEnabled: true,
          fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
        ),
      );

      expect(mode, AndroidScheduleMode.exactAllowWhileIdle);
    });

    test('falls back to inexact scheduling when exact permission is off', () {
      final mode = NotificationService.reminderScheduleModeForStatus(
        const NotificationPermissionStatus(
          notificationsEnabled: true,
          exactAlarmsEnabled: false,
          fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
        ),
      );

      expect(mode, AndroidScheduleMode.inexactAllowWhileIdle);
    });

    test('uses exact scheduling for unknown exact permission on non-Android',
        () {
      final mode = NotificationService.reminderScheduleModeForStatus(
        const NotificationPermissionStatus(
          notificationsEnabled: null,
          exactAlarmsEnabled: null,
          fullScreenIntentStatus: PermissionCheckState.unsupported,
        ),
      );

      expect(mode, AndroidScheduleMode.exactAllowWhileIdle);
    });
  });
}
