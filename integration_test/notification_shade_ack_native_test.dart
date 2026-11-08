// Host must tap the real System UI '확인(출발)' action after NATIVE_SHADE_READY.
// No handler injection: ActionBroadcastReceiver starts the production callback.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/services/critical_alarm_acknowledgement_store.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'actual shade action dismisses alarm and persists background acknowledgement',
      (tester) async {
    const targetId = 701511;
    const otherId = 701512;
    const eventId = 'qa-native-real-shade-action';
    const ack = SharedPreferencesCriticalAlarmAcknowledgementStore();
    final plugin = FlutterLocalNotificationsPlugin();
    final service =
        NotificationService(plugin: plugin, allowPermissionRequests: false);
    await service.initialize();
    await ack.clearAcknowledgement(eventId);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(
                child: Text(
                    'PlanFlow QA: real notification action validation')))));
    await tester.pump();
    try {
      await plugin.show(
          id: otherId,
          title: 'QA unrelated event - keep this',
          body: 'This notification must not be dismissed by the other event',
          notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                  'planflow_real_shade_quiet_v1', 'QA unrelated notification',
                  playSound: false, enableVibration: false)));
      await plugin.show(
          id: targetId,
          title: 'QA real departure alarm - confirm this',
          body: 'Tap 확인(출발) in the notification shade',
          payload: 'event:$eventId:critical',
          notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                  'planflow_real_shade_alarm_v1', 'QA real action validation',
                  importance: Importance.max,
                  priority: Priority.max,
                  category: AndroidNotificationCategory.alarm,
                  audioAttributesUsage: AudioAttributesUsage.alarm,
                  playSound: true,
                  enableVibration: true,
                  ongoing: true,
                  autoCancel: false,
                  additionalFlags: Int32List.fromList(<int>[4]),
                  actions: NotificationService.criticalActionsForTest)));
      final before =
          (await plugin.getActiveNotifications()).map((n) => n.id).toSet();
      expect(before, containsAll(<int>[targetId, otherId]));
      debugPrint('NATIVE_SHADE_READY target=$targetId other=$otherId');
      var success = false;
      Set<int?> after = <int?>{};
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (DateTime.now().isBefore(deadline)) {
          await (await SharedPreferences.getInstance()).reload();
          after =
              (await plugin.getActiveNotifications()).map((n) => n.id).toSet();
          final persisted = await ack.hasUnknownStartAcknowledgement(eventId);
          if (!after.contains(targetId) &&
              after.contains(otherId) &&
              persisted) {
            success = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      });
      expect(success, isTrue,
          reason:
              'Real shade action must invoke background Dart acknowledgement, '
              'not merely auto-dismiss the Android notification');
      binding.reportData = <String, dynamic>{
        'realShadeAction': <String, dynamic>{
          'before': before.toList(),
          'after': after.toList(),
          'targetRemoved': !after.contains(targetId),
          'otherNotificationRetained': after.contains(otherId),
          'backgroundAcknowledgementPersisted': success,
          'handlerCalledByTest': false,
        }
      };
      debugPrint('NATIVE_SHADE_ACTION_VERIFIED');
    } finally {
      await plugin.cancel(id: targetId);
      await plugin.cancel(id: otherId);
      await ack.clearAcknowledgement(eventId);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
