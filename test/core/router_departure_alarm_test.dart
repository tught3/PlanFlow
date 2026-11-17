import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/screens/departure_alarm_screen.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('P5d production departure route confirms the query occurrence', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'initialize' ? true : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });
    const eventId = 'p5d-route-series';
    final occurrence = CriticalAlarmOccurrence(
      DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    final productionRoute = appRouter.configuration.routes
        .whereType<GoRoute>()
        .singleWhere((route) => route.path == AppRoutes.departureAlarm);
    final router = GoRouter(
      initialLocation: Uri(
        path: AppRoutes.departureAlarm,
        queryParameters: {
          'eventId': eventId,
          'title': 'Departure',
          NotificationService.departureOccurrenceRouteQueryKey:
              occurrence.token,
        },
      ).toString(),
      overridePlatformDefaultLocation: true,
      routes: [
        productionRoute,
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    final screen = tester.widget<DepartureAlarmScreen>(
      find.byType(DepartureAlarmScreen),
    );
    expect(screen.eventId, eventId);
    await tester.tap(find.byKey(const Key('departure_alarm_go_button')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final key = NotificationService.departureAcknowledgementKey(
      eventId,
      occurrence,
    );
    expect(prefs.getBool('departure_alarm:ack:$key'), isTrue);
    expect(prefs.containsKey('departure_alarm:ack:$eventId'), isFalse);
    expect(find.byType(DepartureAlarmScreen), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
