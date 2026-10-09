import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/supabase_auth_options.dart';
import '../data/models/event_model.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'alarm_service.dart';
import 'app_permission_service.dart';
import 'critical_alarm_acknowledgement_store.dart';
import 'map_service.dart';
import 'notification_service.dart';
import 'travel_time_buffer_service.dart';

/// 강한알람(Android, 좌표 있는 강한 중요 일정)의 기존 트리거 시각 직전 재계산.
///
/// 기존 트리거(예: 13:00 일정의 60분 전 12:00)에는 소리 대신 headless
/// preflight 알람만 깨어나 신선한 현재 GPS + 기존 경로 API(TMAP→Naver→Google,
/// DepartureAlarmService와 같은 체인) + 저장된 사용자 설정(이동수단, 출발 여유)
/// 으로 출발 시각을 다시 계산한다. 출발 시각이 미래면 조용히 재무장(12:30)하고
/// 새 트리거에서 다시 계산한다. 출발 시각이 지났으면 바로 울린다.
///
/// 소유권: 모든 preflight 산출물(headless 알람, 소리나는 watchdog/즉시 울림)은
/// generation별 ID를 쓴다. 다른(새) generation의 산출물은 절대 건드리지
/// 않으므로, 늦게 끝난 오래된 실행이 새 예약을 취소/덮어쓰지 못한다.
///
/// 실패 안전: 위치/설정/경로/이벤트 조회 실패·시간초과·휴리스틱 추정은
/// 연기 근거가 될 수 없고 즉시 울린다. 콜백 자체가 죽으면 트리거+
/// [watchdogDelay]의 watchdog이 늦게라도 울린다.
///
/// iOS: 백그라운드/종료 상태에서 소리 전에 Dart GPS를 돌릴 수 없으므로
/// 기존 OS 로컬 알람(legacy)을 그대로 쓴다(사전 재계산 불가, 차단 보고).
typedef CriticalPreflightScheduler = Future<bool> Function(
  CriticalPreflightRequest request,
);

typedef CriticalPreflightCanceller = Future<bool> Function(int alarmId);

/// preflight 단계별 시간 상한. 합계([total])는 watchdog 지연보다 충분히
/// 작아야 한다(헤드리스 엔진 기동 여유 포함).
class CriticalPreflightBudget {
  const CriticalPreflightBudget({
    this.total = const Duration(seconds: 47),
    this.supabaseInit = const Duration(seconds: 10),
    this.eventFetch = const Duration(seconds: 8),
    this.location = const Duration(seconds: 15),
    this.settings = const Duration(seconds: 6),
    this.route = const Duration(seconds: 18),
  });

  final Duration total;
  final Duration supabaseInit;
  final Duration eventFetch;
  final Duration location;
  final Duration settings;
  final Duration route;
}

/// headless 알람 params로 직렬화되는 preflight 요청. 원래 강한알람의
/// 표시 정보와 occurrence(시작 시각)를 함께 보존해, 원격 조회가 실패해도
/// 같은 알람을 즉시 울릴 수 있고 ACK는 occurrence 단위로 검사한다.
class CriticalPreflightRequest {
  const CriticalPreflightRequest({
    required this.eventId,
    required this.userId,
    required this.generation,
    required this.triggerAt,
    DateTime? originalTriggerAt,
    required this.occurrenceStartAt,
    required this.title,
    this.body,
    this.payload,
    this.useStrongAlarm = true,
  }) : originalTriggerAt = originalTriggerAt ?? triggerAt;

  final String eventId;
  final String userId;
  final String generation;
  final DateTime triggerAt;
  final DateTime originalTriggerAt;
  final DateTime occurrenceStartAt;
  final String title;
  final String? body;
  final String? payload;
  final bool useStrongAlarm;

  CriticalPreflightRequest rearmedAt(DateTime nextTrigger) {
    return CriticalPreflightRequest(
      eventId: eventId,
      userId: userId,
      generation: generation,
      triggerAt: nextTrigger,
      originalTriggerAt: originalTriggerAt,
      occurrenceStartAt: occurrenceStartAt,
      title: title,
      body: body,
      payload: payload,
      useStrongAlarm: useStrongAlarm,
    );
  }

  Map<String, dynamic> toParams() => <String, dynamic>{
        'event_id': eventId,
        'user_id': userId,
        'generation': generation,
        'trigger_at': triggerAt.toUtc().toIso8601String(),
        'original_trigger_at': originalTriggerAt.toUtc().toIso8601String(),
        'start_at': occurrenceStartAt.toUtc().toIso8601String(),
        'title': title,
        'body': body,
        'payload': payload,
        'strong': useStrongAlarm,
      };

