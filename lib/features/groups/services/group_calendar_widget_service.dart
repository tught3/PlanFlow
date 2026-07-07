import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import '../models/group_event_recurrence.dart';
import '../repositories/group_event_repository.dart';
import '../repositories/group_repository.dart';
import '../../../services/home_widget_platform.dart';

/// 홈 위젯 'PlanFlowGroupCalendarWidgetProvider'에 그룹 월간 캘린더 데이터를
/// 기록하고 위젯을 갱신하는 서비스.
///
/// 데이터 계약 (home_widget SharedPreferences 키):
///   `gw_groups_json`          : JSON string `[{"id","name"}]` — 마지막 선택 그룹 먼저
///   `gw_<gid>_name`           : 그룹 이름
///   `gw_<gid>_title`          : "\<year\>년 \<month\>월"
///   `gw_<gid>_c<i>_d`         : 날짜 번호 (0‥41)
///   `gw_<gid>_c<i>_m`         : "1" = 이번 달, "0" = 인접 달
///   `gw_<gid>_c<i>_t`         : "1" = 오늘, "0" = 오늘 아님
///   `gw_<gid>_c<i>_n`         : 해당 날 이벤트 발생 횟수 (string)
class GroupCalendarWidgetService {
  GroupCalendarWidgetService({
    GroupRepository? groupRepository,
    GroupEventRepository? eventRepository,
    HomeWidgetPlatform? platform,
  })  : _groupRepositoryOverride = groupRepository,
        _eventRepositoryOverride = eventRepository,
        _platformOverride = platform;

  static const String _widgetName = 'PlanFlowGroupCalendarWidgetProvider';
  static const String _selectedGroupKeyPrefix =
      'planflow:group_context:selected_group_id:v1:';

  // Supabase/플랫폼 의존성은 실제 refresh가 진행될 때(=Android)만 생성한다.
  // 생성자에서 즉시 만들면 테스트 등 Supabase 미초기화 환경에서 assert가 난다.
  final GroupRepository? _groupRepositoryOverride;
  final GroupEventRepository? _eventRepositoryOverride;
  final HomeWidgetPlatform? _platformOverride;
  GroupRepository? _groupRepositoryCache;
  GroupEventRepository? _eventRepositoryCache;
  HomeWidgetPlatform? _platformCache;

  GroupRepository get _groupRepository => _groupRepositoryCache ??=
      _groupRepositoryOverride ?? GroupRepository.supabase();
  GroupEventRepository get _eventRepository => _eventRepositoryCache ??=
      _eventRepositoryOverride ?? GroupEventRepository.supabase();
  HomeWidgetPlatform get _platform =>
      _platformCache ??= _platformOverride ?? createHomeWidgetPlatform();

  // 디바운스: 최근 refresh 완료 시각 추적
  DateTime? _lastRefresh;
  static const Duration _debounce = Duration(seconds: 10);

