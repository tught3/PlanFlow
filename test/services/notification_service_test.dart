import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  group('NotificationService', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('planflow/android_settings'),
        null,
      );
    });

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
            fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
          ),
          requestResult: null,
        ),
        isTrue,
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

    test('opens the exact critical alarm notification channel settings',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('planflow/android_settings'),
        (call) async {
          capturedCall = call;
          return true;
        },
      );

      final opened =
          await NotificationService().openCriticalAlarmChannelSettings();

      expect(opened, isTrue);
      expect(capturedCall?.method, 'openNotificationChannelSettings');
      expect(
        capturedCall?.arguments,
        <String, Object?>{
          'channelId': NotificationService.criticalAlarmChannelId,
        },
      );
    });

    test('routes departure notification action and body tap separately', () {
      final tappedDeparture = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'departure:event-1',
      );
      final acknowledgedDeparture = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationService.departureAcknowledgedActionId,
        payload: 'departure:event-1',
      );

      expect(
        NotificationService.routeForNotificationResponse(tappedDeparture),
        '${AppRoutes.departureAlarm}?eventId=event-1',
      );
      expect(
        NotificationService.routeForNotificationResponse(acknowledgedDeparture),
        isNull,
      );
    });

    test('important alarm actions either open the event or schedule tomorrow',
        () async {
      final acknowledged = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationService.criticalAcknowledgedActionId,
        payload: 'event:event-1',
      );
      final tomorrow = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationService.criticalRemindTomorrowActionId,
        payload: 'event:event-1',
      );
      final notifications = _FakeNotificationService();

      expect(
        NotificationService.routeForNotificationResponse(acknowledged),
        '${AppRoutes.eventDetail}/event-1',
      );
      expect(
        NotificationService.routeForNotificationResponse(tomorrow),
        isNull,
      );

      await handleNotificationResponseAction(
        tomorrow,
        notificationService: notifications,
      );
      expect(notifications.remindTomorrowEventId, 'event-1');
    });

    test('important alarm tomorrow reminder is scheduled for 9 AM next day',
        () {
      expect(
        NotificationService.nextCriticalReminderAt(DateTime(2026, 7, 16, 22)),
        DateTime(2026, 7, 17, 9),
      );
    });

    test('important alarm defines confirm and tomorrow actions', () {
      final source =
          File('lib/services/notification_service.dart').readAsStringSync(
        encoding: utf8,
      );

      expect(source, contains("'확인'"));
      expect(source, contains("'내일 오전 9시'"));
      expect(source, contains('criticalRemindTomorrowActionId'));
    });

    test('departure notification has only the departure action', () {
      final source =
          File('lib/services/notification_service.dart').readAsStringSync(
        encoding: utf8,
      );

      expect(source, contains("'출발'"));
      expect(source, isNot(contains("'도착'")));
      expect(source, isNot(contains('departureArrivedActionId')));
      expect(source, contains('showsUserInterface: false'));
    });

    test('departure notification strings do not contain mojibake', () {
      final source = <String>[
        'lib/services/notification_service.dart',
        'lib/services/departure_alarm_service.dart',
        'lib/services/smart_preparation_alarm_service.dart',
      ].map((path) => File(path).readAsStringSync(encoding: utf8)).join('\n');

      expect(
        source,
        isNot(matches(RegExp(r'吏|湲|異|쒕|쇱|덉|볦|튂|以묒|뚮|媛|諛|�'))),
      );
      expect(source, contains('이미 지난 출발 알림은 예약하지 않았습니다.'));
      expect(source, contains('놓치면 안 되는 중요 알림'));
    });
  });
}

class _FakeNotificationService extends NotificationService {
  String? remindTomorrowEventId;

  @override
  Future<NotificationScheduleResult> scheduleCriticalReminderTomorrow({
    required String eventId,
    DateTime? now,
  }) async {
    remindTomorrowEventId = eventId;
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: now ?? DateTime.now(),
    );
  }
}