  static CriticalPreflightRequest? fromParams(Map<String, dynamic> params) {
    String? text(String key) {
      final value = params[key];
      if (value is! String) {
        return null;
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final eventId = text('event_id');
    final userId = text('user_id');
    final generation = text('generation');
    final startAt = DateTime.tryParse(text('start_at') ?? '');
    final triggerAt = DateTime.tryParse(text('trigger_at') ?? '');
    if (eventId == null ||
        userId == null ||
        generation == null ||
        startAt == null ||
        triggerAt == null) {
      return null;
    }
    return CriticalPreflightRequest(
      eventId: eventId,
      userId: userId,
      generation: generation,
      triggerAt: triggerAt.toLocal(),
      originalTriggerAt:
          DateTime.tryParse(text('original_trigger_at') ?? '')?.toLocal(),
      occurrenceStartAt: startAt.toLocal(),
      title: text('title') ?? '중요 일정',
      body: text('body'),
      payload: text('payload'),
      useStrongAlarm: params['strong'] != false,
    );
  }
}

class _CriticalOwnership {
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const channel = MethodChannel('planflow/critical_alarm_ownership');
  static Future<T?> call<T>(String method, [Map<String, Object?>? args]) {
    if (!isSupported) {
      return Future<T?>.error(UnsupportedError('Android ownership only'));
    }
    return channel
        .invokeMethod<T>(method, args)
        .timeout(const Duration(seconds: 3));
  }

  static Future<Map<String, dynamic>?> read(String eventId) async {
    final value = await call<Map>('readOwner', {'eventId': eventId});
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  static Map<String, Object?> state(CriticalPreflightRequest request,
          {String mode = 'preflight',
          Map<String, dynamic>? protectedPreviousOwner}) =>
      {
        'eventId': request.eventId,
        'generation': request.generation,
        'triggerAt': request.triggerAt.millisecondsSinceEpoch,
        'originalNotifyAt': request.originalTriggerAt.millisecondsSinceEpoch,
        'metadataJson': jsonEncode({
          'mode': mode,
          'request': request.toParams(),
          if (protectedPreviousOwner != null)
            'protectedPreviousOwner': protectedPreviousOwner
        }),
      };
  static Future<bool> release(CriticalPreflightRequest request) async =>
      await call<bool>('releaseIfOwner', {
        'eventId': request.eventId,
        'generation': request.generation,
        'expectedTrigger': request.triggerAt.millisecondsSinceEpoch,
      }) ==
      true;
}

class CriticalAlarmPreflightService {
  const CriticalAlarmPreflightService({
    NotificationService? notificationService,
    EventRepository? eventRepository,
    SettingsRepository? settingsRepository,
    AppPermissionService? permissionService,
    TravelTimeBufferService? travelTimeBufferService,
    CriticalAlarmAcknowledgementStore? acknowledgementStore,
    Future<GeoPoint?> Function()? freshLocationProvider,
    CriticalPreflightScheduler? preflightScheduler,
    CriticalPreflightCanceller? preflightCanceller,
    DateTime Function()? now,
    bool? supabaseReadyOverride,
    bool? androidOverride,
    CriticalPreflightBudget budget = const CriticalPreflightBudget(),
  })  : _notificationService = notificationService,
        _eventRepository = eventRepository,
        _settingsRepository = settingsRepository,
        _permissionService = permissionService,
        _travelTimeBufferService = travelTimeBufferService,
        _acknowledgementStore = acknowledgementStore,
        _freshLocationProvider = freshLocationProvider,
        _preflightScheduler = preflightScheduler,
        _preflightCanceller = preflightCanceller,
        _now = now,
        _supabaseReadyOverride = supabaseReadyOverride,
        _androidOverride = androidOverride,
        _budget = budget;

  /// 기존 트리거 이후 watchdog(늦은 fail-safe 울림)까지의 지연. Supabase 초기화
  /// 상한(10초) + preflight 예산(47초) + 실패 재검증(8초) + 엔진 여유(25초).
  static const Duration watchdogDelay = Duration(seconds: 90);

  /// 출발 시각까지 이보다 짧게 남으면 headless 재무장 대신 정확히 출발
  /// 시각에 소리 알람을 예약한다(조기 울림 없음, zero-delay 재실행 루프 없음).
  static const Duration minRearmLead = Duration(seconds: 30);

  /// 출발 시각이 이미 지났을 때 즉시 울림 지연.
  static const Duration ringNowDelay = Duration(seconds: 3);

  /// DepartureAlarmService.defaultSafetyMarginMin과 동일.
  static const int defaultSafetyMarginMin = 20;

  static const String generationKeyPrefix = 'critical_preflight:gen:';
  static const String lastRunKey = 'critical_preflight_last_run';
  static const String defaultBody = '중요 일정이 곧 시작됩니다.';

  final NotificationService? _notificationService;
  final EventRepository? _eventRepository;
  final SettingsRepository? _settingsRepository;
  final AppPermissionService? _permissionService;
  final TravelTimeBufferService? _travelTimeBufferService;
  final CriticalAlarmAcknowledgementStore? _acknowledgementStore;
  final Future<GeoPoint?> Function()? _freshLocationProvider;
  final CriticalPreflightScheduler? _preflightScheduler;
  final CriticalPreflightCanceller? _preflightCanceller;
  final DateTime Function()? _now;
  final bool? _supabaseReadyOverride;
  final bool? _androidOverride;
  final CriticalPreflightBudget _budget;

  NotificationService get _notifications =>
      _notificationService ??
      NotificationService(allowPermissionRequests: false);

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();

  SettingsRepository get _settings =>
      _settingsRepository ?? SettingsRepository.supabase();

  AppPermissionService get _permissions =>
      _permissionService ?? AppPermissionService();

  TravelTimeBufferService _travelFor(UserSettingsModel settings) =>
      _travelTimeBufferService ??
      TravelTimeBufferService(
        googleMapsApiKey: settings.preferredMapProvider == 'google' ? null : '',
        mapService: MapService(
          allowTransitCarFallback: false,
          tmapApiKey: settings.preferredMapProvider == 'tmap' ? null : '',
          naverProxyUrl: settings.preferredMapProvider == 'naver' ? null : '',
          naverClientId: settings.preferredMapProvider == 'naver' ? null : '',
        ),
      );

  // AlarmManager callbacks within an engine must not overlap for one trigger.
  static final Set<String> _runningTriggers = <String>{};

  CriticalAlarmAcknowledgementStore get _acks =>
      _acknowledgementStore ??
      const SharedPreferencesCriticalAlarmAcknowledgementStore();

  DateTime get _currentTime => (_now ?? DateTime.now)();

  bool get _isAndroid =>
      _androidOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  bool get _supabaseReady => _supabaseReadyOverride ?? AppEnv.isSupabaseReady;

  // ---------------------------------------------------------------------------
  // ID / generation helpers (static: 다른 isolate·취소 훅과 공유)
  // ---------------------------------------------------------------------------

  static String audibleKeyFor(String eventId, String generation) =>
      '${eventId.trim()}:critical_audible:$generation';

  static int preflightAlarmIdFor(String eventId, String generation) =>
      stableAlarmIdFor('${eventId.trim()}:critical_preflight:$generation');

  static Future<SharedPreferences?> _reloadedPrefs() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      return preferences;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> currentGeneration(String eventId) async {
    if (!_CriticalOwnership.isSupported) return null;
    try {
      return (await _CriticalOwnership.read(eventId))?['generation'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 이 일정의 출발 타이밍을 동적 강한알람 체인이 소유 중인지(Android).
  /// 스마트 준비의 "출발만" 안내가 오래된 시각에 따로 울리지 않도록 쓴다.
  static Future<bool> isDynamicCriticalArmed(String eventId) async {
    if (!_CriticalOwnership.isSupported) return false;
    final normalized = eventId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    try {
      final owner = await _CriticalOwnership.read(normalized);
      if (owner == null) return false;
      final metadata = jsonDecode(owner['metadataJson'] as String? ?? '{}');
      return metadata is Map &&
          (metadata['mode'] == 'preflight' || metadata['mode'] == 'restoring');
    } catch (_) {
      return false;
    }
  }

  /// 출발만 알리는 스마트 준비 문구인지. 병합 문구(" / ")는 모든 조각이
  /// 출발 안내일 때만 true(실제 준비 안내가 섞이면 보존).
  static bool isDepartureOnlyPromptTitle(String title) {
    final parts = title
        .split(' / ')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return false;
    }
    final departurePart = RegExp(r'^(지금 출발하세요|\d+분 뒤 출발해야 해요)');
    return parts.every(departurePart.hasMatch);
  }

  /// 취소 훅(cancelEventNotifications 등): 현재 generation을 무효화하고 그
  /// generation 소유 산출물(headless 알람 + 소리 알림)만 취소한다.
  static Future<void> cancelScheduledPreflight(
    String eventId, {
    NotificationService? notifications,
    CriticalPreflightCanceller? alarmCanceller,
  }) async {
    if (!_CriticalOwnership.isSupported) return;
    final normalized = eventId.trim();
    if (normalized.isEmpty) {
      return;
    }
    try {
      final removed = await _CriticalOwnership.call<Map>(
          'invalidateOwner', {'eventId': normalized});
      if (removed == null) return;
      final service = CriticalAlarmPreflightService(
        notificationService: notifications,
        preflightCanceller: alarmCanceller,
      );
      await service._cancelSnapshotArtifacts(
          normalized, Map<String, dynamic>.from(removed));
    } catch (error) {
      debugPrint(
          'Critical preflight cancellation ownership unavailable: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Arm (실제 호출처: Manual.scheduleLocalNotifications / ConfirmScreen)
  // ---------------------------------------------------------------------------

  Future<NotificationScheduleResult> scheduleCriticalAlarmWithTravelRecalc({
    required EventModel event,
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    // 이전 체인(generation)과 legacy 강한알람을 먼저 무효화한다.
    await cancelScheduledPreflight(
      event.id,
      notifications: _notifications,
      alarmCanceller: _preflightCanceller,
    );
    await _safeCancel(id);

    final startAt = event.startAt;
    final now = _currentTime;
    final eligible = useStrongAlarm &&
        event.useStrongAlarm &&
        event.isCritical &&
        _isAndroid &&
        startAt != null &&
        startAt.isAfter(now) &&
        event.locationLat != null &&
        event.locationLng != null &&
        notifyAt.isAfter(now) &&
        event.userId.trim().isNotEmpty;

    Future<NotificationScheduleResult> legacy() =>
        _notifications.scheduleCriticalAlarmWithResult(
          id: id,
          title: title,
          notifyAt: notifyAt,
          body: body,
          payload: payload,
          useStrongAlarm: useStrongAlarm,
        );

    if (!eligible || !await _canArmHeadlessPreflight()) {
      // Opt-out, missing OS grant, or a failed probe keeps the original-time
      // native alarm. Never arm a silent trigger/watchdog without capability.
      return legacy();
    }

    final generation = _newGeneration();
    final request = CriticalPreflightRequest(
      eventId: event.id,
      userId: event.userId,
      generation: generation,
      triggerAt: notifyAt,
      occurrenceStartAt: startAt,
      title: title,
      body: body,
      payload: payload,
      useStrongAlarm: useStrongAlarm,
    );
    if (!await _persistGeneration(request)) return legacy();

    final preflightScheduled = await _schedulePreflightAlarm(request);
    if (!preflightScheduled) {
      if (!await _isGenerationCurrent(event.id, generation) ||
          await _isOccurrenceAcknowledged(request)) {
        await _cancelOwnedArtifacts(event.id, generation);
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.error,
          notifyAt: notifyAt,
        );
      }
      await _cancelPreflightAlarm(request.eventId, request.generation);
      return _scheduleAudible(request, at: notifyAt);
    }
    final watchdog = await _scheduleAudible(
      request,
      at: notifyAt.add(watchdogDelay),
    );
    if (!watchdog.isScheduled) {
      if (!await _isGenerationCurrent(event.id, generation) ||
          await _isOccurrenceAcknowledged(request)) {
        await _cancelOwnedArtifacts(event.id, generation);
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.error,
          notifyAt: notifyAt,
        );
      }
      await _cancelPreflightAlarm(request.eventId, request.generation);
      return _scheduleAudible(request, at: notifyAt);
    }
    if (!await _isGenerationCurrent(event.id, generation)) {
      // 동시에 더 새로운 예약이 소유권을 가져갔다: 내 산출물만 정리.
      await _cancelOwnedArtifacts(event.id, generation);
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
      );
    }
    // 동적 체인이 출발 타이밍을 소유하므로, 이미 예약된 스마트 준비의
    // "출발만" 안내(오래된 이동시간 기준)를 제거한다. 준비 안내는 보존.
    try {
      await _notifications.cancelDepartureOnlyPreparationPrompts(event.id);
    } catch (error) {
      debugPrint('Critical preflight departure prompt cleanup failed: $error');
    }
    DiagLogger.log(
      'CriticalPreflight',
      'armed event=${event.id} trigger=${notifyAt.toIso8601String()} '
          'watchdog=${notifyAt.add(watchdogDelay).toIso8601String()} '
          'gen=$generation',
    );
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }

  /// Restore only this service's still-owned pending chains after opt-in false.
  /// A failed owner/event read is reported, never guessed or migrated from prefs.
  Future<Map<String, int>> restorePendingAfterConsentRevoked() async {
    if (!_isAndroid || !_CriticalOwnership.isSupported) {
      return {'restored': 0, 'skipped': 0, 'failed': 0};
    }
    var restored = 0, skipped = 0, failed = 0;
    Map owners;
    try {
      owners = await _CriticalOwnership.call<Map>('listOwners') ??
          <String, Object?>{};
    } catch (error) {
      debugPrint('Critical preflight restore owner list unavailable: $error');
      return {'restored': 0, 'skipped': 0, 'failed': 1};
    }
    for (final entry in owners.entries) {
      try {
        final owner = Map<String, dynamic>.from(entry.value as Map);
        final metadata = jsonDecode(owner['metadataJson'] as String? ?? '{}');
        if (metadata is! Map || metadata['mode'] != 'preflight') {
          skipped++;
          continue;
        }
        final saved = CriticalPreflightRequest.fromParams(
            Map<String, dynamic>.from(metadata['request'] as Map));
        if (saved == null || saved.eventId != entry.key) {
          failed++;
          continue;
        }
        final request = CriticalPreflightRequest(
          eventId: saved.eventId,
          userId: saved.userId,
          generation: owner['generation'] as String,
          triggerAt:
              DateTime.fromMillisecondsSinceEpoch(owner['triggerAt'] as int),
          originalTriggerAt: DateTime.fromMillisecondsSinceEpoch(
              owner['originalNotifyAt'] as int),
          occurrenceStartAt: saved.occurrenceStartAt,
          title: saved.title,
          body: saved.body,
          payload: saved.payload,
          useStrongAlarm: saved.useStrongAlarm,
        );
        if (await _isOccurrenceAcknowledged(request)) {
          await _releaseGeneration(request);
          skipped++;
          continue;
        }
        final fetched = await _fetchEvent(request, _budget.eventFetch);
        if (fetched.failed) {
          failed++;
          continue;
        }
        final event = fetched.event;
        if (event == null ||
            !_matchesOccurrence(event, request) ||
            !request.occurrenceStartAt.isAfter(_currentTime)) {
          await _releaseGeneration(request);
          skipped++;
          continue;
        }
        final now = _currentTime;
        final at = request.originalTriggerAt.isAfter(now)
            ? request.originalTriggerAt
            : now.add(ringNowDelay);
        final replacement = CriticalPreflightRequest(
          eventId: request.eventId,
          userId: request.userId,
          generation: _newGeneration(),
          triggerAt: at,
          originalTriggerAt: request.originalTriggerAt,
          occurrenceStartAt: request.occurrenceStartAt,
          title: event.title,
          body: request.body,
          payload: request.payload,
          useStrongAlarm: request.useStrongAlarm,
        );
        final replaced =
            await _CriticalOwnership.call<bool>('replaceOwnerIfMatches', {
          ..._CriticalOwnership.state(replacement,
              mode: 'restoring', protectedPreviousOwner: owner),
          'expectedGeneration': request.generation,
          'expectedTrigger': request.triggerAt.millisecondsSinceEpoch,
        });
        if (replaced != true) {
          skipped++;
          continue;
        }
        final result =
            await _scheduleAudible(replacement, at: at, event: event);
        if (result.isScheduled) {
          final finalized =
              await _CriticalOwnership.call<bool>('replaceOwnerIfMatches', {
            ..._CriticalOwnership.state(replacement, mode: 'restored'),
            'expectedGeneration': replacement.generation,
            'expectedTrigger': replacement.triggerAt.millisecondsSinceEpoch,
          });
          if (finalized != true) {
            skipped++;
            continue;
          }
          await _cancelOwnedArtifacts(request.eventId, request.generation);
          restored++;
        } else {
          // Preserve the original watchdog until replacement is confirmed.
          final rolledBack =
              await _CriticalOwnership.call<bool>('replaceOwnerIfMatches', {
            ..._CriticalOwnership.state(request),
            'expectedGeneration': replacement.generation,
            'expectedTrigger': replacement.triggerAt.millisecondsSinceEpoch,
          });
          if (rolledBack == true) {
            await _cancelOwnedArtifacts(
                replacement.eventId, replacement.generation);
          }
          failed++;
        }
      } catch (error) {
        debugPrint('Critical preflight restore failed: $error');
        failed++;
      }
    }
    final result = {'restored': restored, 'skipped': skipped, 'failed': failed};
    debugPrint('Critical preflight consent restoration: $result');
    return result;
  }

  Future<bool> _canArmHeadlessPreflight([Duration? timeout]) async {
    try {
      return await _permissions.canUseBackgroundFreshLocation().timeout(
            timeout ?? _budget.settings,
            onTimeout: () => false,
          );
    } catch (error) {
      debugPrint('Critical preflight capability unavailable: $error');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Run (headless 콜백 본체)
  // ---------------------------------------------------------------------------

  Future<CriticalPreflightOutcome> runCriticalPreflight(
    CriticalPreflightRequest request,
  ) async {
    final token =
        '${request.eventId}:${request.generation}:${request.triggerAt.toUtc().toIso8601String()}';
    if (!_runningTriggers.add(token)) {
      return const CriticalPreflightOutcome.aborted('duplicate_trigger');
    }
    try {
      final claimed = await _CriticalOwnership.call<bool>('claimTrigger', {
        'eventId': request.eventId,
        'generation': request.generation,
        'triggerAt': request.triggerAt.millisecondsSinceEpoch,
      });
      if (claimed != true) {
        final current = await _CriticalOwnership.read(request.eventId);
        if (current?['generation'] != request.generation) {
          await _cancelOwnedArtifacts(request.eventId, request.generation);
          return const CriticalPreflightOutcome.aborted('stale_generation');
        }
        return const CriticalPreflightOutcome.aborted('duplicate_trigger');
      }
      return await _runCriticalPreflight(request);
    } catch (error) {
      debugPrint('Critical preflight ownership unavailable: $error');
      return const CriticalPreflightOutcome.watchdogKept(
          'ownership_unavailable');
    } finally {
      _runningTriggers.remove(token);
    }
  }

  Future<CriticalPreflightOutcome> _runCriticalPreflight(
    CriticalPreflightRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    Duration left(Duration step) {
      final remaining = _budget.total - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        return Duration.zero;
      }
      return remaining < step ? remaining : step;
    }

    if (!await _isGenerationCurrent(request.eventId, request.generation)) {
      await _cancelOwnedArtifacts(request.eventId, request.generation);
      return const CriticalPreflightOutcome.aborted('stale_generation');
    }
    if (await _isOccurrenceAcknowledged(request)) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('critical_acknowledged');
    }
    if (!_supabaseReady) {
      return _failSafeRing(request, null, 'supabase_unavailable');
    }

    final _Fetch fetched = await _fetchEvent(request, left(_budget.eventFetch));
    if (fetched.failed) {
      return _failSafeRing(request, null, 'event_fetch_failed');
    }
    final event = fetched.event;
    if (event == null) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('event_not_found');
    }
    if (!_matchesOccurrence(event, request)) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('event_changed');
    }
    if (!request.occurrenceStartAt.isAfter(_currentTime)) {
      return _failSafeRing(request, event, 'start_passed');
    }

    final origin = await _resolveFreshOrigin(left(_budget.location));
    if (origin == null) {
      return _failSafeRing(request, event, 'no_fresh_location');
    }

    final settings =
        await _loadSettings(request.userId, left(_budget.settings));
    if (settings == null) {
      return _failSafeRing(request, event, 'settings_unavailable');
    }

    if (!await _canArmHeadlessPreflight(left(_budget.settings))) {
      return _failSafeRing(request, event, 'consent_revoked_before_route',
          restoreOriginal: true);
    }
    final routeTimeout = left(_budget.route);
    TravelTimeBufferEstimate? estimate;
    var routeFailure = 'timeout';
    if (routeTimeout > Duration.zero) {
      try {
        estimate = await _travelFor(settings)
            .estimateWithMapApis(
              originLat: origin.latitude,
              originLng: origin.longitude,
              destinationLat: event.locationLat!,
              destinationLng: event.locationLng!,
              mode: _travelModeFromSettings(settings.travelMode),
              locationText: event.location,
              skipRemote: false,
            )
            .timeout(routeTimeout);
      } catch (error) {
        debugPrint('Critical preflight route estimate failed: $error');
        routeFailure = error is TimeoutException ? 'timeout' : 'error';
        estimate = null;
      }
    }
    if (estimate == null ||
        !_isRoutedSource(estimate.source) ||
        !_matchesProvider(estimate.source, settings.preferredMapProvider)) {
      return _failSafeRing(
        request,
        event,
        'unrouted_estimate_${estimate?.source.name ?? routeFailure}',
      );
    }
    if (estimate.buffer.isNegative) {
      return _failSafeRing(request, event, 'invalid_estimate');
    }

    final margin = Duration(
      minutes: _safetyMarginMinutes(settings.departureSafetyMarginMin),
    );
    final departAt =
        request.occurrenceStartAt.subtract(estimate.buffer + margin);

    // 모든 await 이후 실제 변경 직전 재검증(취소/ACK/삭제/편집/비활성화).
    final latestSettings =
        await _loadSettings(request.userId, left(_budget.settings));
    if (latestSettings == null ||
        latestSettings.travelMode != settings.travelMode ||
        latestSettings.preferredMapProvider != settings.preferredMapProvider ||
        latestSettings.departureSafetyMarginMin !=
            settings.departureSafetyMarginMin) {
      return _failSafeRing(request, event, 'settings_changed');
    }
    final freshness =
        await _recheck(request, left(_budget.eventFetch), routeEvent: event);
    if (freshness == _Freshness.stale) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('stale_generation');
    }
    if (freshness == _Freshness.unknown) {
      return _failSafeRing(request, event, 'recheck_failed');
    }

    if (!await _canArmHeadlessPreflight(left(_budget.settings))) {
      return _failSafeRing(request, event, 'consent_revoked_before_postpone',
          restoreOriginal: true);
    }
    final now = _currentTime;
    if (!departAt.isAfter(now)) {
      return _ring(request, event, 'due_now');
    }

    if (departAt.difference(now) < minRearmLead) {
      // 곧 출발: headless 재실행 대신 정확히 출발 시각에 울린다(조기 울림 X).
      final exact = await _scheduleAudible(request, at: departAt, event: event);
      if (!await _isGenerationCurrent(request.eventId, request.generation)) {
        await _cancelOwnedArtifacts(request.eventId, request.generation);
        return const CriticalPreflightOutcome.aborted('stale_generation');
      }
      if (exact.isScheduled) {
        return CriticalPreflightOutcome.rearmed(departAt, detail: 'exact');
      }
      return _ring(request, event, 'exact_schedule_failed');
    }

    final advanced =
        await _CriticalOwnership.call<bool>('updateTriggerIfOwner', {
      'eventId': request.eventId,
      'generation': request.generation,
      'expectedTrigger': request.triggerAt.millisecondsSinceEpoch,
      'nextTrigger': departAt.millisecondsSinceEpoch,
    });
    if (advanced != true) {
      return const CriticalPreflightOutcome.aborted('stale_trigger');
    }
    final next = request.rearmedAt(departAt);
    final rearmed = await _schedulePreflightAlarm(next);
    if (!rearmed) {
      // 재무장 거부: 연기 근거가 없으므로 즉시 울린다.
      return _ring(next, event, 'rearm_refused');
    }
    final watchdog = await _scheduleAudible(
      next,
      at: departAt.add(watchdogDelay),
      event: event,
    );
    if (!await _isGenerationCurrent(request.eventId, request.generation)) {
      await _cancelOwnedArtifacts(request.eventId, request.generation);
      return const CriticalPreflightOutcome.aborted('stale_generation');
    }
    if (!watchdog.isScheduled) {
      // 같은 ID의 기존 watchdog(옛 트리거+90초)이 그대로 남아 늦게 울린다.
      return const CriticalPreflightOutcome.watchdogKept(
        'watchdog_rearm_failed',
      );
    }
    DiagLogger.log(
      'CriticalPreflight',
      'postponed event=${request.eventId} newTrigger=${departAt.toIso8601String()} '
          'route=${estimate.source.name} margin=${margin.inMinutes}m',
    );
    return CriticalPreflightOutcome.rearmed(departAt);
  }

  Future<CriticalPreflightOutcome> _failSafeRing(
    CriticalPreflightRequest request,
    EventModel? event,
    String reason, {
    bool restoreOriginal = false,
  }) async {
    if (!await _isGenerationCurrent(request.eventId, request.generation)) {
      await _cancelOwnedArtifacts(request.eventId, request.generation);
      return const CriticalPreflightOutcome.aborted('stale_generation');
    }
    if (await _isOccurrenceAcknowledged(request)) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('critical_acknowledged');
    }
    final freshness = await _recheck(request, _budget.eventFetch);
    if (freshness == _Freshness.stale) {
      await _releaseGeneration(request);
      return const CriticalPreflightOutcome.aborted('event_changed');
    }
    if (restoreOriginal) {
      await _cancelPreflightAlarm(request.eventId, request.generation);
    }
    return _ring(request, event, reason,
        notifyAt: restoreOriginal ? request.originalTriggerAt : null);
  }

  Future<CriticalPreflightOutcome> _ring(
    CriticalPreflightRequest request,
    EventModel? event,
    String reason, {
    DateTime? notifyAt,
  }) async {
    final now = _currentTime;
    final at = notifyAt != null && notifyAt.isAfter(now)
        ? notifyAt
        : now.add(ringNowDelay);
    final result = await _scheduleAudible(request, at: at, event: event);
    if (!await _isGenerationCurrent(request.eventId, request.generation)) {
      await _cancelOwnedArtifacts(request.eventId, request.generation);
      return const CriticalPreflightOutcome.aborted('stale_generation');
    }
    DiagLogger.log(
      'CriticalPreflight',
      'ringNow event=${request.eventId} reason=$reason '
          'scheduled=${result.isScheduled}',
    );
    if (!result.isScheduled) {
      return CriticalPreflightOutcome.watchdogKept('ring_failed_$reason');
    }
    return at.isAfter(now.add(ringNowDelay))
        ? CriticalPreflightOutcome.rearmed(at, detail: reason)
        : CriticalPreflightOutcome.rangNow(reason);
  }

  // ---------------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------------

  bool _matchesOccurrence(EventModel event, CriticalPreflightRequest request) {
    final startAt = event.startAt;
    return startAt != null &&
        startAt.toUtc() == request.occurrenceStartAt.toUtc() &&
        event.isCritical &&
        event.useStrongAlarm &&
        event.locationLat != null &&
        event.locationLng != null;
  }

  Future<bool> _isOccurrenceAcknowledged(
    CriticalPreflightRequest request,
  ) async {
    await _reloadedPrefs();
    try {
      return await _acks.hasUnknownStartAcknowledgement(request.eventId) ||
          await _acks.isAcknowledged(
            request.eventId,
            request.occurrenceStartAt,
          );
    } catch (_) {
      return false;
    }
  }

  Future<_Fetch> _fetchEvent(
    CriticalPreflightRequest request,
    Duration timeout,
  ) async {
    if (timeout <= Duration.zero) {
      return const _Fetch.failed();
    }
    try {
      final event = await _events
          .fetchEvent(request.eventId, userId: request.userId)
          .timeout(timeout);
      return _Fetch(event);
    } catch (error) {
      debugPrint('Critical preflight event fetch failed: $error');
      return const _Fetch.failed();
    }
  }

  Future<_Freshness> _recheck(
    CriticalPreflightRequest request,
    Duration timeout, {
    EventModel? routeEvent,
  }) async {
    if (!await _isGenerationCurrent(request.eventId, request.generation)) {
      return _Freshness.stale;
    }
    if (await _isOccurrenceAcknowledged(request)) {
      return _Freshness.stale;
    }
    final fetched = await _fetchEvent(request, timeout);
    if (fetched.failed) {
      return _Freshness.unknown;
    }
    final event = fetched.event;
    if (event == null || !_matchesOccurrence(event, request)) {
      return _Freshness.stale;
    }
    if (routeEvent != null &&
        (event.locationLat != routeEvent.locationLat ||
            event.locationLng != routeEvent.locationLng)) {
      return _Freshness.unknown;
    }
    return await _isGenerationCurrent(request.eventId, request.generation)
        ? _Freshness.current
        : _Freshness.stale;
  }

  /// 신선한 현재 위치만. 주입 provider가 없으면 [AppPermissionService.
  /// getFreshCurrentLocation]만 쓴다(이 getter가 권한을 프롬프트 없이 확인하고
  /// 요청 시각/출처를 검증한다). lastKnown/캐시 폴백은 절대 쓰지 않는다.
  Future<GeoPoint?> _resolveFreshOrigin(Duration timeout) async {
    if (timeout <= Duration.zero) {
      return null;
    }
    final provider = _freshLocationProvider;
    try {
      if (provider != null) {
        return await provider().then<GeoPoint?>((value) => value).timeout(
              timeout,
              onTimeout: () => null,
            );
      }
      if (!_isAndroid) {
        return null;
      }
      return await _permissions
          .getFreshCurrentLocation(requireBackgroundPermission: true)
          .then<GeoPoint?>((value) => value)
          .timeout(timeout, onTimeout: () => null);
    } catch (error) {
      debugPrint('Critical preflight fresh location failed: $error');
      return null;
    }
  }

  Future<UserSettingsModel?> _loadSettings(
    String userId,
    Duration timeout,
  ) async {
    if (timeout <= Duration.zero) {
      return null;
    }
    try {
      return await _settings
          .fetchSettings(userId)
          .then<UserSettingsModel?>((value) => value)
          .timeout(timeout, onTimeout: () => null);
    } catch (error) {
      debugPrint('Critical preflight settings unavailable: $error');
      return null;
    }
  }

  bool _matchesProvider(TravelTimeBufferSource source, String provider) =>
      switch (provider) {
        'tmap' => source == TravelTimeBufferSource.tmap,
        'google' => source == TravelTimeBufferSource.googleMaps,
        _ => source == TravelTimeBufferSource.naverMap,
      };

  bool _isRoutedSource(TravelTimeBufferSource source) {
    switch (source) {
      case TravelTimeBufferSource.tmap:
      case TravelTimeBufferSource.naverMap:
      case TravelTimeBufferSource.googleMaps:
        return true;
      case TravelTimeBufferSource.coordinates:
      case TravelTimeBufferSource.locationText:
      case TravelTimeBufferSource.defaultFallback:
        return false;
    }
  }

  MapTravelMode _travelModeFromSettings(String? travelMode) {
    return travelMode == 'transit' ? MapTravelMode.transit : MapTravelMode.car;
  }

  /// 저장된 출발 여유. UI 값(10/20/30)과 명시 저장된 0(여유 없음)을 존중하고,
  /// 그 외는 DepartureAlarmService와 같은 기본값(20분)으로 돌아간다.
  int _safetyMarginMinutes(int value) {
    if (value == 0 || value == 10 || value == 20 || value == 30) {
      return value;
    }
    return defaultSafetyMarginMin;
  }

  Future<NotificationScheduleResult> _scheduleAudible(
    CriticalPreflightRequest request, {
    required DateTime at,
    EventModel? event,
  }) async {
    final freshTitle = event?.title.trim();
    try {
      if (!await _isGenerationCurrent(request.eventId, request.generation) ||
          await _isOccurrenceAcknowledged(request)) {
        await _releaseGeneration(request);
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.error,
          notifyAt: at,
        );
      }
      final result = await _notifications.scheduleCriticalAlarmWithResult(
        id: _notifications.notificationIdFor(
          audibleKeyFor(request.eventId, request.generation),
        ),
        title: freshTitle == null || freshTitle.isEmpty
            ? request.title
            : freshTitle,
        notifyAt: at,
        body: request.body ?? defaultBody,
        payload: request.payload ?? 'event:${request.eventId}',
        useStrongAlarm: request.useStrongAlarm,
      );
      if (!await _isGenerationCurrent(request.eventId, request.generation) ||
          await _isOccurrenceAcknowledged(request)) {
        await _releaseGeneration(request);
        return NotificationScheduleResult(
          status: NotificationScheduleStatus.error,
          notifyAt: at,
        );
      }
      return result;
    } catch (error) {
      debugPrint('Critical preflight audible schedule failed: $error');
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: at,
      );
    }
  }

