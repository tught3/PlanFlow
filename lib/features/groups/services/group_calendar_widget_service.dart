import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import '../models/group_event_recurrence.dart';
import '../models/group_member_model.dart';
import '../repositories/group_event_repository.dart';
import '../repositories/group_repository.dart';
import '../../../services/home_widget_platform.dart';

/// 홈 위젯 'PlanFlowGroupCalendarWidgetProvider'에 그룹 월간 캘린더 데이터를
/// 기록하고 위젯을 갱신하는 서비스.
///
/// 데이터 계약 (home_widget SharedPreferences 키):
///   `gw_groups_json`          : JSON string `[{"id","name"}]` — 마지막 선택 그룹 먼저
///   `gw_<gid>_name`           : 그룹 이름
///   `gw_<gid>_title`          : "\<year\>년 \<month\>월" (현재 달 기준, 네이티브가
///                               "오늘 달로 복귀"할 때의 초기값 폴백으로만 사용)
///   `gw_<gid>_occurrences_json` : JSON 배열 `[{"d":"yyyy-MM-dd","n":"표시이름"}, ...]`
///                               현재 달 기준 -12개월 ~ +12개월(약 25개월 창) 안의
///                               모든 이벤트 발생(반복 전개 포함)을, 그 발생이 걸치는
///                               모든 날짜 × 작성자(createdBy)의 표시이름으로 펼친 목록.
///                               `d`는 KST 로컬 날짜(yyyy-MM-dd), `n`은
///                               [buildDisambiguatedDisplayNames]로 계산된 표시 이름
///                               (예: "김A"). 네이티브가 이 배열을 받아 원하는 달로
///                               날짜별 재집계한다. 정렬 순서는 보장하지 않는다.
///                               그룹 이벤트에는 "중요(critical)" 개념이 없으므로 이
///                               JSON에 critical 필드를 넣지 않는다.
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

    // 6) 그룹별 달력 데이터 저장 (병렬)
    await Future.wait(
      orderedGroups.map(
        (group) => _writeGroupOccurrencesData(
          group.id,
          group.name,
          currentMonth,
        ),
      ),
    );

    // 7) 위젯 갱신
    await _platform.updateWidget(androidName: _widgetName);
  }

  Future<void> _writeGroupOccurrencesData(
    String groupId,
    String groupName,
    DateTime currentMonth,
  ) async {
    // 이벤트 로드 범위: 현재 달 기준 -12개월 ~ +12개월 (약 25개월 창).
    // Supabase 쿼리는 그룹당 1회만 나간다.
    final rangeStart = DateTime(currentMonth.year, currentMonth.month - 12, 1);
    final rangeEndExclusive =
        DateTime(currentMonth.year, currentMonth.month + 13, 1);

    final events = await _eventRepository.getEventsForGroup(
      groupId,
      rangeStart,
      rangeEndExclusive,
    );
    final members = await _groupRepository.listMembers(groupId);
    final displayNames = buildDisambiguatedDisplayNames(members);

    final rangeStartUtc = planflowLocalDateTimeToUtc(rangeStart);
    final rangeEndUtc = planflowLocalDateTimeToUtc(rangeEndExclusive);

    // 반복 일정 전개 (expandGroupEventOccurrences 재사용)
    final occurrences = <GroupEventModel>[];
    for (final event in events) {
      occurrences.addAll(
        expandGroupEventOccurrences(
          event,
          rangeStartUtc,
          rangeEndUtc,
        ),
      );
    }

    // 발생을 "날짜 × 작성자 표시이름" 항목으로 펼친다 (다일 일정은 날짜마다 1건).
    final items = <Map<String, String>>[];
    for (final occ in occurrences) {
      final localStart = planflowLocal(occ.startAt);
      final localEnd = planflowLocal(occ.endAt);
      final startDay = DateTime(localStart.year, localStart.month, localStart.day);
      final endDay = DateTime(localEnd.year, localEnd.month, localEnd.day);
      final displayName = displayNames[occ.createdBy] ?? '?';
      for (var d = startDay;
          !d.isAfter(endDay);
          d = d.add(const Duration(days: 1))) {
        items.add(<String, String>{'d': _formatYmd(d), 'n': displayName});
      }
    }

    // gw_<gid>_name, gw_<gid>_title, gw_<gid>_occurrences_json
    final gid = groupId;
    await _platform.saveWidgetData('gw_${gid}_name', groupName);
    await _platform.saveWidgetData(
      'gw_${gid}_title',
      '${currentMonth.year}년 ${currentMonth.month}월',
    );
    await _platform.saveWidgetData(
      'gw_${gid}_occurrences_json',
      jsonEncode(items),
    );
  }

  static String _formatYmd(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 그룹 멤버 표시 이름을 계산한다.
  ///
  /// 기본값은 이름의 첫 글자(성)만 사용한다(예: 김철수 → "김"). 같은 첫 글자를
  /// 가진 멤버가 2명 이상이면, 가입(참여) 순서 — `joinedAt`(없으면 `createdAt`,
  /// 그마저 없으면 `id`) 기준으로 앞선 사람부터 A/B/C 접미사를 붙인다
  /// (예: "김A", "김B"). 이 방식은 위젯의 자동 표시용이며, 사용자가 그룹
  /// 멤버 화면에서 표시 이름을 직접 바꾸면 그 이름이 우선 사용된다.
  @visibleForTesting
  static Map<String, String> buildDisambiguatedDisplayNames(
    List<GroupMemberModel> members,
  ) {
    final sorted = List<GroupMemberModel>.from(members)
      ..sort((a, b) {
        final aJoin = a.joinedAt ?? a.createdAt;
        final bJoin = b.joinedAt ?? b.createdAt;
        if (aJoin == null && bJoin == null) return a.id.compareTo(b.id);
        if (aJoin == null) return 1;
        if (bJoin == null) return -1;
        return aJoin.compareTo(bJoin);
      });

    final bySurname = <String, List<GroupMemberModel>>{};
    for (final member in sorted) {
      final name = member.effectiveDisplayName;
      final surname = name.isEmpty ? '?' : name.substring(0, 1);
      bySurname.putIfAbsent(surname, () => <GroupMemberModel>[]).add(member);
    }

    final result = <String, String>{};
    for (final entry in bySurname.entries) {
      final group = entry.value;
      if (group.length == 1) {
        result[group.first.userId] = entry.key;
      } else {
        for (var i = 0; i < group.length; i++) {
          final suffix = String.fromCharCode('A'.codeUnitAt(0) + (i % 26));
          result[group[i].userId] = '${entry.key}$suffix';
        }
      }
    }
    return result;
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
