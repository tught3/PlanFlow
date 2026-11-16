import 'dart:async';
import 'dart:math' as math;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';
import '../core/diag_logger.dart';
import '../core/local_time.dart';
import '../core/router.dart';
import '../data/repositories/event_repository.dart';
import 'critical_alarm_acknowledgement_store.dart';
import 'critical_alarm_preflight_service.dart';
import 'departure_acknowledgement_store.dart';
import 'launch_signal_ledger.dart';
import 'naver_ics_reminder_policy.dart';

/// Books local alerts in event-start order against the shared pending queue.
class LocalAlarmResyncBatch {
  LocalAlarmResyncBatch({required NotificationService notificationService})
      : _notifications = notificationService;

  final NotificationService _notifications;
  final _bookings = <({
    DateTime startAt,
    int slots,
    Future<int> Function(int) book,
    String? departureKey,
    Future<bool> Function()? canReplacePending,
    void Function()? onSkip,
  })>[];

  void add(
    DateTime startAt,
    int slots,
    Future<int> Function(int) book, {
    String? departureKey,
    Future<bool> Function()? canReplacePending,
    void Function()? onSkip,
  }) {
    if (slots > 0) {
      _bookings.add((
        startAt: startAt,
        slots: slots,
        book: book,
        departureKey: departureKey,
        canReplacePending: canReplacePending,
        onSkip: onSkip,
      ));
    }
  }

  Future<bool> book() async {
    final ordered = _bookings.asMap().entries.toList()
      ..sort((a, b) {
        final byStart = a.value.startAt.compareTo(b.value.startAt);
        return byStart == 0 ? a.key.compareTo(b.key) : byStart;
      });
    _bookings.clear();
    if (ordered.isEmpty) return true;

    var succeeded = true;
    var trimmed = 0;
    var pending = <int>{};
    try {
      pending = (await _notifications.pendingRequestsForCleanup())
          .map((request) => request.id)
          .toSet();
    } catch (error) {
      // The callers may already have cleared jobs they intend to rebook.
      // Continue with the per-resync cap and leave existing queue entries alone.
      succeeded = false;
      DiagLogger.log(
        'LocalAlarmResync',
        'Could not read pending alarms: ${error.runtimeType}; '
            'total pending alarms unknown',
      );
    }

    final replaceable = <int, ({String key, int id})>{};
    for (var index = 0; index < ordered.length; index++) {
      final booking = ordered[index].value;
      final key = booking.departureKey;
      final canReplace = booking.canReplacePending;
      if (key == null || canReplace == null) continue;
      final id = _notifications.notificationIdFor(key);
      if (!pending.contains(id)) continue;
      try {
        if (await canReplace()) {
          replaceable[index] = (key: key, id: id);
        }
      } catch (error) {
        succeeded = false;
        DiagLogger.log(
          'LocalAlarmResync',
          'Could not assess pending departure: ${error.runtimeType}',
        );
      }
    }

    var occupied = pending.length;
    final limit = localAlarmResyncLimit;
    Future<void> cancelLaterDeparture(int index) async {
      final slot = replaceable.remove(index)!;
      try {
        await _notifications.cancelDepartureSlot(slot.key);
        if (pending.remove(slot.id)) occupied--;
      } catch (error) {
        succeeded = false;
        DiagLogger.log(
          'LocalAlarmResync',
          'Could not cancel later departure: ${error.runtimeType}',
        );
      }
    }

    while (occupied > limit && replaceable.isNotEmpty) {
      await cancelLaterDeparture(replaceable.keys.last);
    }
    for (var index = 0; index < ordered.length; index++) {
      final booking = ordered[index].value;
      final key = booking.departureKey;
      final id = key == null ? null : _notifications.notificationIdFor(key);
      final alreadyBooked = pending.contains(id);
      replaceable.remove(index);
      if (!alreadyBooked) {
        while (limit - occupied < booking.slots && replaceable.isNotEmpty) {
          await cancelLaterDeparture(replaceable.keys.last);
        }
      }
      final allowed = math.min(
        booking.slots,
        math.max(0, limit - occupied + (alreadyBooked ? 1 : 0)),
      );
      trimmed += booking.slots - allowed;
      if (allowed == 0) {
        booking.onSkip?.call();
        continue;
      }
      try {
        final booked = await booking.book(allowed);
        if (!alreadyBooked) {
          occupied += booked;
          if (id != null && booked > 0) pending.add(id);
        }
      } catch (error) {
        // A booking may fail after reserving some of its slots.
        if (!alreadyBooked) occupied += allowed;
        succeeded = false;
        DiagLogger.log(
          'LocalAlarmResync',
          'Local alarm resync booking failed: ${error.runtimeType}',
        );
      }
    }
    if (trimmed > 0) {
      DiagLogger.log(
        'LocalAlarmResync',
        'Local alarm resync trimmed $trimmed alarms (limit $limit)',
      );
    }
    return succeeded;
  }
}

/// Local calendar suffix shared by recurring alarm scheduling and cancellation.
String eventAlarmDateSuffix(DateTime time) {
  final day = planflowLocal(time);
  return _eventAlarmDateDigits(day);
}

String _eventAlarmDateDigits(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}'
    '${day.month.toString().padLeft(2, '0')}'
    '${day.day.toString().padLeft(2, '0')}';

/// The unsuffixed slot plus today and seven more local dates.
Iterable<String> eventAlarmCancellationKeys(String key, DateTime now) sync* {
  yield key;
  final today = planflowLocalDay(now);
  for (var offset = 0; offset < 8; offset++) {
    final day = DateTime(today.year, today.month, today.day + offset);
    yield '$key:${_eventAlarmDateDigits(day)}';
  }
}

const iosLocalAlarmResyncLimit = 56;
const androidLocalAlarmResyncLimit = 400;