  Future<bool> _schedulePreflightAlarm(CriticalPreflightRequest request) async {
    if (!request.triggerAt.isAfter(_currentTime)) {
      return false;
    }
    final injected = _preflightScheduler;
    try {
      if (injected != null) {
        return await injected(request);
      }
      if (!_isAndroid) {
        return false;
      }
      if (!await AlarmService.ensureInitialized()) {
        return false;
      }
      return await AndroidAlarmManager.oneShotAt(
        request.triggerAt,
        preflightAlarmIdFor(request.eventId, request.generation),
        criticalAlarmPreflightCallback,
        exact: true,
        allowWhileIdle: true,
        wakeup: true,
        rescheduleOnReboot: true,
        params: request.toParams(),
      );
    } catch (error) {
      debugPrint('Critical preflight scheduling failed: $error');
      return false;
    }
  }

  Future<void> _cancelPreflightAlarm(String eventId, String generation) async {
    final alarmId = preflightAlarmIdFor(eventId, generation);
    final injected = _preflightCanceller;
    try {
      if (injected != null) {
        await injected(alarmId);
        return;
      }
      if (!_isAndroid) {
        return;
      }
      if (!await AlarmService.ensureInitialized()) {
        return;
      }
      await AndroidAlarmManager.cancel(alarmId);
    } catch (error) {
      debugPrint('Critical preflight cancel failed: $error');
    }
  }

