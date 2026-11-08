import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/critical_alarm_acknowledgement_store.dart';
import 'package:planflow/services/departure_acknowledgement_store.dart';
import 'package:planflow/services/notification_service.dart';

class ActionNotifications extends NotificationService {
  final events = <String>[];
  final departures = <String>[];
  bool failSiblings = false;
  @override
  Future<void> cancelEventNotifications(String eventId) async {
    events.add(eventId);
    if (failSiblings) throw StateError('sibling cleanup failed');
  }

  @override
  Future<void> cancelDepartureNotifications(String eventId) async {
    departures.add(eventId);
  }
}

class ActionEvents extends EventRepository {
  @override
  Future<EventModel?> fetchEvent(String id, {String? userId}) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ActionAck extends CriticalAlarmAcknowledgementStore {
  final acknowledged = <String>[];
  bool fail = false;
  @override
  Future<void> markAcknowledged(String id, DateTime time) async {
    acknowledged.add(id);
    if (fail) throw StateError('preferences unavailable');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DepartureAckFailure extends DepartureAcknowledgementStore {
  @override
  Future<void> markAcknowledged(String id) async =>
      throw StateError('preferences unavailable');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  NotificationResponse critical() => const NotificationResponse(
      id: 417,
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: NotificationService.criticalAcknowledgedActionId,
      payload: 'event:owned:critical');
  test(
      'critical action cancels exact posted id without initialization, repeat safe',
      () async {
    final notifications = ActionNotifications();
    final ack = ActionAck();
    for (var i = 0; i < 2; i++) {
      await handleNotificationResponseAction(critical(),
          notificationService: notifications,
          criticalAlarmAcknowledgementStore: ack,
          eventRepository: ActionEvents());
    }
    expect(calls.map((c) => c.method), ['cancel', 'cancel']);
    expect(calls.map((c) => (c.arguments as Map)['id']), [417, 417]);
    expect(notifications.events, ['owned', 'owned']);
    expect(ack.acknowledged, ['owned', 'owned']);
  });
  test(
      'failed acknowledgement storage cannot prevent current alarm cancellation',
      () async {
    final ack = ActionAck()..fail = true;
    await handleNotificationResponseAction(critical(),
        notificationService: ActionNotifications(),
        criticalAlarmAcknowledgementStore: ack,
        eventRepository: ActionEvents());
    expect(calls.single.method, 'cancel');
    expect((calls.single.arguments as Map)['id'], 417);
  });
  test('sibling cancellation failure still persists acknowledgement', () async {
    final ack = ActionAck();
    await expectLater(
        handleNotificationResponseAction(critical(),
            notificationService: ActionNotifications()..failSiblings = true,
            criticalAlarmAcknowledgementStore: ack,
            eventRepository: ActionEvents()),
        throwsStateError);
    expect(calls.single.method, 'cancel');
    expect(ack.acknowledged, ['owned']);
  });
  test(
      'departure action dismisses exact notification before failing preferences',
      () async {
    final notifications = ActionNotifications();
    await expectLater(
        handleNotificationResponseAction(
            const NotificationResponse(
                id: 918,
                notificationResponseType:
                    NotificationResponseType.selectedNotificationAction,
                actionId: NotificationService.departureAcknowledgedActionId,
                payload: 'departure:owned'),
            notificationService: notifications,
            departureAcknowledgementStore: DepartureAckFailure()),
        throwsStateError);
    expect(calls.single.method, 'cancel');
    expect((calls.single.arguments as Map)['id'], 918);
    expect(notifications.departures, ['owned']);
  });
}
