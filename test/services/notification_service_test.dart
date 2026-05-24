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

    test('critical alarms fall back to inexact when exact permission is off',
        () {
      final mode = NotificationService.criticalAlarmScheduleModeForStatus(
        const NotificationPermissionStatus(
          notificationsEnabled: true,
          exactAlarmsEnabled: false,
          fullScreenIntentStatus: PermissionCheckState.denied,
        ),
      );

      expect(mode, AndroidScheduleMode.inexactAllowWhileIdle);
    });

    test('critical alarms use exact scheduling when permission is available',
        () {
      final mode = NotificationService.criticalAlarmScheduleModeForStatus(
        const NotificationPermissionStatus(
          notificationsEnabled: true,
          exactAlarmsEnabled: true,
          fullScreenIntentStatus: PermissionCheckState.granted,
        ),
      );

      expect(mode, AndroidScheduleMode.exactAllowWhileIdle);
    });

    test('critical alarms only attach full-screen intent when allowed', () {
      expect(
        NotificationService.shouldUseCriticalFullScreenIntent(
          status: const NotificationPermissionStatus(
            notificationsEnabled: true,
            exactAlarmsEnabled: true,
            fullScreenIntentStatus: PermissionCheckState.denied,
          ),
          requestResult: false,
        ),
        isFalse,
      );

      expect(
        NotificationService.shouldUseCriticalFullScreenIntent(
          status: const NotificationPermissionStatus(
            notificationsEnabled: true,
            exactAlarmsEnabled: true,
            fullScreenIntentStatus: PermissionCheckState.granted,
          ),
          requestResult: null,
        ),
        isTrue,
      );
    });

    test('formats critical alarm title so it is visibly distinct', () {
      expect(
        NotificationService.criticalAlarmDisplayTitle('팀장 동행방문'),
        '중요 알람: 팀장 동행방문',
      );
      expect(
        NotificationService.criticalAlarmDisplayTitle('중요 알람: 팀장 동행방문'),
        '중요 알람: 팀장 동행방문',
      );
    });

    test('formats critical alarm body with an urgent lead and event title', () {
      expect(
        NotificationService.criticalAlarmDisplayBody(
          title: '팀장 동행방문',
          body: '중요 일정이 곧 시작됩니다.',
        ),
        '중요 일정입니다. 지금 확인해 주세요.\n'
        '팀장 동행방문\n'
        '중요 일정이 곧 시작됩니다.\n'
        '알림을 누르면 해당 일정으로 이동합니다.',
      );
      expect(
        NotificationService.criticalAlarmDisplayBody(
          title: '성심당 출발',
          body: '대전 성심당까지 30분 걸립니다.',
        ),
        '중요 일정입니다. 지금 확인해 주세요.\n'
        '성심당 출발\n'
        '대전 성심당까지 30분 걸립니다.\n'
        '알림을 누르면 해당 일정으로 이동합니다.',
      );
    });

    test('uses the distinct critical alarm channel and sound', () {
      expect(
        NotificationService.criticalAlarmChannelId,
        'critical_alarms_v5_distinct',
      );
      expect(
        NotificationService.criticalAlarmSoundResource,
        'planflow_critical_alarm',
      );
    });
  });
}