  /// [generation] 소유 산출물만 취소한다(다른 generation은 건드리지 않음).
  static Map<String, dynamic>? _protectedPrevious(Map<String, dynamic> owner) {
    final metadata = jsonDecode(owner['metadataJson'] as String? ?? '{}');
    if (metadata is Map &&
        metadata['mode'] == 'restoring' &&
        metadata['protectedPreviousOwner'] is Map) {
      return Map<String, dynamic>.from(
          metadata['protectedPreviousOwner'] as Map);
    }
    return null;
  }

  Future<void> _cancelSnapshotArtifacts(
      String eventId, Map<String, dynamic> owner) async {
    await _cancelOwnedArtifacts(eventId, owner['generation'] as String,
        force: true);
    final previous = _protectedPrevious(owner);
    if (previous != null) {
      await _cancelOwnedArtifacts(eventId, previous['generation'] as String,
          force: true);
    }
  }

  Future<void> _cancelOwnedArtifacts(String eventId, String generation,
      {bool force = false}) async {
    if (!force) {
      final owner = await _CriticalOwnership.read(eventId);
      // Never retire artifacts that still belong to the live owner, or to a
      // protected predecessor while replacement delivery remains unconfirmed.
      if (owner != null &&
          (owner['generation'] == generation ||
              _protectedPrevious(owner)?['generation'] == generation)) {
        return;
      }
    }
    await _cancelPreflightAlarm(eventId, generation);
    await _safeCancel(
        _notifications.notificationIdFor(audibleKeyFor(eventId, generation)));
  }