int get localAlarmResyncLimit => defaultTargetPlatform == TargetPlatform.iOS
    ? iosLocalAlarmResyncLimit
    : androidLocalAlarmResyncLimit;

/// Identity of the alarm as scheduled, including its original local date.
class CriticalAlarmOccurrence {
  CriticalAlarmOccurrence(DateTime startAt)
      : this._(startAt.toUtc(), eventAlarmDateSuffix(startAt));

  const CriticalAlarmOccurrence._(this.startAt, this.dateSuffix);

  static const routeQueryKey = 'criticalOccurrence';
  static const _payloadMarker = ':occurrence:';

  final DateTime startAt;
  final String dateSuffix;

  String get token => '$dateSuffix.${startAt.microsecondsSinceEpoch}';

  String payloadFor(String eventId) =>
      'event:$eventId$_payloadMarker$token${NotificationService.criticalAlarmPayloadSuffix}';

  String alarmKey(String eventId, String kind) => '$eventId:$kind:$dateSuffix';

  String acknowledgementKey(String eventId) => alarmKey(eventId, 'critical');

  static CriticalAlarmOccurrence? tryParse(String? token) {
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 2 || !RegExp(r'^[0-9]{8}$').hasMatch(parts.first)) {
      return null;
    }
    final micros = int.tryParse(parts.last);
    if (micros == null) return null;
    try {
      final start = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      return CriticalAlarmOccurrence._(start, parts.first);
    } on ArgumentError {
      return null;
    }
  }
}

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
  NotificationService(
      {FlutterLocalNotificationsPlugin? plugin,
      this.allowPermissionRequests = true,
      LaunchSignalLedger? launchSignalLedger,
      NaverIcsImportHistoryStore? naverIcsImportHistory,
      DateTime Function()? now})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _launchSignalLedger = launchSignalLedger ?? LaunchSignalLedger(),
        _naverIcsImportHistory =
            naverIcsImportHistory ?? NaverIcsImportHistoryStore(),
        _now = now ?? DateTime.now;

  final FlutterLocalNotificationsPlugin _plugin;
  final bool allowPermissionRequests;
  final LaunchSignalLedger _launchSignalLedger;
  final NaverIcsImportHistoryStore _naverIcsImportHistory;
  final DateTime Function() _now;

  Future<void>? _initializationFuture;

  // v2 -> v3: enableVibration/playSound를 details까지 명시적으로 강제하기 위한 bump.
  // Android는 채널 생성 후 사운드/진동 설정을 코드로 재정의할 수 없어, 값이 바뀌면
  // 반드시 새 채널 id로 다시 만들어야 기존 기기에도 반영된다.
  static const String eventReminderChannelId = 'event_reminders_v3';
  static const String _eventReminderChannelId = eventReminderChannelId;
  static const String _eventReminderChannelName = '일정 알림';
  static const String _eventReminderChannelDescription = '다가오는 일정 알림';
  static const int _maxSmartPreparationAlarmsPerEvent = 20;

  // v5_distinct -> v6_alarmstream: audioAttributesUsage=alarm 복원 bump.
  // fa66fc0("Stabilize critical alarm channel")에서 alarm usage를 빼고 시스템
  // 기본음으로 되돌렸었고, 5834431에서 raw 사운드만 재도입한 뒤 alarm usage는
  // 복원되지 않아 무음 회귀가 발생했다. 채널 id를 반드시 함께 올려야
  // 기존 기기에서도 새 오디오 스트림 설정이 적용된다(Android 채널 불변 정책).
  static const String criticalAlarmChannelId =
      'critical_alarms_v7_strong_sound';
  static const String importantAlarmChannelId = 'important_alarms_v1';

  /// 과거 사용됐던 채널 id 이력. 앱 초기화 시 정리 대상이며, 반드시 현재
  /// [eventReminderChannelId]/[criticalAlarmChannelId]와 겹치지 않아야 한다.
  @visibleForTesting
  static const List<String> legacyEventReminderChannelIds = <String>[
    'event_reminders',
    'event_reminders_v2',
  ];

  @visibleForTesting
  static const List<String> legacyCriticalAlarmChannelIds = <String>[
    'critical_alarms',
    'critical_alarms_v2',
    'critical_alarms_v3_loud',
    'critical_alarms_v4_safe',
    'critical_alarms_v5_distinct',
    'critical_alarms_v6_alarmstream',
  ];

  @visibleForTesting
  static const String criticalAlarmSoundResource = 'planflow_critical_alarm';

  static const String _criticalAlarmChannelName = '중요 일정 알람';
  static const String _criticalAlarmChannelDescription =
      '중요 일정 알람. 일반 알림보다 강한 진동과 전용 알림음으로 구분합니다.';
  static const Color _criticalAlarmColor = Color(0xFFD32F2F);
  static const String departureAcknowledgedActionId = 'departure_ack';
  static const String criticalAcknowledgedActionId = 'critical_ack';
  static const String criticalRemindTomorrowActionId =
      'critical_remind_tomorrow';

  /// [scheduleCriticalAlarmWithResult]가 예약하는 `event:` payload에만 붙는
  /// 구분용 suffix. 일반 리마인더/준비알람/"내일 다시 알림"은 같은
  /// `event:<id>` prefix를 쓰지만 강한알람(critical alarm) 채널이 아니므로
  /// 이 suffix가 붙지 않는다. [routeForNotificationResponse]가 이 suffix
  /// 유무로 `criticalAck` 쿼리파라미터를 강한알람 응답에만 부여한다.
  /// (M1: criticalAck가 모든 event: payload에 무차별로 붙던 문제 수정)
  @visibleForTesting
  static const String criticalAlarmPayloadSuffix = ':critical';
  static const List<AndroidNotificationAction> _departureActions =
      <AndroidNotificationAction>[
    AndroidNotificationAction(
      departureAcknowledgedActionId,
      '출발',
      cancelNotification: true,
      showsUserInterface: false,
      semanticAction: SemanticAction.none,
    ),
  ];

  /// iOS 강한알람 커스텀 사운드. Runner 타겟 번들에 포함된 파일명(확장자 포함).
  /// Android와 동일한 wav를 ios/Runner/planflow_critical_alarm.wav 로 복사해
  /// Xcode Resources에 추가했다. UNNotificationSound는 파일명만 지정하면 된다.
  static const String criticalAlarmIosSoundName = 'planflow_critical_alarm.wav';

  /// iOS 강한알람 알림 카테고리 identifier. Android의 critical 액션 버튼과
  /// 동일한 "확인(출발)" 액션을 달아 준다.
  static const String criticalAlarmCategoryId = 'critical_alarm_category';

  /// Darwin 알림 카테고리. 액션 identifier를 [criticalAcknowledgedActionId]로
  /// 맞춰 [handleNotificationResponseAction]의 취소 로직을 그대로 재사용한다.
  @visibleForTesting
  static final DarwinNotificationCategory criticalAlarmDarwinCategory =
      DarwinNotificationCategory(
    criticalAlarmCategoryId,
    actions: <DarwinNotificationAction>[
      DarwinNotificationAction.plain(
        criticalAcknowledgedActionId,
        '확인(출발)',
      ),
    ],
  );

  static const List<AndroidNotificationAction> _criticalActions =
      <AndroidNotificationAction>[
    AndroidNotificationAction(
      criticalAcknowledgedActionId,
      '확인(출발)',
      cancelNotification: true,
      showsUserInterface: false,
      semanticAction: SemanticAction.none,
    ),
    AndroidNotificationAction(
      criticalRemindTomorrowActionId,
      '내일 오전 9시',
      cancelNotification: true,
      showsUserInterface: false,
      semanticAction: SemanticAction.none,
    ),
  ];
  @visibleForTesting
  static List<AndroidNotificationAction> get criticalActionsForTest =>
      _criticalActions;
  static const MethodChannel _settingsChannel = MethodChannel(
    'planflow/android_settings',
  );
  static const MethodChannel _iosPermissionsChannel =
      MethodChannel('planflow/ios_permissions');

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
    bool includeDepartureAction = false,
  }) async {
    await scheduleEventReminderWithResult(
      id: id,
      title: title,
      body: body,
      notifyAt: notifyAt,
      payload: payload,
      includeDepartureAction: includeDepartureAction,
    );
  }

  Future<NotificationScheduleResult> scheduleEventReminderWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
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
        details: _eventReminderDetails(
          actions: includeDepartureAction ? _departureActions : null,
        ),
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

  /// 가져오기 이력이 있을 때만 예약하며, 이력이 없으면 기존 예약도 취소한다.
  Future<void> scheduleMonthlyNaverIcsReminder({DateTime? now}) async {
    final nextReminder = nextNaverIcsReminderAt(
      now: now ?? _now(),
      lastImportAt: await _naverIcsImportHistory.lastImportAt(),
    );
    if (nextReminder == null) {
      await cancel(notificationIdFor(naverIcsReminderPayloadPrefix));
      return;
    }
    await scheduleEventReminder(
      id: notificationIdFor('naver_ics_monthly_reminder'),
      title: '네이버 캘린더 가져오기',
      body: '새 일정이 있을 수 있어요. 다시 가져올까요?',
      notifyAt: nextReminder,
      payload: naverIcsReminderPayload(nextReminder),
    );
  }

  /// 이전 버전에서 예약된 베타 후기 알림만 정리한다. 새 알림은 예약하지 않는다.
  Future<void> cancelBetaSurveyReminder() {
    return cancel(notificationIdFor('beta_survey_reminder'));
  }

  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    await scheduleCriticalAlarmWithResult(
      id: id,
      title: title,
      notifyAt: notifyAt,
      body: body,
      payload: payload,
      useStrongAlarm: useStrongAlarm,
    );
  }

  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
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
      // Event reminders never use full-screen UI. The strong profile changes
      // only the sound/vibration channel; it must not create a second alarm
      // surface or keep a stale notification alive after a tap.
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
      final alarmTitle = title.trim().isEmpty ? '중요 일정' : title.trim();
      final alarmBody =
          body?.trim().isNotEmpty == true ? body!.trim() : '중요 일정이 곧 시작됩니다.';
      await _scheduleNotification(
        id: id,
        title: alarmTitle,
        body: alarmBody,
        notifyAt: notifyAt,
        details: _criticalAlarmDetails(
          title: alarmTitle,
          body: alarmBody,
          useStrongAlarm: useStrongAlarm,
        ),
        androidScheduleMode: criticalAlarmScheduleModeForStatus(status),
        payload: _criticalAlarmPayload(payload),
      );
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
        message: _criticalAlarmScheduleWarning(
          status: status,
          fullScreenIntentAllowed: null,
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

  /// 중요 알람의 "내일 오전 9시" 액션이 누른 일정을 다시 확인하도록
  /// 독립 알림을 예약한다. 원 일정의 시각을 바꾸지 않는다.
  Future<NotificationScheduleResult> scheduleCriticalReminderTomorrow({
    required String eventId,
    DateTime? now,
  }) async {
    final normalizedEventId = eventId.trim();
    final reference = now ?? DateTime.now();
    final notifyAt = nextCriticalReminderAt(reference);
    if (normalizedEventId.isEmpty) {
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
        message: '다시 알릴 중요 일정을 찾지 못했습니다.',
      );
    }
    return scheduleEventReminderWithResult(
      id: notificationIdFor('$normalizedEventId:critical_remind_tomorrow'),
      title: '중요 일정 다시 확인',
      body: '어제 미룬 중요 일정이 있어요. 확인해 주세요.',
      notifyAt: notifyAt,
      payload: 'event:$normalizedEventId',
    );
  }

  @visibleForTesting
  static DateTime nextCriticalReminderAt(DateTime now) {
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
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
          actions: _departureActions,
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

  /// Cancels the exact notification that delivered an action response. Android
  /// actions can arrive in a headless Flutter engine after process death; the
  /// response ID is the authoritative identity and must be dismissed before any
  /// event lookup or preference persistence can delay/fail.
  Future<void> cancelResponseNotification(int? notificationId) async {
    if (notificationId == null) return;
    // Android cancellation does not require callback/channel initialization.
    // A headless action must not wait for channel setup or permission prompts.
    await _plugin.cancel(id: notificationId);
  }

  Future<void> cancelEventNotifications(String eventId) async {
    // 강한알람 preflight 체인(generation + 그 generation 소유 headless 알람/
    // 소리 알림)을 먼저 무효화해 대기 중인 실행이 부활시키지 못하게 한다.
    await CriticalAlarmPreflightService.cancelScheduledPreflight(
      eventId,
      notifications: this,
    );
    final now = DateTime.now();
    for (final kind in ['push', 'critical', 'departure']) {
      for (final key in eventAlarmCancellationKeys('$eventId:$kind', now)) {
        await cancel(notificationIdFor(key));
      }
    }
    await cancelSmartPreparationAlarms(eventId);
    await cancelPreActionAlarms(eventId);
  }

  /// Cancels the three dated channels for the acknowledged occurrence.
  Future<void> cancelCriticalAlarmOccurrence(
    String eventId,
    CriticalAlarmOccurrence occurrence,
  ) async {
    for (final kind in ['push', 'critical', 'departure']) {
      await cancel(notificationIdFor(occurrence.alarmKey(eventId, kind)));
    }
  }

  /// Cancels only the event reminder channels. Departure and smart-prep
  /// alarms belong to separate user actions and must not be cleared when a
  /// user acknowledges or opens the event reminder itself.
  Future<void> cancelEventReminderNotifications(String eventId) async {
    await cancel(notificationIdFor('$eventId:push'));
    await cancel(notificationIdFor('$eventId:critical'));
    await CriticalAlarmPreflightService.cancelScheduledPreflight(
      eventId,
      notifications: this,
    );
  }

  /// 예약 대기 중 알림 목록(정리용). 테스트에서 대체할 수 있도록 분리했다.
  @protected
  Future<List<PendingNotificationRequest>> pendingRequestsForCleanup() async {
    await initialize();
    return _plugin.pendingNotificationRequests();
  }

  /// 동적 강한알람 체인이 출발 타이밍을 소유하는 일정에서, 이미 예약된
  /// 스마트 준비/사전 액션의 "출발만" 안내(옛 이동시간 기준)를 취소한다.
  /// 실제 준비 안내와 병합된 준비 문구는 보존한다. 취소 개수를 반환한다.
  Future<int> cancelDepartureOnlyPreparationPrompts(String eventId) async {
    final normalized = eventId.trim();
    if (normalized.isEmpty) {
      return 0;
    }
    final candidateIds = <int>{
      for (var index = 0;
          index < _maxSmartPreparationAlarmsPerEvent;
          index += 1) ...<int>[
        notificationIdFor('$normalized:smart_preparation:$index'),
        notificationIdFor('$normalized:pre_action:$index'),
      ],
    };
    final pending = await pendingRequestsForCleanup();
    var cancelled = 0;
    for (final request in pending) {
      if (!candidateIds.contains(request.id)) {
        continue;
      }
      final firstLine = (request.body ?? '').split('\n').first.trim();
      const prefix = '스마트 준비 알람:';
      final promptTitle = firstLine.startsWith(prefix)
          ? firstLine.substring(prefix.length).trim()
          : firstLine;
      if (CriticalAlarmPreflightService.isDepartureOnlyPromptTitle(
        promptTitle,
      )) {
        await cancel(request.id);
        cancelled += 1;
      }
    }
    return cancelled;
  }

  Future<void> cancelDepartureNotifications(String eventId) async {
    for (final key in eventAlarmCancellationKeys(
      '$eventId:departure',
      DateTime.now(),
    )) {
      await cancelDepartureSlot(key);
    }
  }

  Future<void> cancelDepartureOccurrence(
    String eventId,
    CriticalAlarmOccurrence occurrence,
  ) =>
      cancelDepartureSlot(occurrence.alarmKey(eventId, 'departure'));

  Future<void> cancelDepartureSlot(String key) async {
    await cancel(notificationIdFor(key));
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await AndroidAlarmManager.cancel(
        _stableNotificationId(
            key.replaceFirst(':departure', ':departure_preflight')),
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
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await initialize();
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final permissions = await ios?.checkPermissions();
        return NotificationPermissionStatus(
          notificationsEnabled: permissions?.isEnabled ?? false,
          exactAlarmsEnabled: null,
          fullScreenIntentStatus: PermissionCheckState.unsupported,
        );
      } catch (error, stackTrace) {
        debugPrint('iOS notification permission check failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return const NotificationPermissionStatus(
          notificationsEnabled: false,
          exactAlarmsEnabled: null,
          fullScreenIntentStatus: PermissionCheckState.unsupported,
        );
      }
    }
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

    // 권한이 미허용이면 알람이 안 울리는 직접 원인이므로 기기 진단로그에 남긴다.
    if (!notificationsEnabled || !exactAlarmsEnabled) {
      DiagLogger.log(
        'AlarmPerm',
        '권한 미허용 → 알람 누락 가능: notifications=$notificationsEnabled '
            'exact=$exactAlarmsEnabled',
      );
    }

    return NotificationPermissionStatus(
      notificationsEnabled: notificationsEnabled,
      exactAlarmsEnabled: exactAlarmsEnabled,
      fullScreenIntentStatus: await _checkFullScreenIntentStatus(),
    );
  }

  Future<NotificationPermissionStatus> requestAndCheckPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await requestNotificationPermission();
      return checkPermissionStatus();
    }
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
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final requested = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        if (requested != null) {
          return requested;
        }
      } catch (error, stackTrace) {
        debugPrint('iOS notification permission request failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return false;
      }
      return (await checkPermissionStatus()).notificationsEnabled == true;
    }
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
    if (status.fullScreenIntentStatus == PermissionCheckState.granted) {
      return true;
    }
    if (status.fullScreenIntentStatus == PermissionCheckState.denied ||
        requestResult == false) {
      return false;
    }
    // 일부 Android/OEM 조합은 전체 화면 권한의 현재 상태를 반환하지 않는다.
    // 그 경우 intent 자체를 빼면 시스템이 허용할 수 있는 출발 화면까지 막힌다.
    return true;
  }

  Future<bool> openAppNotificationSettings() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        return await _iosPermissionsChannel.invokeMethod<bool>(
              'openAppSettings',
            ) ??
            false;
      } catch (error, stackTrace) {
        debugPrint('Open iOS notification settings failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return false;
      }
    }
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
    final initializationSettings = InitializationSettings(
      android: const AndroidInitializationSettings('ic_stat_planflow'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
        defaultPresentAlert: true,
        defaultPresentSound: true,
        defaultPresentBadge: true,
        defaultPresentBanner: true,
        defaultPresentList: true,
        notificationCategories: <DarwinNotificationCategory>[
          criticalAlarmDarwinCategory,
        ],
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
        notificationCategories: <DarwinNotificationCategory>[
          criticalAlarmDarwinCategory,
        ],
      ),
      linux: const LinuxInitializationSettings(defaultActionName: '알림 열기'),
    );

    await _plugin.initialize(
      settings: initializationSettings,
      onDidReceiveBackgroundNotificationResponse:
          _backgroundNotificationResponseCallback,
      onDidReceiveNotificationResponse: (response) {
        // Handle the response before navigation. A recurring critical body
        // tap forwards its occurrence to the detail confirmation.
        unawaited(() async {
          await handleNotificationResponseAction(response);
          final route = routeForNotificationResponse(response);
          if (route != null) appRouter.go(route);
        }());
      },
    );
    await _ensureAndroidNotificationChannels();
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      await _runPermissionRequestBestEffort(
        'initial notification permission',
        _requestNotificationPermissionIfNeeded,
      );
    }
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
        // 일반 일정 알림은 알람 스트림까지 올릴 필요는 없어 기본값
        // (AudioAttributesUsage.notification)을 그대로 둔다.
      ),
    );
    await android.createNotificationChannel(
      AndroidNotificationChannel(
        criticalAlarmChannelId,
        _criticalAlarmChannelName,
        description: _criticalAlarmChannelDescription,
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
          criticalAlarmSoundResource,
        ),
        enableVibration: true,
        vibrationPattern: Int64List.fromList(
          <int>[0, 1200, 250, 1200, 250, 1600],
        ),
        // 중요 알람/출발 알람은 방해금지·알림음 소거에도 덜 묻히도록
        // 알람 오디오 스트림을 쓴다. raw 사운드 리소스와 alarm usage를
        // 함께 쓰는 조합은 과거(fa66fc0) "불안정" 사유로 한 번 제거된
        // 적이 있으나, 커밋 메시지에 구체적 실패 증상은 남아있지 않다.
        // 이번 재도입은 채널 id를 함께 bump해 기존 채널의 불변 설정과
        // 충돌하지 않도록 했다 — 재발 시 이 조합(raw sound + alarm
        // usage)을 1순위 의심 대상으로 본다.
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ),
    );
    await android.createNotificationChannel(
      AndroidNotificationChannel(
        importantAlarmChannelId,
        _criticalAlarmChannelName,
        description: _criticalAlarmChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 300, 120, 300]),
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    );

    await _deleteLegacyChannels(android);
  }

  /// 채널 id를 bump할 때마다 남는 구 채널을 정리한다. 현재 사용 중인
  /// 현재 사용하는 세 채널은 절대 지우지 않는다.
  Future<void> _deleteLegacyChannels(
    AndroidFlutterLocalNotificationsPlugin android,
  ) async {
    final legacyIds = <String>{
      ...legacyEventReminderChannelIds,
      ...legacyCriticalAlarmChannelIds,
    }..removeWhere(
        (id) =>
            id == eventReminderChannelId ||
            id == criticalAlarmChannelId ||
            id == importantAlarmChannelId,
      );

    for (final legacyId in legacyIds) {
      try {
        await android.deleteNotificationChannel(channelId: legacyId);
      } catch (error, stackTrace) {
        // 존재하지 않는 채널을 지우려 하면 플랫폼에 따라 예외가 날 수
        // 있다. best-effort 정리이므로 무시하고 계속 진행한다.
        debugPrint('Delete legacy notification channel failed ($legacyId): '
            '$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  Future<void> _runPermissionRequestBestEffort(
    String label,
    Future<void> Function() request,
  ) async {
    if (!allowPermissionRequests) {
      // headless/백그라운드 실행: 권한 요청 UI를 띄우지 않는다.
      return;
    }
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
        playSound: true,
        enableVibration: true,
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
        actions: _departureActions,
        audioAttributesUsage: AudioAttributesUsage.alarm,
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
    bool useStrongAlarm = true,
  }) {
    final channelId =
        useStrongAlarm ? criticalAlarmChannelId : importantAlarmChannelId;
    final sound = useStrongAlarm
        ? RawResourceAndroidNotificationSound(criticalAlarmSoundResource)
        : null;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        _criticalAlarmChannelName,
        channelDescription: _criticalAlarmChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
          summaryText: '놓치면 안 되는 중요 알람',
        ),
        category: AndroidNotificationCategory.event,
        fullScreenIntent: false,
        channelAction: AndroidNotificationChannelAction.update,
        playSound: true,
        sound: sound,
        enableVibration: true,
        autoCancel: true,
        vibrationPattern: Int64List.fromList(
          useStrongAlarm
              ? <int>[0, 1200, 250, 1200, 250, 1600]
              : <int>[0, 300, 120, 300],
        ),
        visibility: NotificationVisibility.public,
        ticker: '중요 일정 알림',
        actions: _criticalActions,
        audioAttributesUsage: useStrongAlarm
            ? AudioAttributesUsage.alarm
            : AudioAttributesUsage.notification,
      ),
      // 강한알람 iOS: 커스텀 사운드(Runner 번들 wav)를 지정하지 않으면 기본
      // 짧은 알림음만 울린다. critical-alerts entitlement가 없으므로
      // InterruptionLevel.critical은 무시/거부될 수 있어 timeSensitive로
      // 요청한다 (entitlement 없이 허용되는 최상위 수준).
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        sound: criticalAlarmIosSoundName,
        interruptionLevel: InterruptionLevel.timeSensitive,
        categoryIdentifier: criticalAlarmCategoryId,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        sound: criticalAlarmIosSoundName,
        interruptionLevel: InterruptionLevel.timeSensitive,
        categoryIdentifier: criticalAlarmCategoryId,
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

  /// 앱이 완전히 종료된 상태(cold start)에서 알림을 눌러 실행된 경우의
  /// 목적지 라우트를 반환한다. onDidReceiveNotificationResponse는 프로세스가
  /// 살아있을 때만 호출되므로, 새벽 브리핑처럼 앱이 꺼져 있을 때 울리는
  /// 알림은 이 경로로만 딥링크를 잡을 수 있다.
  Future<String?> resolveColdStartLaunchRoute() async {
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails == null || !launchDetails.didNotificationLaunchApp) {
      DiagLogger.log('LaunchSignal',
          'notification cold-start kind=none decision=passthrough');
      return null;
    }
    final response = launchDetails.notificationResponse;
    if (response == null) {
      DiagLogger.log('LaunchSignal',
          'notification cold-start kind=none decision=passthrough');
      return null;
    }
    // Cold-start body taps use this path instead of the foreground callback;
    // apply the same cancellation semantics before returning the route.
    await handleNotificationResponseAction(response, notificationService: this);
    final kind = classifyNaverIcsReminderPayload(response.payload);
    if (kind == NaverIcsReminderPayloadKind.legacy) {
      DiagLogger.log('LaunchSignal',
          'notification cold-start kind=naver_ics_legacy decision=skip-legacy');
      return null;
    }
    if (kind == NaverIcsReminderPayloadKind.malformed) {
      DiagLogger.log('LaunchSignal',
          'notification cold-start kind=naver_ics_malformed decision=skip-malformed');
      return null;
    }
    if (kind == NaverIcsReminderPayloadKind.tokened) {
      // banned-ok: reminder payload is a calendar date marker, not an API credential.
      final token = response.payload!;
      if (await _launchSignalLedger.lastNaverReminderToken() == token) {
        DiagLogger.log('LaunchSignal',
            'notification cold-start kind=naver_ics_tokened decision=skip-already-handled');
        return null;
      }
      final date = naverIcsReminderDateFromPayload(token)!;
      final scheduled = DateTime(date.year, date.month, date.day, 9);
      final now = _now();
      if (now.difference(scheduled) > const Duration(days: 7)) {
        DiagLogger.log('LaunchSignal',
            'notification cold-start kind=naver_ics_tokened decision=skip-stale');
        return null;
      }
      if (scheduled.difference(now) > const Duration(days: 1)) {
        DiagLogger.log('LaunchSignal',
            'notification cold-start kind=naver_ics_tokened decision=skip-future');
        return null;
      }
      await _launchSignalLedger.markNaverReminderToken(token);
      DiagLogger.log('LaunchSignal',
          'notification cold-start kind=naver_ics_tokened decision=route');
      return AppRoutes.naverIcsImport;
    }
    final payload = response.payload ?? '';
    final otherKind = payload.isEmpty
        ? 'none'
        : payload.startsWith('briefing:')
            ? 'briefing'
            : payload.startsWith('event:')
                ? 'event'
                : payload.startsWith('departure:')
                    ? 'departure'
                    : 'other';
    DiagLogger.log('LaunchSignal',
        'notification cold-start kind=$otherKind decision=passthrough');
    return routeForNotificationResponse(response);
  }

  @visibleForTesting
  static String? routeForNotificationResponse(NotificationResponse response) {
    if (classifyNaverIcsReminderPayload(response.payload) ==
            NaverIcsReminderPayloadKind.legacy ||
        classifyNaverIcsReminderPayload(response.payload) ==
            NaverIcsReminderPayloadKind.tokened) {
      return AppRoutes.naverIcsImport;
    }

    final payload = response.payload ?? '';
    if (payload == 'briefing:morning' || payload == 'briefing:evening') {
      final type = payload.endsWith('evening') ? 'evening' : 'morning';
      return '${AppRoutes.briefing}?type=$type';
    }

    if (payload.startsWith('event:')) {
      if (response.actionId == criticalRemindTomorrowActionId) {
        return null;
      }
      if (response.actionId == criticalAcknowledgedActionId) {
        return null;
      }
      final event = _eventFromPayload(payload);
      if (event.id.isEmpty) {
        return null;
      }
      final query = <String, String>{
        if (_isCriticalAlarmPayload(payload)) 'criticalAck': '1',
        if (event.occurrence case final occurrence?)
          CriticalAlarmOccurrence.routeQueryKey: occurrence.token,
      };
      return Uri(
        path: '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
        queryParameters: query.isEmpty ? null : query,
      ).toString();
    }

    if (payload.startsWith('departure:')) {
      final eventId = _departureFromPayload(payload).id;
      if (eventId.isEmpty) {
        return null;
      }
      if (response.actionId == departureAcknowledgedActionId) {
        return null;
      }
      return '${AppRoutes.departureAlarm}'
          '?eventId=${Uri.encodeComponent(eventId)}';
    }

    return null;
  }

  /// [scheduleCriticalAlarmWithResult]가 예약 직전 payload에
  /// [criticalAlarmPayloadSuffix]를 붙인다. `event:` prefix가 아닌 payload
  /// (예: null)는 손대지 않고, 이미 suffix가 붙어 있으면 중복으로 붙이지
  /// 않는다.
  static String? _criticalAlarmPayload(String? payload) {
    if (payload == null || !payload.startsWith('event:')) {
      return payload;
    }
    if (payload.endsWith(criticalAlarmPayloadSuffix)) {
      return payload;
    }
    return '$payload$criticalAlarmPayloadSuffix';
  }

  /// [payload]가 강한알람(critical alarm) 채널에서 예약된 `event:` payload인지
  /// 판정한다.
  static bool _isCriticalAlarmPayload(String payload) {
    return payload.startsWith('event:') &&
        payload.endsWith(criticalAlarmPayloadSuffix);
  }

  static String departurePayloadFor(
    String eventId, {
    CriticalAlarmOccurrence? occurrence,
  }) =>
      occurrence == null
          ? 'departure:$eventId'
          : 'departure:$eventId${CriticalAlarmOccurrence._payloadMarker}${occurrence.token}';

  static String departureAcknowledgementKey(
    String eventId,
    CriticalAlarmOccurrence occurrence,
  ) =>
      '$eventId:departure:${occurrence.token}';

  static ({String id, CriticalAlarmOccurrence? occurrence})
      _departureFromPayload(String payload) {
    final value = payload.substring('departure:'.length);
    const marker = CriticalAlarmOccurrence._payloadMarker;
    final markerIndex = value.lastIndexOf(marker);
    if (markerIndex < 0) return (id: value.trim(), occurrence: null);
    final occurrence = CriticalAlarmOccurrence.tryParse(
      value.substring(markerIndex + marker.length),
    );
    if (occurrence == null) return (id: '', occurrence: null);
    return (id: value.substring(0, markerIndex).trim(), occurrence: occurrence);
  }

  static ({String id, CriticalAlarmOccurrence? occurrence}) _eventFromPayload(
    String payload,
  ) {
    var value = payload.substring('event:'.length);
    if (_isCriticalAlarmPayload(payload)) {
      value =
          value.substring(0, value.length - criticalAlarmPayloadSuffix.length);
      final marker = CriticalAlarmOccurrence._payloadMarker;
      final markerIndex = value.lastIndexOf(marker);
      if (markerIndex >= 0) {
        final occurrence = CriticalAlarmOccurrence.tryParse(
          value.substring(markerIndex + marker.length),
        );
        if (occurrence == null) return (id: '', occurrence: null);
        return (
          id: value.substring(0, markerIndex).trim(),
          occurrence: occurrence
        );
      }
    }
    return (id: value.trim(), occurrence: null);
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

  String _criticalAlarmPermissionMessage(NotificationPermissionStatus status) {
    final blockers = <String>[];
    if (status.notificationsEnabled == false) {
      blockers.add('앱 알림');
    }

    final blockerText =
        blockers.isEmpty ? 'Android 알림 설정' : blockers.join(', ');
    return '중요 알림을 예약하려면 $blockerText 권한이 필요합니다. '
        '휴대폰 설정에서 PlanFlow 알림과 알람 및 리마인더 허용 상태를 확인해 주세요.';
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

  /// 진단용: [eventReminderChannelId] 채널로 즉시 테스트 알림을 1건 발송한다.
  /// 이 알림이 뜨고 소리가 나면 알림 표시 자체는 정상 → 스케줄/타이밍 문제로 범위 좁힘.
  /// 알림이 전혀 안 뜨면 채널 또는 시스템 차단으로 확정.
  Future<void> showDiagnosticTestNotification() async {
    await initialize();
    final now = DateTime.now();
    final timeLabel =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    await _plugin.show(
      id: _stableNotificationId('diag_test_notification'),
      title: 'PlanFlow 테스트 알림',
      body: '알림 표시 진단 — $timeLabel 발송',
      notificationDetails: _eventReminderDetails(),
      payload: 'diag_test',
    );
  }

  /// 현재 예약된 알림(pendingNotificationRequests) 개수를 반환한다.
  Future<int> pendingNotificationCount() async {
    await initialize();
    final pending = await _plugin.pendingNotificationRequests();
    return pending.length;
  }
}

/// foreground/background 알림 액션을 같은 방식으로 처리한다.
///
/// 출발은 즉시 확인 상태로 바꾸고, 중요 알람의 내일 액션은 일정 자체를
/// 수정하지 않은 채 다음 날 오전 9시에 다시 확인하도록 예약한다.
///
/// 중요 알람의 "확인(출발)"은 같은 시작 시각이 다시 예약되지 않도록
/// 확인을 기록한다. 반복 알림은 응답을 보낸 회차만 취소한다.
@visibleForTesting
Future<void> handleNotificationResponseAction(
  NotificationResponse response, {
  NotificationService? notificationService,
  DepartureAcknowledgementStore? departureAcknowledgementStore,
  CriticalAlarmAcknowledgementStore? criticalAlarmAcknowledgementStore,
  EventRepository? eventRepository,
}) async {
  final payload = response.payload ?? '';
  final actionId = response.actionId;
  if (actionId == NotificationService.departureAcknowledgedActionId &&
      payload.startsWith('departure:')) {
    final departure = NotificationService._departureFromPayload(payload);
    final eventId = departure.id;
    final occurrence = departure.occurrence;
    if (eventId.isNotEmpty) {
      final store = departureAcknowledgementStore ??
          const SharedPreferencesDepartureAcknowledgementStore();
      final notifications = notificationService ??
          NotificationService(allowPermissionRequests: false);
      await notifications.cancelResponseNotification(response.id);
      // Persist after dismissal so preference latency cannot leave it sounding.
      if (occurrence == null) {
        // Older payloads have no occurrence identity. The response ID was
        // dismissed above; clear only the legacy slot shared by those payloads.
        await notifications.cancelDepartureSlot('$eventId:departure');
        await store.markAcknowledged(eventId);
      } else {
        try {
          await store.markAcknowledged(
            NotificationService.departureAcknowledgementKey(
                eventId, occurrence),
          );
        } finally {
          await notifications.cancelDepartureOccurrence(eventId, occurrence);
        }
      }
    }
    return;
  }

  if (actionId == NotificationService.criticalRemindTomorrowActionId &&
      payload.startsWith('event:')) {
    final event = NotificationService._eventFromPayload(payload);
    if (event.id.isNotEmpty) {
      await (notificationService ?? NotificationService())
          .scheduleCriticalReminderTomorrow(eventId: event.id);
    }
    return;
  }

  final isCriticalAcknowledgement =
      actionId == NotificationService.criticalAcknowledgedActionId;
  if (payload.startsWith('event:') &&
      (isCriticalAcknowledgement ||
          response.notificationResponseType ==
              NotificationResponseType.selectedNotification)) {
    final event = NotificationService._eventFromPayload(payload);
    final eventId = event.id;
    if (eventId.isNotEmpty) {
      final notifications = notificationService ??
          NotificationService(allowPermissionRequests: false);
      final occurrence = event.occurrence;
      if (occurrence != null) {
        if (isCriticalAcknowledgement) {
          try {
            await notifications.cancelResponseNotification(response.id);
          } finally {
            await _persistCriticalAcknowledge(
              eventId: eventId,
              occurrence: occurrence,
              criticalAlarmAcknowledgementStore:
                  criticalAlarmAcknowledgementStore,
              eventRepository: eventRepository,
            );
            await notifications.cancelCriticalAlarmOccurrence(
                eventId, occurrence);
          }
        }
        return;
      }
      // 중요 알람 액션은 같은 event로 묶인 모든 로컬 알림(푸시/중요/출발/
      // 스마트 준비/사전 액션)을 함께 취소한다. 단순 body 탭은 리마인더만
      // 취소해 출발/스마트 준비는 유지한다(사용자 의도 분리).
      if (isCriticalAcknowledgement) {
        // Cancel the exact posted alarm first. This dismisses Android's
        // sound/vibration with the notification and remains safe to repeat.
        // Event-derived sibling cancellation is additional cleanup, not the
        // identity source for the notification that invoked this action.
        await notifications.cancelResponseNotification(response.id);
        try {
          await notifications.cancelEventNotifications(eventId);
        } finally {
          // Even a failed sibling cleanup must not leave this event eligible
          // for a later preflight re-ring when the acknowledgement can persist.
          await _persistCriticalAcknowledge(
            eventId: eventId,
            criticalAlarmAcknowledgementStore:
                criticalAlarmAcknowledgementStore,
            eventRepository: eventRepository,
          );
        }
      } else {
        await notifications.cancelEventReminderNotifications(eventId);
      }
    }
  }
}

/// 강한알람 확인을 영구화한다.
///
/// 회차 정보가 없는 기존 payload만 저장소에서 시작 시각을 조회한다.
/// 조회가 실패하면 [unknownStartSentinel]을 기록한다.
///
/// 백그라운드 isolate 액션 경로에서는 SharedPreferences가 일시적으로
/// 끊길 수 있다(tryGetPrefs가 false 반환). 이 경로에서는 store 호출 실패를
/// 삼키고 알림 정지만 보장한다(다음 실행에서 재시도).
Future<void> _persistCriticalAcknowledge({
  required String eventId,
  CriticalAlarmOccurrence? occurrence,
  required CriticalAlarmAcknowledgementStore? criticalAlarmAcknowledgementStore,
  required EventRepository? eventRepository,
}) async {
  final store = criticalAlarmAcknowledgementStore ??
      const SharedPreferencesCriticalAlarmAcknowledgementStore();
  DateTime? startAt = occurrence?.startAt;
  if (occurrence == null) {
    try {
      final repository = eventRepository ?? EventRepository.supabase();
      final event = await repository.fetchEvent(eventId);
      startAt = event?.startAt;
    } catch (error, stackTrace) {
      debugPrint('Critical ack startAt lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  try {
    await store.markAcknowledged(
      occurrence?.acknowledgementKey(eventId) ?? eventId,
      startAt ?? unknownStartSentinel,
    );
  } catch (error, stackTrace) {
    debugPrint('Critical ack store write failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

/// 앱이 백그라운드 상태에서 알림 액션 버튼 탭 시 호출되는 top-level 콜백.
/// flutter_local_notifications 요구사항: @pragma('vm:entry-point') + top-level 함수.
@pragma('vm:entry-point')
Future<void> _backgroundNotificationResponseCallback(
  NotificationResponse response,
) {
  return handleNotificationResponseAction(response);
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
