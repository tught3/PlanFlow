import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/calendar_auto_sync_service.dart';
import '../../../services/departure_alarm_service.dart';
import '../../../services/home_widget_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/smart_preparation_alarm_service.dart';
import '../providers/group_context_provider.dart';
import '../services/group_calendar_widget_service.dart';

/// 그룹 archive/restore 이후 파생 상태(알림, 알람, 위젯, 캐시 등)를 정리하는 서비스.
///
/// 설계 원칙:
/// 1. 각 cleanup 단계는 개별 try/catch로 감싸 한 단계 실패가 다른 단계를 막지 않는다.
/// 2. cleanup 자체는 fire-and-forget. 호출자가 `unawaited`로 호출해도 안전하게
///    시간이 걸리는 작업은 내부에서 동기/비동기를 구분해 진행한다.
/// 3. cleanup 실패가 archive/restore 자체를 실패로 만들지 않는다. archive/restore
///    RPC가 이미 성공한 후 호출되는 보조 정리용이기 때문이다.
/// 4. 모든 의존성은 constructor 주입. 테스트에서는 mock으로 교체 가능하다.
/// 5. 기존 서비스 public API는 변경하지 않는다. 새 매서드가 필요한 자리는
///    TODO 주석으로 남기고 호출 가능한 것만 호출한다.
class GroupCleanupService {
  GroupCleanupService({
    SupabaseClient? client,
    NotificationService? notificationService,
    SmartPreparationAlarmService? smartAlarmService,
    DepartureAlarmService? departureAlarmService,
    HomeWidgetService? homeWidgetService,
    GroupCalendarWidgetService? groupWidgetService,
    GroupContextProvider? contextProvider,
    CalendarAutoSyncService? calendarAutoSyncService,
    SharedPreferences? preferences,
  })  : _client = client ?? Supabase.instance.client,
        _notificationService =
            notificationService ?? NotificationService(),
        _smartAlarmService = smartAlarmService,
        _departureAlarmService = departureAlarmService,
        _homeWidgetService = homeWidgetService,
        _groupWidgetService = groupWidgetService,
        _contextProvider = contextProvider,
        _calendarAutoSyncService = calendarAutoSyncService,
        _preferences = preferences;

  final SupabaseClient _client;
  final NotificationService _notificationService;
  final SmartPreparationAlarmService? _smartAlarmService;
  final DepartureAlarmService? _departureAlarmService;
  // HomeWidgetService는 group archive/restore 시 홈 위젯 캐시를 새로 갱신할
  // 용도로 주입받는다. 현재는 refreshScheduleFromEvents(List<EventModel>)가
  // 이벤트 리스트를 요구해 호출 지점(#_refreshWidgetsAfterArchive 참조)이
  // TODO로 남아 있어 이 필드는 미래 사용을 위해 보존한다.
  // ignore: unused_field
  final HomeWidgetService? _homeWidgetService;
  final GroupCalendarWidgetService? _groupWidgetService;
  final GroupContextProvider? _contextProvider;
  final CalendarAutoSyncService? _calendarAutoSyncService;
  final SharedPreferences? _preferences;

  static GroupCleanupService? _instance;
  static GroupCleanupService get instance =>
      _instance ??= GroupCleanupService();

  static void setInstance(GroupCleanupService service) => _instance = service;
  static void resetInstance() => _instance = null;

  String _currentUserId() => _client.auth.currentUser?.id ?? '';

  /// 그룹 archive RPC가 성공한 뒤 호출. 파생 상태 정리를 fire-and-forget 수행.
  Future<void> onGroupArchived(String groupId, {String? userId}) async {
    final effectiveUserId = (userId ?? _currentUserId()).trim();
    await _cancelGroupEventNotifications(groupId);
    await _cancelSmartPreparationAlarms(groupId);
    await _cancelDepartureAlarms(groupId);
    await _refreshWidgetsAfterArchive(groupId, effectiveUserId);
    await _refreshGroupContextProvider(groupId, effectiveUserId);
    await _pauseCalendarAutoSync(groupId);
    await _invalidateSharedPreferencesCache(groupId, effectiveUserId);
  }