  Future<void> _releaseGeneration(CriticalPreflightRequest request) async {
    final snapshot = await _CriticalOwnership.read(request.eventId);
    if (await _CriticalOwnership.release(request)) {
      if (snapshot != null &&
          snapshot['generation'] == request.generation &&
          snapshot['triggerAt'] == request.triggerAt.millisecondsSinceEpoch) {
        await _cancelSnapshotArtifacts(request.eventId, snapshot);
      } else {
        await _cancelOwnedArtifacts(request.eventId, request.generation,
            force: true);
      }
      return;
    }
    await _cancelOwnedArtifacts(request.eventId, request.generation);
  }

  Future<void> _safeCancel(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (error) {
      debugPrint('Critical preflight notification cancel failed: $error');
    }
  }

  String _newGeneration() {
    final random = math.Random();
    final suffix = List<int>.generate(8, (_) => random.nextInt(16)).map((v) {
      return v.toRadixString(16);
    }).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  Future<bool> _persistGeneration(CriticalPreflightRequest request) async {
    try {
      final previous = await _CriticalOwnership.call<Map>(
          'updateOwner', _CriticalOwnership.state(request));
      if (previous != null) {
        await _cancelSnapshotArtifacts(
            request.eventId, Map<String, dynamic>.from(previous));
      }
      return true;
    } catch (error) {
      debugPrint('Critical preflight ownership persist failed: $error');
      return false;
    }
  }

  Future<bool> _isGenerationCurrent(String eventId, String generation) async =>
      (await _CriticalOwnership.read(eventId))?['generation'] == generation;

  /// DepartureAlarmService의 `_stableAlarmId`와 동일 알고리즘(FNV-1a).
  static int stableAlarmIdFor(String id) {
    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  static Future<String?> loadLastRunSummary() async {
    final preferences = await _reloadedPrefs();
    return preferences?.getString(lastRunKey);
  }
}

enum _Freshness { current, stale, unknown }

class _Fetch {
  const _Fetch(this.event) : failed = false;
  const _Fetch.failed()
      : event = null,
        failed = true;

  final EventModel? event;
  final bool failed;
}

class CriticalPreflightOutcome {
  const CriticalPreflightOutcome._({
    required this.kind,
    this.detail,
    this.rearmedAt,
  });

  const CriticalPreflightOutcome.rangNow(String detail)
      : this._(kind: CriticalPreflightOutcomeKind.rangNow, detail: detail);

  const CriticalPreflightOutcome.rearmed(DateTime at, {String? detail})
      : this._(
          kind: CriticalPreflightOutcomeKind.rearmed,
          rearmedAt: at,
          detail: detail,
        );

  const CriticalPreflightOutcome.aborted(String detail)
      : this._(kind: CriticalPreflightOutcomeKind.aborted, detail: detail);

  const CriticalPreflightOutcome.watchdogKept(String detail)
      : this._(
          kind: CriticalPreflightOutcomeKind.watchdogKept,
          detail: detail,
        );

  final CriticalPreflightOutcomeKind kind;
  final String? detail;
  final DateTime? rearmedAt;

  @override
  String toString() => switch (kind) {
        CriticalPreflightOutcomeKind.rangNow => 'RING reason=$detail',
        CriticalPreflightOutcomeKind.rearmed =>
          'REARM at=${rearmedAt?.toIso8601String()} ${detail ?? ''}'.trim(),
        CriticalPreflightOutcomeKind.watchdogKept =>
          'WATCHDOG_KEPT reason=$detail',
        CriticalPreflightOutcomeKind.aborted => 'ABORT reason=$detail',
      };
}

enum CriticalPreflightOutcomeKind { rangNow, rearmed, aborted, watchdogKept }

/// android_alarm_manager_plus 콜백(최상위 함수).
@pragma('vm:entry-point')
Future<void> criticalAlarmPreflightCallback(
  int id,
  Map<String, dynamic> params,
) async {
  final request = CriticalPreflightRequest.fromParams(params);
  if (request == null) {
    // 필수 정보가 없으면 판단 불가: watchdog이 그대로 남아 늦게 울린다.
    debugPrint('Critical alarm preflight: invalid params');
    return;
  }
  const budget = CriticalPreflightBudget();
  var outcome = const CriticalPreflightOutcome.aborted('callback_error');
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      try {
        await Supabase.initialize(
          url: AppEnv.supabaseUrl,
          anonKey: AppEnv.supabaseAnonKey,
          authOptions: buildPlanFlowAuthOptions(
            supabaseUrl: AppEnv.supabaseUrl,
            detectSessionInUri: false,
            autoRefreshToken: false,
            isolateMode: true,
          ),
        ).timeout(budget.supabaseInit);
        AppEnv.markSupabaseInitialized();
      } catch (error) {
        // 초기화 실패 → runCriticalPreflight가 supabase_unavailable로 즉시 울림.
        debugPrint('Critical alarm preflight supabase init failed: $error');
      }
    }
    outcome = await const CriticalAlarmPreflightService(budget: budget)
        .runCriticalPreflight(request);
  } catch (error, stackTrace) {
    debugPrint('Critical alarm preflight failed: $error');
    debugPrintStack(stackTrace: stackTrace, maxFrames: 8);
  }
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      CriticalAlarmPreflightService.lastRunKey,
      '${DateTime.now().toIso8601String()} | event=${request.eventId} | '
      '$outcome',
    );
  } catch (_) {}
}