  /// [userId]에 맞는 그룹 월간 달력 데이터를 위젯에 기록하고 갱신한다.
  ///
  /// - web / non-Android(iOS 제외 – 현재 Android-only)에서는 no-op.
  /// - 내부 오류는 모두 catch 해 호출자에게 예외를 던지지 않는다.
  /// - [force] = true 이면 디바운스를 무시한다.
  Future<void> refresh({
    required String userId,
    bool force = false,
  }) async {
    // web 또는 플랫폼 미지원 시 no-op
    if (kIsWeb) {
      return;
    }
    if (!Platform.isAndroid) {
      return;
    }
    if (!_platform.isSupported) {
      return;
    }
    if (userId.isEmpty) {
      return;
    }

    // 디바운스: 짧은 시간 내 중복 호출 방지
    if (!force) {
      final last = _lastRefresh;
      if (last != null && DateTime.now().difference(last) < _debounce) {
        return;
      }
    }

    try {
      await _doRefresh(userId);
      _lastRefresh = DateTime.now();
    } catch (error, stackTrace) {
      debugPrint('GroupCalendarWidgetService.refresh 오류: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// 테스트 전용: [refresh]의 `Platform.isAndroid` 하드 게이트를 우회해
  /// 핵심 데이터 기록 로직만 직접 실행한다. 프로덕션 경로는 [refresh]를 쓴다.
  @visibleForTesting
  Future<void> doRefreshForTesting(String userId) => _doRefresh(userId);

  Future<void> _doRefresh(String userId) async {
    // 1) 사용자의 그룹 목록 로드
    final groups = await _groupRepository.listGroups();
    if (groups.isEmpty) {
      // 그룹이 없어도 gw_groups_json을 "[]"로 명시 저장해 위젯 상태를
      // 결정적으로 만든다(전이적 빈 응답으로 잔상/미정의 상태 방지).
      await _platform.saveWidgetData('gw_groups_json', '[]');
      await _platform.updateWidget(androidName: _widgetName);
      return;
    }

    // 2) 마지막 선택 그룹 ID 읽기 (SharedPreferences)
    final selectedGroupId = await _readSelectedGroupId(userId);

    // 3) 그룹 목록 정렬: 마지막 선택 그룹이 첫 번째
    final orderedGroups = [
      ...groups.where((g) => g.id == selectedGroupId),
      ...groups.where((g) => g.id != selectedGroupId),
    ];

    // 4) gw_groups_json 저장
    final groupsJson = jsonEncode(
      orderedGroups
          .map((g) => <String, String>{'id': g.id, 'name': g.name})
          .toList(growable: false),
    );
    await _platform.saveWidgetData('gw_groups_json', groupsJson);

    // 5) 현재 달 계산
    final now = planflowNow();
    final currentMonth = DateTime(now.year, now.month);
    final today = DateTime(now.year, now.month, now.day);

    // 6) 그룹별 달력 데이터 저장 (병렬)
    await Future.wait(
      orderedGroups.map(
        (group) => _writeGroupMonthData(
          group.id,
          group.name,
          currentMonth,
          today,
        ),
      ),
    );

    // 7) 위젯 갱신
    await _platform.updateWidget(androidName: _widgetName);
  }

  Future<void> _writeGroupMonthData(
    String groupId,
    String groupName,
    DateTime currentMonth,
    DateTime today,
  ) async {
    // 이벤트 로드 범위: monthStart-7d ~ monthEnd+7d (recurrence 포함)
    final monthStart = DateTime(currentMonth.year, currentMonth.month, 1);
    final monthEnd = DateTime(currentMonth.year, currentMonth.month + 1, 1);
    final from = monthStart.subtract(const Duration(days: 7));
    final to = monthEnd.add(const Duration(days: 7));

    final events = await _eventRepository.getEventsForGroup(groupId, from, to);

    // 그리드 시작일 계산 (group_month_calendar.dart _gridFirstDay 와 동일 로직)
    final gridFirstDay = _gridFirstDay(currentMonth);
    final gridEndUtc = gridFirstDay.toUtc().add(const Duration(days: 43));

    // 반복 일정 전개 (expandGroupEventOccurrences 재사용)
    final occurrences = <GroupEventModel>[];
    for (final event in events) {
      occurrences.addAll(
        expandGroupEventOccurrences(
          event,
          gridFirstDay.toUtc(),
          gridEndUtc,
        ),
      );
    }

    // 날짜별 발생 횟수 인덱스
    final countByDay = <DateTime, int>{};
    for (final occ in occurrences) {
      final localStart = planflowLocal(occ.startAt);
      final localEnd = planflowLocal(occ.endAt);
      final startDay = DateTime(localStart.year, localStart.month, localStart.day);
      final endDay = DateTime(localEnd.year, localEnd.month, localEnd.day);
      for (var d = startDay;
          !d.isAfter(endDay);
          d = d.add(const Duration(days: 1))) {
        countByDay[d] = (countByDay[d] ?? 0) + 1;
      }
    }

    // gw_<gid>_name, gw_<gid>_title
    final gid = groupId;
    await _platform.saveWidgetData('gw_${gid}_name', groupName);
    await _platform.saveWidgetData(
      'gw_${gid}_title',
      '${currentMonth.year}년 ${currentMonth.month}월',
    );

    // gw_<gid>_c<i>_* (i = 0..41)
    for (var i = 0; i < 42; i++) {
      final cellDay = gridFirstDay.add(Duration(days: i));
      final inMonth = cellDay.year == currentMonth.year &&
          cellDay.month == currentMonth.month;
      final isToday = cellDay == today;
      final count = countByDay[cellDay] ?? 0;

      await _platform.saveWidgetData('gw_${gid}_c${i}_d', '${cellDay.day}');
      await _platform.saveWidgetData('gw_${gid}_c${i}_m', inMonth ? '1' : '0');
      await _platform.saveWidgetData('gw_${gid}_c${i}_t', isToday ? '1' : '0');
      await _platform.saveWidgetData('gw_${gid}_c${i}_n', '$count');
    }
  }

  /// group_month_calendar.dart _gridFirstDay 와 동일:
  /// 해당 달 1일이 포함된 주의 일요일을 반환한다.
  static DateTime _gridFirstDay(DateTime month) {
    final firstOfMonth = DateTime(month.year, month.month, 1);
    final weekday = firstOfMonth.weekday; // 1=월 … 7=일
    final offsetToSunday = weekday % 7; // 일=0, 월=1 … 토=6
    return firstOfMonth.subtract(Duration(days: offsetToSunday));
  }

  Future<String?> _readSelectedGroupId(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_selectedGroupKeyPrefix$userId');
    } catch (_) {
      return null;
    }
  }
}