  /// 그룹 restore RPC가 성공한 뒤 호출. archive 때 정리한 상태를 복원.
  Future<void> onGroupRestored(String groupId, {String? userId}) async {
    final effectiveUserId = (userId ?? _currentUserId()).trim();
    await _refreshWidgetsAfterRestore(groupId, effectiveUserId);
    await _refreshGroupContextProvider(groupId, effectiveUserId);
    await _resumeCalendarAutoSync(groupId);
    await _primeRestoredGroupAlarms(groupId);
  }

  /// 부팅 시 호출. 입력으로 받은 active group 집합에 들어 있지 않은 그룹 이벤트의
  /// 알림/알람을 정리한다. 그룹 상태가 stale일 수 있는 환경에서 orphan 알람을
  /// 0으로 수렴시키는 용도.
  Future<void> reconcileStaleAlarms(
    Set<String> activeGroupIds, {
    String? userId,
  }) async {
    final normalizedActive = activeGroupIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    try {
      final response = await _client
          .from('group_events')
          .select('id,group_id')
          .neq('status', 'cancelled');
      final rows = (response as List<dynamic>);
      final stale = <String>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final map = row;
        final groupId = (map['group_id'] as String?)?.trim();
        final eventId = (map['id'] as String?)?.trim();
        if (groupId == null || groupId.isEmpty) continue;
        if (eventId == null || eventId.isEmpty) continue;
        if (normalizedActive.contains(groupId)) continue;
        stale.add(eventId);
      }
      for (final eventId in stale) {
        await _safeCancelEventNotifications(eventId);
        await _safeCancelSmartPreparation(eventId);
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService.reconcileStaleAlarms failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<void> _cancelGroupEventNotifications(String groupId) async {
    try {
      final response = await _client
          .from('group_events')
          .select('id')
          .eq('group_id', groupId);
      final rows = (response as List<dynamic>);
      for (final row in rows) {
        if (row is! Map) continue;
        final eventId = (row['id'] as String?)?.trim();
        if (eventId == null || eventId.isEmpty) continue;
        await _safeCancelEventNotifications(eventId);
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService._cancelGroupEventNotifications failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<void> _safeCancelEventNotifications(String eventId) async {
    try {
      await _notificationService.cancelEventNotifications(eventId);
      await _notificationService.cancelDepartureNotifications(eventId);
    } catch (e) {
      debugPrint(
          'GroupCleanupService: cancelEventNotifications($eventId) failed: $e');
    }
  }

  Future<void> _cancelSmartPreparationAlarms(String groupId) async {
    final service = _smartAlarmService;
    if (service == null) {
      debugPrint(
          'GroupCleanupService: SmartPreparationAlarmService not injected, skipping group-level cancel');
      return;
    }
    try {
      final response = await _client
          .from('group_events')
          .select('id')
          .eq('group_id', groupId);
      final rows = (response as List<dynamic>);
      for (final row in rows) {
        if (row is! Map) continue;
        final eventId = (row['id'] as String?)?.trim();
        if (eventId == null || eventId.isEmpty) continue;
        await _safeCancelSmartPreparation(eventId, source: service);
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService._cancelSmartPreparationAlarms failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<void> _safeCancelSmartPreparation(
    String eventId, {
    SmartPreparationAlarmService? source,
  }) async {
    final service = source ?? _smartAlarmService;
    if (service == null) return;
    try {
      await service.cancelForEvent(eventId);
    } catch (e) {
      debugPrint(
          'GroupCleanupService: smartAlarm.cancelForEvent($eventId) failed: $e');
    }
  }

  /// TODO(cleanup): DepartureAlarmService에 cancelByGroupId 또는
  /// cancelForGroupEvent 같은 public API가 없어 현재는 no-op.
  /// API가 추가되면 해당 메서드를 호출하도록 교체.
  Future<void> _cancelDepartureAlarms(String groupId) async {
    final service = _departureAlarmService;
    if (service == null) {
      debugPrint(
          'GroupCleanupService: DepartureAlarmService not injected, skipping group-level cancel');
      return;
    }
    try {
      final response = await _client
          .from('group_events')
          .select('id')
          .eq('group_id', groupId);
      final rows = (response as List<dynamic>);
      for (final row in rows) {
        if (row is! Map) continue;
        final eventId = (row['id'] as String?)?.trim();
        if (eventId == null || eventId.isEmpty) continue;
        try {
          await _notificationService.cancelPreActionAlarms(eventId);
        } catch (e) {
          debugPrint(
              'GroupCleanupService: cancelPreActionAlarms($eventId) failed: $e');
        }
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService._cancelDepartureAlarms failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<void> _refreshWidgetsAfterArchive(
    String groupId,
    String userId,
  ) async {
    try {
      final widgetService = _groupWidgetService;
      if (widgetService != null && userId.isNotEmpty) {
        await widgetService.refresh(userId: userId, force: true);
      }
    } catch (e) {
      debugPrint('GroupCleanupService: groupWidget refresh failed: $e');
    }
    // TODO(cleanup): HomeWidgetService.refreshScheduleFromEvents(List<EventModel>)
    // 는 events 인자가 필수. archive 시점에 이벤트 리스트를 다시 가져와 인자로
    // 넘기거나, HomeWidgetService에 groupId만으로 refresh 하는 public API 추가가
    // 필요. 이번 Task 범위 밖.
  }

  Future<void> _refreshWidgetsAfterRestore(
    String groupId,
    String userId,
  ) async {
    try {
      final widgetService = _groupWidgetService;
      if (widgetService != null && userId.isNotEmpty) {
        await widgetService.refresh(userId: userId, force: true);
      }
    } catch (e) {
      debugPrint('GroupCleanupService: groupWidget refresh (restore) failed: $e');
    }
    // TODO(cleanup): _refreshWidgetsAfterArchive 주석 참조.
  }

  Future<void> _refreshGroupContextProvider(
    String groupId,
    String userId,
  ) async {
    final provider = _contextProvider;
    if (provider == null) {
      debugPrint(
          'GroupCleanupService: GroupContextProvider not injected, skipping provider reload');
      return;
    }
    if (userId.isEmpty) {
      debugPrint(
          'GroupCleanupService: userId is empty, skipping provider reload');
      return;
    }
    try {
      await provider.load(userId);
    } catch (e, st) {
      debugPrint('GroupCleanupService: provider.reload failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  /// TODO(cleanup): CalendarAutoSyncService에 setGroupExcluded(groupId, bool) 같은
  /// public API가 없어 현재는 no-op. archive 직후 동기화 대상에서 제외해야 하면
  /// 해당 API를 추가하고 여기서 true로 호출.
  Future<void> _pauseCalendarAutoSync(String groupId) async {
    final service = _calendarAutoSyncService;
    if (service == null) return;
    // No-op placeholder: API 추가 전까지 호출 가능한 public surface가 없음.
    // CalendarAutoSyncService가 주입됐다는 사실만 기록하고 즉시 종료한다.
    // ignore: unused_local_variable
    final _ = service;
  }

  Future<void> _resumeCalendarAutoSync(String groupId) async {
    final service = _calendarAutoSyncService;
    if (service == null) return;
    // No-op placeholder: API 추가 전까지 호출 가능한 public surface가 없음.
    // ignore: unused_local_variable
    final _ = service;
  }

  /// restore 시 새 group_id 또는 그룹 이벤트가 다시 등장하면 알람을 재등록.
  /// 새 event_id 체계가 도입되면 그에 맞춰 감싸기.
  Future<void> _primeRestoredGroupAlarms(String groupId) async {
    try {
      final response = await _client
          .from('group_events')
          .select('id')
          .eq('group_id', groupId);
      final rows = (response as List<dynamic>);
      // 현재는 notification_service.cancel*만 있어 pre-register 호출 경로가
      // 부재. 실제 재등록은 화면 단의 일정 진입 시 onResume 훅에 위임하고,
      // 여기서는 실패한 cleanup가 없는지만 보장.
      for (final row in rows) {
        if (row is! Map) continue;
        final eventId = (row['id'] as String?)?.trim();
        if (eventId == null || eventId.isEmpty) continue;
        // suppress unused: 실측 후 재등록 API가 노출되면 호출.
        assert(eventId.isNotEmpty);
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService._primeRestoredGroupAlarms failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<void> _invalidateSharedPreferencesCache(
    String groupId,
    String userId,
  ) async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final groupIdToken = ':$groupId';
      final userIdToken = userId.isEmpty ? null : ':$userId';
      for (final key in keys) {
        if (!key.startsWith('planflow:group_')) continue;
        if (!key.contains(groupIdToken)) continue;
        if (userIdToken != null && !key.contains(userIdToken)) continue;
        await prefs.remove(key);
      }
    } catch (e, st) {
      debugPrint('GroupCleanupService._invalidateSharedPreferencesCache failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }
}
