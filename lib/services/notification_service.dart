import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';
import '../core/router.dart';

class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  Future<void>? _initializationFuture;

  static const String _eventReminderChannelId = 'event_reminders';
  static const String _eventReminderChannelName = '일정 알림';
  static const String _eventReminderChannelDescription = '다가오는 일정 알림';
  static const int _maxSmartPreparationAlarmsPerEvent = 20;

  static const String _criticalAlarmChannelId = 'critical_alarms';
  static const String _criticalAlarmChannelName = '중요 일정 알람';
  static const String _criticalAlarmChannelDescription = '중요 일정 긴급 알람';
  static const MethodChannel _settingsChannel = MethodChannel(
    'planflow/android_settings',
  );

  Future<void> initialize() {
    return _initializationFuture ??= _initializeInternal();
  }

  Future<void> schedule({
    required String id,
    required String title,
    required DateTime scheduledAt,
    String? body,
  }) {
    return scheduleEventReminder(
      id: _stableNotificationId(id),
      title: title,
      body: body ?? title,
      notifyAt: scheduledAt,
    );
  }

  int notificationIdFor(String id) {
    return _stableNotificationId(id);
  }

  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      return;
    }

    await initialize();
    await _scheduleNotification(
      id: id,
      title: title,
      body: body,
      notifyAt: notifyAt,
      details: _eventReminderDetails,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  Future<void> scheduleMonthlyNaverIcsReminder({DateTime? now}) {
    final basis = now ?? DateTime.now();
    final nextReminder = _nextMonthlyNaverIcsReminderAt(basis);
    return scheduleEventReminder(
      id: notificationIdFor('naver_ics_monthly_reminder'),
      title: '네이버 캘린더 가져오기',
      body: '새 일정이 있을 수 있어요. 다시 가져올까요?',
      notifyAt: nextReminder,
      payload: 'naver_ics_monthly_reminder',
    );
  }

  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      return;
    }

    await initialize();
    await _runPermissionRequestBestEffort(
      'exact alarm before critical notification',
      _requestExactAlarmPermissionIfNeeded,
    );
    await _runPermissionRequestBestEffort(
      'full-screen intent before critical notification',
      _requestFullScreenIntentPermissionIfNeeded,
    );
    await _scheduleNotification(
      id: id,
      title: title,
      body: body ?? '중요 일정이 곧 시작됩니다.',
      notifyAt: notifyAt,
      details: _criticalAlarmDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id: id);
  }

  Future<void> cancelEventNotifications(String eventId) async {
    await cancel(notificationIdFor('$eventId:push'));
    await cancel(notificationIdFor('$eventId:critical'));
    await cancelSmartPreparationAlarms(eventId);
  }

  Future<void> cancelSmartPreparationAlarms(String eventId) async {
    for (var index = 0;
        index < _maxSmartPreparationAlarmsPerEvent;
        index += 1) {
      await cancel(notificationIdFor('$eventId:smart_preparation:$index'));
    }
  }

  Future<NotificationPermissionStatus> checkPermissionStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const NotificationPermissionStatus(
        notificationsEnabled: null,
        exactAlarmsEnabled: null,
        fullScreenIntentStatus: PermissionCheckState.unsupported,
      );
    }

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final notificationsEnabled =
        await android?.areNotificationsEnabled() ?? false;
    final exactAlarmsEnabled =
        await android?.canScheduleExactNotifications() ?? false;

    return NotificationPermissionStatus(
      notificationsEnabled: notificationsEnabled,
      exactAlarmsEnabled: exactAlarmsEnabled,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }

  Future<NotificationPermissionStatus> requestAndCheckPermissions() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return checkPermissionStatus();
    }

    await initialize();
    await _runPermissionRequestBestEffort(
      'notification permission',
      _requestNotificationPermissionIfNeeded,
    );
    await _runPermissionRequestBestEffort(
      'exact alarm permission',
      _requestExactAlarmPermissionIfNeeded,
    );
    await _runPermissionRequestBestEffort(
      'full-screen intent permission',
      _requestFullScreenIntentPermissionIfNeeded,
    );
    return checkPermissionStatus();
  }

  Future<bool> openAppNotificationSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      return await _settingsChannel.invokeMethod<bool>(
            'openNotificationSettings',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Open notification settings failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> _initializeInternal() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_planflow'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestSoundPermission: true,
        requestBadgePermission: true,
        defaultPresentAlert: true,
        defaultPresentSound: true,
        defaultPresentBadge: true,
        defaultPresentBanner: true,
        defaultPresentList: true,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestSoundPermission: true,
        requestBadgePermission: true,
        defaultPresentAlert: true,
        defaultPresentSound: true,
        defaultPresentBadge: true,
        defaultPresentBanner: true,
        defaultPresentList: true,
      ),
      linux: LinuxInitializationSettings(defaultActionName: '알림 열기'),
    );

    await _plugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == 'naver_ics_monthly_reminder') {
          appRouter.go(AppRoutes.naverIcsImport);
        }
      },
    );
    await _runPermissionRequestBestEffort(
      'initial notification permission',
      _requestNotificationPermissionIfNeeded,
    );
  }

  Future<void> _runPermissionRequestBestEffort(
    String label,
    Future<void> Function() request,
  ) async {
    try {
      await request();
    } catch (error, stackTrace) {
      debugPrint('Notification permission request skipped ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _requestNotificationPermissionIfNeeded() async {
    if (kIsWeb) {
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> _requestExactAlarmPermissionIfNeeded() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestExactAlarmsPermission();
  }

  Future<void> _requestFullScreenIntentPermissionIfNeeded() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestFullScreenIntentPermission();
  }

  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    required NotificationDetails details,
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      return;
    }

    final scheduledDate = tz.TZDateTime.from(notifyAt.toUtc(), tz.UTC);

    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: scheduledDate,
      notificationDetails: details,
      androidScheduleMode: androidScheduleMode,
      title: title,
      body: body,
      payload: payload ?? id.toString(),
    );
  }

  NotificationDetails get _eventReminderDetails {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _eventReminderChannelId,
        _eventReminderChannelName,
        channelDescription: _eventReminderChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.event,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      linux: LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.normal,
        suppressSound: false,
      ),
    );
  }

  NotificationDetails get _criticalAlarmDetails {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _criticalAlarmChannelId,
        _criticalAlarmChannelName,
        channelDescription: _criticalAlarmChannelDescription,
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      linux: LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.critical,
        suppressSound: false,
      ),
    );
  }

  int _stableNotificationId(String id) {
    final parsedId = int.tryParse(id);
    if (parsedId != null) {
      return parsedId;
    }

    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }

    return hash == 0 ? 1 : hash;
  }

  DateTime _nextMonthlyNaverIcsReminderAt(DateTime now) {
    var reminder = DateTime(now.year, now.month, 1, 9);
    if (!reminder.isAfter(now)) {
      reminder = DateTime(now.year, now.month + 1, 1, 9);
    }
    return reminder;
  }
}

enum PermissionCheckState { granted, denied, unsupported, needsManualCheck }

class NotificationPermissionStatus {
  const NotificationPermissionStatus({
    required this.notificationsEnabled,
    required this.exactAlarmsEnabled,
    required this.fullScreenIntentStatus,
  });

  final bool? notificationsEnabled;
  final bool? exactAlarmsEnabled;
  final PermissionCheckState fullScreenIntentStatus;
}
