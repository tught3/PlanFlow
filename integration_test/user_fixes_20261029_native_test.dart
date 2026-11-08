// Offline native verification of the real screens and real Android notification
// manager. Uses synthetic local IDs only; never creates a backend event.
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/services/notification_service.dart';
import '../test/screens/confirm_screen_test.dart' as confirm_tests;
import '../test/screens/event_location_coordinate_test.dart'
    as coordinate_tests;
import '../test/services/notification_action_dismissal_test.dart'
    as action_fakes;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  confirm_tests.registerConfirmScreenGuideSaveStageTests();
  coordinate_tests.main();
  testWidgets(
      'native Android exact-id acknowledgement dismisses ringing notification only',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.android);
    const alarmId = 701501;
    const unrelatedId = 701502;
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
        settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_stat_planflow')));
    try {
      await plugin.show(
          id: unrelatedId,
          title: 'QA unrelated event',
          body: 'Must remain after the other event is acknowledged',
          notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                  'planflow_ack_validation_quiet_v1',
                  'QA unrelated notification',
                  playSound: false,
                  enableVibration: false)));
      await plugin.show(
          id: alarmId,
          title: 'QA strong departure alarm',
          body: 'Synthetic local alarm, cancelled by the real action handler',
          payload: 'event:qa-native-ack:critical',
          notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                  'planflow_ack_validation_ringing_v1',
                  'QA alarm cancellation validation',
                  importance: Importance.max,
                  priority: Priority.max,
                  category: AndroidNotificationCategory.alarm,
                  audioAttributesUsage: AudioAttributesUsage.alarm,
                  playSound: true,
                  enableVibration: true,
                  ongoing: true,
                  autoCancel: false,
                  additionalFlags: Int32List.fromList(<int>[4]))));
      final before =
          (await plugin.getActiveNotifications()).map((n) => n.id).toSet();
      expect(before, containsAll(<int>[alarmId, unrelatedId]),
          reason:
              'Both notifications must really be posted before cancellation');
      // Use a fresh service, not an initialized singleton. This is the same
      // production handler used by Android's foreground/background callbacks.
      final service =
          NotificationService(plugin: plugin, allowPermissionRequests: false);
      final response = const NotificationResponse(
          id: alarmId,
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: NotificationService.criticalAcknowledgedActionId,
          payload: 'event:qa-native-ack:critical');
      await handleNotificationResponseAction(response,
          notificationService: service,
          eventRepository: action_fakes.ActionEvents(),
          criticalAlarmAcknowledgementStore: action_fakes.ActionAck());
      final after =
          (await plugin.getActiveNotifications()).map((n) => n.id).toSet();
      expect(after, isNot(contains(alarmId)));
      expect(after, contains(unrelatedId));
      await handleNotificationResponseAction(response,
          notificationService: service,
          eventRepository: action_fakes.ActionEvents(),
          criticalAlarmAcknowledgementStore: action_fakes.ActionAck());
      expect((await plugin.getActiveNotifications()).map((n) => n.id),
          contains(unrelatedId));
      binding.reportData = <String, dynamic>{
        ...?binding.reportData,
        'notificationCancellation': <String, dynamic>{
          'before': before.toList(),
          'after': after.toList(),
          'exactNotificationRemoved': !after.contains(alarmId),
          'unrelatedNotificationRetained': after.contains(unrelatedId),
          'audioMechanism':
              'Android NotificationManager cancellation of an insistent notification',
          'backgroundIsolateOrShadeTapVerified': false,
        },
      };
    } finally {
      await plugin.cancel(id: alarmId);
      await plugin.cancel(id: unrelatedId);
    }
  });
}
