import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';
import '../core/router.dart';
import 'departure_acknowledgement_store.dart';

enum NotificationScheduleStatus {
  scheduled,
  skippedPast,
  permissionBlocked,
  error,
}

class NotificationScheduleResult {
  const NotificationScheduleResult({
    required this.status,
    required this.notifyAt,
    this.message,
  });

  final NotificationScheduleStatus status;
  final DateTime notifyAt;
  final String? message;

  bool get isScheduled => status == NotificationScheduleStatus.scheduled;
}

class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  Future<void>? _initializationFuture;

  static const String eventReminderChannelId = 'event_reminders_v2';
  static const String _eventReminderChannelId = eventReminderChannelId;
  static const String _eventReminderChannelName = '일정 알림';
  static const String _eventReminderChannelDescription = '다가오는 일정 알림';
  static const int _maxSmartPreparationAlarmsPerEvent = 20;

  static const String criticalAlarmChannelId = 'critical_alarms_v5_distinct';

  @visibleForTesting
  static const String criticalAlarmSoundResource = 'planflow_critical_alarm';

  static const String _criticalAlarmChannelName = '중요 일정 알람';
  static const String _criticalAlarmChannelDescription =
      '중요 일정 알람. 일반 알림보다 강한 진동과 전용 알림음으로 구분합니다.';
  static const Color _criticalAlarmColor = Color(0xFFD32F2F);
  static const String departureAcknowledgedActionId = 'departure_ack';
  static const String departureArrivedActionId = 'departure_arrived';
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
    await scheduleEventReminderWithResult(
      id: id,
      title: title,
      body: body,
      notifyAt: notifyAt,
      payload: payload,
    );
  }

  Future<NotificationScheduleResult> scheduleEventReminderWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      debugPrint('Notification skipped because notifyAt is past: $notifyAt');
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.skippedPast,
        notifyAt: notifyAt,
        message: '알림 시간이 이미 지나 예약하지 않았습니다.',
      );
    }

    try {
      await initialize();
      final status = await checkPermissionStatus();
      if (status.notificationsEnabled == false) {
        debugPrint('Event reminder permission blocked: notifications=false');
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.permissionBlocked,
          notifyAt: notifyAt,
          message: '앱 알림 권한이 꺼져 있어 알림을 예약하지 못했습니다.',
        );
      }
      await _scheduleNotification(
        id: id,
        title: title,
        body: body,
        notifyAt: notifyAt,
        details: _eventReminderDetails(),
        androidScheduleMode: reminderScheduleModeForStatus(status),
        payload: payload,
      );
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
        message: status.exactAlarmsEnabled == false
            ? '정확한 알람 권한이 꺼져 있어 Android가 알림을 조금 늦출 수 있습니다.'
            : null,
      );
    } catch (error, stackTrace) {
      debugPrint('Event reminder scheduling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
        message: '알림 예약 중 오류가 발생했습니다.',
      );
    }
  }

  Future<void> reinitializeForAppUpdate() async {
    _initializationFuture = null;
    await initialize();
    await scheduleMonthlyNaverIcsReminder();
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
    String? payload,
  }) async {
    await scheduleCriticalAlarmWithResult(
      id: id,
      title: title,
      notifyAt: notifyAt,
      body: body,
      payload: payload,
    );
  }

  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      debugPrint('Critical alarm skipped because notifyAt is past: $notifyAt');
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.skippedPast,
        notifyAt: notifyAt,
        message: '중요 알람 시간이 이미 지나 예약하지 않았습니다.',
      );
    }

    try {
      await initialize();
      await _runPermissionRequestBestEffort(
        'exact alarm before critical notification',
        _requestExactAlarmPermissionIfNeeded,
      );
      final fullScreenIntentAllowed =
          await _requestFullScreenIntentPermissionBestEffort();
      final status = await checkPermissionStatus();
      if (status.notificationsEnabled == false) {
        debugPrint(
          'Critical alarm permission blocked: '
          'notifications=${status.notificationsEnabled}, '
          'exact=${status.exactAlarmsEnabled}',
        );
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.permissionBlocked,
          notifyAt: notifyAt,
          message: _criticalAlarmPermissionMessage(status),
        );
      }
      final alarmTitle = criticalAlarmDisplayTitle(title);
      final alarmBody = criticalAlarmDisplayBody(title: title, body: body);
      await _scheduleNotification(
        id: id,
        title: alarmTitle,
        body: alarmBody,
        notifyAt: notifyAt,
        details: _criticalAlarmDetails(
          title: alarmTitle,
          body: alarmBody,
          fullScreenIntent: shouldUseCriticalFullScreenIntent(
            status: status,
            requestResult: fullScreenIntentAllowed,
          ),
        ),
        androidScheduleMode: criticalAlarmScheduleModeForStatus(status),
        payload: payload,
      );
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
        message: _criticalAlarmScheduleWarning(
          status: status,
          fullScreenIntentAllowed: fullScreenIntentAllowed,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Critical alarm scheduling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
        message:
            '중요 알람 예약 중 오류가 발생했습니다. Android 알림, 정확한 알람, 전체 화면 알림 설정을 확인해 주세요.',
      );
    }
  }

  Future<void> scheduleDepartureAlarm({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    await scheduleDepartureAlarmWithResult(
      id: id,
      title: title,
      body: body,
      notifyAt: notifyAt,
      payload: payload,
    );
  }

  Future<NotificationScheduleResult> scheduleDepartureAlarmWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      debugPrint('Departure alarm skipped because notifyAt is past: $notifyAt');
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.skippedPast,
        notifyAt: notifyAt,
        message: '이미 지난 출발 알림은 예약하지 않았습니다.',
      );
    }

    try {
      await initialize();
      await _runPermissionRequestBestEffort(
        'exact alarm before departure notification',
        _requestExactAlarmPermissionIfNeeded,
      );
      final fullScreenIntentAllowed =
          await _requestFullScreenIntentPermissionBestEffort();
      final status = await checkPermissionStatus();
      if (status.notificationsEnabled == false) {
        debugPrint(
          'Departure alarm permission blocked: '
          'notifications=${status.notificationsEnabled}, '
          'exact=${status.exactAlarmsEnabled}',
        );
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.permissionBlocked,
          notifyAt: notifyAt,
          message: _criticalAlarmPermissionMessage(status),
        );
      }

      await _scheduleNotification(
        id: id,
        title: title,
        body: body,
        notifyAt: notifyAt,
        details: _departureNotificationDetails(
          title: title,
          body: body,
          fullScreenIntent: shouldUseCriticalFullScreenIntent(
            status: status,
            requestResult: fullScreenIntentAllowed,
          ),
        ),
        androidScheduleMode: criticalAlarmScheduleModeForStatus(status),
        payload: payload,
      );
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
        message: _criticalAlarmScheduleWarning(
          status: status,
          fullScreenIntentAllowed: fullScreenIntentAllowed,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Departure alarm scheduling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
        message: '출발 알림 예약 중 오류가 발생했습니다.',
      );
    }
  }

  Future<NotificationScheduleResult> scheduleDepartureFallbackWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    if (!notifyAt.isAfter(DateTime.now())) {
      debugPrint(
          'Departure fallback skipped because notifyAt is past: $notifyAt');
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.skippedPast,
        notifyAt: notifyAt,
        message: '이미 지난 출발 알림은 예약하지 않았습니다.',
      );
    }

    try {
      await initialize();
      final status = await checkPermissionStatus();
      if (status.notificationsEnabled == false) {
        debugPrint(
          'Departure fallback permission blocked: '
          'notifications=${status.notificationsEnabled}, '
          'exact=${status.exactAlarmsEnabled}',
        );
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.permissionBlocked,
          notifyAt: notifyAt,
          message: _criticalAlarmPermissionMessage(status),
        );
      }
      await _scheduleNotification(
        id: id,
        title: title,
        body: body,
        notifyAt: notifyAt,
        details: _eventReminderDetails(
          actions: const [
            AndroidNotificationAction(
              departureAcknowledgedActionId,
              '출발했어요',
              cancelNotification: true,
              showsUserInterface: true,
              semanticAction: SemanticAction.none,
            ),
            AndroidNotificationAction(
              departureArrivedActionId,
              '도착',
              cancelNotification: true,
              showsUserInterface: true,
              semanticAction: SemanticAction.none,
            ),
          ],
        ),
        androidScheduleMode: reminderScheduleModeForStatus(status),
        payload: payload,
      );
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
        message: status.exactAlarmsEnabled == false
            ? '정확한 알림 권한이 꺼져 있어 Android가 약간 늦게 울릴 수 있습니다.'
            : null,
      );
    } catch (error, stackTrace) {
      debugPrint('Departure fallback scheduling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
        message: '출발 알림 예약 중 오류가 발생했습니다.',
      );
    }
  }

  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id: id);
  }

  Future<void> cancelEventNotifications(String eventId) async {
    await cancel(notificationIdFor('$eventId:push'));
    await cancel(notificationIdFor('$eventId:critical'));
    await cancel(notificationIdFor('$eventId:departure'));
    await cancelSmartPreparationAlarms(eventId);
    await cancelPreActionAlarms(eventId);
  }

  Future<void> cancelDepartureNotifications(String eventId) async {
    await cancel(notificationIdFor('$eventId:departure'));
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await AndroidAlarmManager.cancel(
        _stableNotificationId('$eventId:departure_preflight'),
      );
    } catch (error, stackTrace) {
      debugPrint('Cancel departure preflight failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> cancelSmartPreparationAlarms(String eventId) async {
    for (var index = 0;
        index < _maxSmartPreparationAlarmsPerEvent;
        index += 1) {
      await cancel(notificationIdFor('$eventId:smart_preparation:$index'));
    }
  }

  Future<void> cancelPreActionAlarms(String eventId) async {
    for (var index = 0;
        index < _maxSmartPreparationAlarmsPerEvent;
        index += 1) {
      await cancel(notificationIdFor('$eventId:pre_action:$index'));
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
      fullScreenIntentStatus: await _checkFullScreenIntentStatus(),
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

  Future<bool> requestNotificationPermission() async {
    await initialize();
    await _runPermissionRequestBestEffort(
      'notification permission',
      _requestNotificationPermissionIfNeeded,
    );
    return (await checkPermissionStatus()).notificationsEnabled == true;
  }

  Future<bool> requestExactAlarmPermission() async {
    await initialize();
    await _runPermissionRequestBestEffort(
      'exact alarm permission',
      _requestExactAlarmPermissionIfNeeded,
    );
    return (await checkPermissionStatus()).exactAlarmsEnabled == true;
  }

  Future<bool?> requestFullScreenIntentPermission() async {
    await initialize();
    return _requestFullScreenIntentPermissionBestEffort();
  }

  Future<PermissionCheckState> _checkFullScreenIntentStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return PermissionCheckState.unsupported;
    }

    try {
      final granted = await _settingsChannel.invokeMethod<bool>(
        'canUseFullScreenIntent',
      );
      if (granted == true) {
        return PermissionCheckState.granted;
      }
      if (granted == false) {
        return PermissionCheckState.denied;
      }
      return PermissionCheckState.needsManualCheck;
    } catch (error, stackTrace) {
      debugPrint('Full-screen intent permission check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return PermissionCheckState.needsManualCheck;
    }
  }

  @visibleForTesting
  static AndroidScheduleMode reminderScheduleModeForStatus(
    NotificationPermissionStatus status,
  ) {
    if (status.exactAlarmsEnabled == false) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  @visibleForTesting
  static AndroidScheduleMode criticalAlarmScheduleModeForStatus(
    NotificationPermissionStatus status,
  ) {
    if (status.exactAlarmsEnabled == false) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  @visibleForTesting
  static bool shouldUseCriticalFullScreenIntent({
    required NotificationPermissionStatus status,
    required bool? requestResult,
  }) {
    return requestResult == true ||
        status.fullScreenIntentStatus == PermissionCheckState.granted;
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

  Future<bool> openCriticalAlarmChannelSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      return await _settingsChannel.invokeMethod<bool>(
            'openNotificationChannelSettings',
            <String, Object?>{'channelId': criticalAlarmChannelId},
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Open critical alarm channel settings failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return openAppNotificationSettings();
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
      onDidReceiveBackgroundNotificationResponse:
          _backgroundNotificationResponseCallback,
      onDidReceiveNotificationResponse: (response) {
        final route = routeForNotificationResponse(response);
        if ((response.actionId == departureAcknowledgedActionId ||
                response.actionId == departureArrivedActionId) &&
            (response.payload ?? '').startsWith('departure:')) {
          final eventId =
              (response.payload ?? '').substring('departure:'.length).trim();
          if (eventId.isNotEmpty) {
            unawaited(_acknowledgeDeparture(eventId));
          }
        }
        if (route != null) {
          appRouter.go(route);
        }
      },
    );
    await _ensureAndroidNotificationChannels();
    await _runPermissionRequestBestEffort(
      'initial notification permission',
      _requestNotificationPermissionIfNeeded,
    );
  }

  Future<void> _ensureAndroidNotificationChannels() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      return;
    }

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _eventReminderChannelId,
        _eventReminderChannelName,
        description: _eventReminderChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android.createNotificationChannel(
      AndroidNotificationChannel(
        criticalAlarmChannelId,
        _criticalAlarmChannelName,
        description: _criticalAlarmChannelDescription,
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
          criticalAlarmSoundResource,
        ),
        enableVibration: true,
        vibrationPattern: Int64List.fromList(
          <int>[0, 1200, 250, 1200, 250, 1600],
        ),
      ),
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

  Future<bool?> _requestFullScreenIntentPermissionBestEffort() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    try {
      return await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestFullScreenIntentPermission();
    } catch (error, stackTrace) {
      debugPrint('Full-screen intent permission request skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
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

  NotificationDetails _eventReminderDetails({
    List<AndroidNotificationAction>? actions,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _eventReminderChannelId,
        _eventReminderChannelName,
        channelDescription: _eventReminderChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.event,
        actions: actions,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      linux: LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.normal,
        suppressSound: false,
      ),
    );
  }

  NotificationDetails _departureNotificationDetails({
    required String title,
    required String body,
    required bool fullScreenIntent,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        criticalAlarmChannelId,
        _criticalAlarmChannelName,
        channelDescription: _criticalAlarmChannelDescription,
        importance: Importance.max,
        priority: Priority.max,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
          summaryText: '놓치면 안 되는 중요 알림',
        ),
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: fullScreenIntent,
        channelAction: AndroidNotificationChannelAction.update,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
          criticalAlarmSoundResource,
        ),
        enableVibration: true,
        autoCancel: false,
        color: _criticalAlarmColor,
        colorized: true,
        enableLights: true,
        ledColor: _criticalAlarmColor,
        ledOnMs: 1000,
        ledOffMs: 500,
        vibrationPattern: Int64List.fromList(
          <int>[0, 1200, 250, 1200, 250, 1600],
        ),
        visibility: NotificationVisibility.public,
        ticker: '중요 일정 알림',
        actions: const [
          AndroidNotificationAction(
            departureAcknowledgedActionId,
            '출발했어요',
            cancelNotification: true,
            showsUserInterface: true,
            semanticAction: SemanticAction.none,
          ),
          AndroidNotificationAction(
            departureArrivedActionId,
            '도착',
            cancelNotification: true,
            showsUserInterface: true,
            semanticAction: SemanticAction.none,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      linux: const LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.critical,
        suppressSound: false,
      ),
    );
  }

  NotificationDetails _criticalAlarmDetails({
    required String title,
    required String body,
    required bool fullScreenIntent,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        criticalAlarmChannelId,
        _criticalAlarmChannelName,
        channelDescription: _criticalAlarmChannelDescription,
        importance: Importance.max,
        priority: Priority.max,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
          summaryText: '놓치면 안 되는 중요 알람',
        ),
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: fullScreenIntent,
        channelAction: AndroidNotificationChannelAction.update,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
          criticalAlarmSoundResource,
        ),
        enableVibration: true,
        autoCancel: false,
        color: _criticalAlarmColor,
        colorized: true,
        enableLights: true,
        ledColor: _criticalAlarmColor,
        ledOnMs: 1000,
        ledOffMs: 500,
        vibrationPattern: Int64List.fromList(
          <int>[0, 1200, 250, 1200, 250, 1600],
        ),
        visibility: NotificationVisibility.public,
        ticker: '중요 일정 알람',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      ),
      linux: const LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.critical,
        suppressSound: false,
      ),
    );
  }

  @visibleForTesting
  static String criticalAlarmDisplayTitle(String title) {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      return '중요 알람';
    }
    if (trimmedTitle.startsWith('중요 알람')) {
      return trimmedTitle;
    }
    return '중요 알람: $trimmedTitle';
  }

  @visibleForTesting
  static String criticalAlarmDisplayBody({
    required String title,
    String? body,
  }) {
    final trimmedTitle = title.trim();
    final trimmedBody = body?.trim();
    final eventLine = trimmedTitle.isEmpty ? null : trimmedTitle;
    const defaultBody = '중요 일정이 곧 시작됩니다.';
    final bodyLines = <String>[
      '중요 일정입니다. 지금 확인해 주세요.',
      if (eventLine != null) eventLine,
      if (trimmedBody != null &&
          trimmedBody.isNotEmpty &&
          trimmedBody != defaultBody)
        trimmedBody
      else
        defaultBody,
      '알림을 누르면 해당 일정으로 이동합니다.',
    ];
    return bodyLines.join('\n');
  }

  @visibleForTesting
  static String? routeForNotificationResponse(NotificationResponse response) {
    if (response.payload == 'naver_ics_monthly_reminder') {
      return AppRoutes.naverIcsImport;
    }

    final payload = response.payload ?? '';
    if (payload == 'briefing:morning' || payload == 'briefing:evening') {
      final type = payload.endsWith('evening') ? 'evening' : 'morning';
      return '${AppRoutes.briefing}?type=$type';
    }

    if (payload.startsWith('event:')) {
      final eventId = payload.substring('event:'.length).trim();
      if (eventId.isEmpty) {
        return null;
      }
      return '${AppRoutes.eventDetail}/${Uri.encodeComponent(eventId)}';
    }

    if (payload.startsWith('departure:')) {
      final eventId = payload.substring('departure:'.length).trim();
      if (eventId.isEmpty) {
        return null;
      }
      final eventRoute =
          '${AppRoutes.eventDetail}/${Uri.encodeComponent(eventId)}';
      if (response.actionId == departureAcknowledgedActionId ||
          response.actionId == departureArrivedActionId) {
        return eventRoute;
      }
      return '$eventRoute?departureAction=prompt';
    }

    return null;
  }

  Future<void> _acknowledgeDeparture(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    const store = SharedPreferencesDepartureAcknowledgementStore();
    await store.markAcknowledged(normalizedEventId);
    await cancelDepartureNotifications(normalizedEventId);
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

  String _criticalAlarmPermissionMessage(NotificationPermissionStatus status) {
    final blockers = <String>[];
    if (status.notificationsEnabled == false) {
      blockers.add('앱 알림');
    }

    final blockerText =
        blockers.isEmpty ? 'Android 알림 설정' : blockers.join(', ');
    return '중요 알람을 강하게 울리려면 $blockerText 권한이 필요합니다. '
        '휴대폰 설정에서 PlanFlow 알림, 알람 및 리마인더, 전체 화면 알림 허용 상태를 확인해 주세요. 폴드/플립 겉화면 노출은 기기 정책에 따라 달라질 수 있습니다.';
  }

  String? _criticalAlarmScheduleWarning({
    required NotificationPermissionStatus status,
    required bool? fullScreenIntentAllowed,
  }) {
    final warnings = <String>[];
    if (status.exactAlarmsEnabled == false) {
      warnings.add(
        '중요 알람은 예약했지만 정확한 알람 권한이 꺼져 있어 Android가 조금 늦게 울릴 수 있습니다.',
      );
    }
    if (fullScreenIntentAllowed == false ||
        status.fullScreenIntentStatus == PermissionCheckState.denied) {
      warnings.add(
        '전체 화면 알림이 꺼져 있어 잠금화면 팝업이나 폴드/플립 겉화면 노출이 제한될 수 있습니다.',
      );
    }
    if (warnings.isEmpty) {
      return null;
    }
    return '${warnings.join(' ')} 휴대폰 설정에서 PlanFlow 알림, 알람 및 리마인더, 전체 화면 알림 허용 상태를 확인해 주세요.';
  }
}

/// 앱이 백그라운드 상태에서 알림 액션 버튼 탭 시 호출되는 top-level 콜백.
/// flutter_local_notifications 요구사항: @pragma('vm:entry-point') + top-level 함수.
@pragma('vm:entry-point')
Future<void> _backgroundNotificationResponseCallback(
  NotificationResponse response,
) async {
  final payload = response.payload ?? '';
  final actionId = response.actionId;
  if ((actionId == NotificationService.departureAcknowledgedActionId ||
          actionId == NotificationService.departureArrivedActionId) &&
      payload.startsWith('departure:')) {
    final eventId = payload.substring('departure:'.length).trim();
    if (eventId.isNotEmpty) {
      const store = SharedPreferencesDepartureAcknowledgementStore();
      await store.markAcknowledged(eventId);
      // cancelNotification: true 로 알림은 자동 취소됨
      // 다음 모니터 실행(30분 이내)에서 isAcknowledged() → skip
    }
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
