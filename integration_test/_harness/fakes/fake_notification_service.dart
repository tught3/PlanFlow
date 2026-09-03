import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:planflow/services/notification_service.dart';

/// [NotificationService]의 결정론적 E2E fake.
///
/// **실측 확인**: `NotificationService({FlutterLocalNotificationsPlugin?
/// plugin})`(`lib/services/notification_service.dart:36`)는 겉보기엔
/// 플러그인 주입 seam이지만, `FlutterLocalNotificationsPlugin`은
/// `factory FlutterLocalNotificationsPlugin() => _instance;` +
/// `FlutterLocalNotificationsPlugin._()`(private named constructor)만
/// 가진 싱글턴이라(package:flutter_local_notifications 21.0.0,
/// `lib/src/flutter_local_notifications_plugin.dart`) 외부 파일에서
/// 서브클래싱해 fake 플러그인을 만들 수 없다(private 생성자는 라이브러리
/// 밖에서 호출 불가). 그래서 이 파라미터는 실질적으로 사용 불가능한 seam이다
/// — 완료 보고에도 이 사실을 남긴다.
///
/// 실제로 재사용 가능한 seam은 `NotificationService` 자체의 서브클래싱
/// (메서드 오버라이드)이며, `test/services/notification_service_test.dart:512`의
/// `_FakeNotificationService extends NotificationService` 패턴을 그대로
/// 따랐다. `initialize()`/`*WithResult` 계열/`cancel*` 계열만 오버라이드하면
/// 내부적으로 이들을 호출하는 다른 공개 메서드(`scheduleEventReminder`,
/// `scheduleCriticalAlarm`, `scheduleDepartureAlarm`,
/// `scheduleCriticalReminderTomorrow` 등)도 Dart의 동적 디스패치 덕분에
/// 자동으로 fake 경로를 탄다 — 이 파일이 직접 오버라이드하는 메서드만
/// `_plugin`을 건드리지 않으면 된다.
class FakeNotificationService extends NotificationService {
  /// scheduleEventReminderWithResult(및 이를 경유하는 모든 호출)가 반환할
  /// 상태. 기본값은 정상 예약.
  NotificationScheduleStatus eventReminderStatus =
      NotificationScheduleStatus.scheduled;
  NotificationScheduleStatus criticalAlarmStatus =
      NotificationScheduleStatus.scheduled;
  NotificationScheduleStatus departureAlarmStatus =
      NotificationScheduleStatus.scheduled;

  final List<ScheduledCall> scheduledEventReminders = <ScheduledCall>[];
  final List<ScheduledCall> scheduledCriticalAlarms = <ScheduledCall>[];
  final List<ScheduledCall> scheduledDepartureAlarms = <ScheduledCall>[];
  final List<ScheduledCall> scheduledDepartureFallbacks = <ScheduledCall>[];
  final List<int> cancelledIds = <int>[];

  @override
  Future<void> initialize() async {
    // 실제 flutter_local_notifications 플러그인 초기화(플랫폼 채널) 없이
    // 즉시 완료된 것으로 간주한다.
  }

  @override
  Future<NotificationScheduleResult> scheduleEventReminderWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async {
    scheduledEventReminders.add(
      ScheduledCall(id: id, title: title, notifyAt: notifyAt, payload: payload),
    );
    return _resultFor(eventReminderStatus, notifyAt);
  }

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    scheduledCriticalAlarms.add(
      ScheduledCall(id: id, title: title, notifyAt: notifyAt, payload: payload),
    );
    return _resultFor(criticalAlarmStatus, notifyAt);
  }

  @override
  Future<NotificationScheduleResult> scheduleDepartureAlarmWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    scheduledDepartureAlarms.add(
      ScheduledCall(id: id, title: title, notifyAt: notifyAt, payload: payload),
    );
    return _resultFor(departureAlarmStatus, notifyAt);
  }

  @override
  Future<NotificationScheduleResult> scheduleDepartureFallbackWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    scheduledDepartureFallbacks.add(
      ScheduledCall(id: id, title: title, notifyAt: notifyAt, payload: payload),
    );
    return _resultFor(departureAlarmStatus, notifyAt);
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
  }

  @override
  Future<void> showDiagnosticTestNotification() async {
    // no-op: 실제 플러그인을 건드리지 않는다.
  }

  @override
  Future<int> pendingNotificationCount() async => scheduledEventReminders.length +
      scheduledCriticalAlarms.length +
      scheduledDepartureAlarms.length +
      scheduledDepartureFallbacks.length -
      cancelledIds.length;

  @override
  Future<String?> resolveColdStartLaunchRoute() async {
    // 실제 `_plugin.getNotificationAppLaunchDetails()`를 건드리지 않는다.
    // cold-start 딥링크 시나리오는 [resolveNotificationTapRoute]로 직접
    // 트리거한다.
    return null;
  }

  NotificationScheduleResult _resultFor(
    NotificationScheduleStatus status,
    DateTime notifyAt,
  ) {
    return NotificationScheduleResult(status: status, notifyAt: notifyAt);
  }
}

class ScheduledCall {
  const ScheduledCall({
    required this.id,
    required this.title,
    required this.notifyAt,
    this.payload,
  });

  final int id;
  final String title;
  final DateTime notifyAt;
  final String? payload;
}

/// 알림 탭(포그라운드/백그라운드 라우팅) 시나리오를 순수 함수로 재현한다.
///
/// `NotificationService.routeForNotificationResponse`
/// (`lib/services/notification_service.dart` 1367번째 줄 근처,
/// `@visibleForTesting static`)를 그대로 호출하므로 실제 라우팅 계약과
/// 100% 동일하다.
String? resolveNotificationTapRoute(NotificationResponse response) {
  return NotificationService.routeForNotificationResponse(response);
}
