import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import '../models/group_member_model.dart';
import 'group_event_repository.dart';
import 'group_repository.dart';

/// 멤버 1인의 그룹 일정 공유 현황.
///
/// [sharedCount]가 0이어도 멤버 목록에 포함해, 리더가 "누가 아직
/// 공유하지 않았는지"까지 볼 수 있게 한다.
class MemberShareStat {
  const MemberShareStat({
    required this.userId,
    required this.displayName,
    required this.sharedCount,
    required this.isLeader,
    this.lastSharedAt,
  });

  final String userId;
  final String displayName;
  final int sharedCount;

  /// 이 멤버가 그룹 리더인지 여부. 멤버 목록류 UI는 항상 리더를 최상단에
  /// 표시해야 하므로 정렬/배지 표시에 사용한다.
  final bool isLeader;
  final DateTime? lastSharedAt;
}

class GroupDashboardSummary {
  const GroupDashboardSummary({
    required this.todayEventCount,
    required this.weekEventCount,
    required this.memberCount,
    required this.upcomingEvents,
    this.memberShareStats = const <MemberShareStat>[],
  });

  final int todayEventCount;
  final int weekEventCount;
  final int memberCount;
  final List<GroupEventModel> upcomingEvents;
  final List<MemberShareStat> memberShareStats;
}

abstract class GroupDashboardRepository {
  const GroupDashboardRepository();

  factory GroupDashboardRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupDashboardRepository;

  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
  });

  /// 특정 멤버가 [from]~[to] 구간에 공유(생성)한 그룹 일정 목록을
  /// startAt 오름차순으로 반환한다. 대시보드 멤버별 공유 현황 카드의
  /// 바텀시트에서 사용하며, 대시보드 요약의 "이번 주" 집계와는 별개로
  /// 임의 기간을 조회할 수 있다.
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String groupId,
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  });
}

class SupabaseGroupDashboardRepository extends GroupDashboardRepository {
  SupabaseGroupDashboardRepository({
    SupabaseClient? client,
    GroupRepository? groupRepository,
    GroupEventRepository? eventRepository,
  })  : _groupRepository =
            groupRepository ?? GroupRepository.supabase(client: client),
        _eventRepository =
            eventRepository ?? GroupEventRepository.supabase(client: client);

  final GroupRepository _groupRepository;
  final GroupEventRepository _eventRepository;

  @override
  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
  }) async {
    final group = await _groupRepository.fetchGroup(groupId);
    if (group == null) {
      throw StateError('선택한 그룹을 찾을 수 없습니다.');
    }
    if (!group.isActive) {
      throw StateError('보관된 그룹의 대시보드는 볼 수 없습니다.');
    }

    final members = await _groupRepository.listMembers(groupId);
    final activeMembers =
        members.where((member) => member.isActive).toList(growable: false);
    final range = _weekRange(now);
    final events = await _eventRepository.getEventsForGroup(
        groupId, range.start, range.end);
    final localNow = planflowLocal(now);
    final todayStart = DateTime(localNow.year, localNow.month, localNow.day);
    final todayEvents = events
        .where(
          (event) => planflowEventIntersectsLocalDay(
            startAt: event.startAt,
            endAt: event.endAt,
            day: todayStart,
          ),
        )
        .toList(growable: false);
    final upcomingEvents = events
        .where((event) => !planflowLocal(event.endAt).isBefore(localNow))
        .toList(growable: false)
      ..sort((left, right) => left.startAt.compareTo(right.startAt));

    final memberShareStats = _buildMemberShareStats(activeMembers, events);

    return GroupDashboardSummary(
      todayEventCount: todayEvents.length,
      weekEventCount: events.length,
      memberCount: activeMembers.length,
      upcomingEvents: upcomingEvents,
      memberShareStats: memberShareStats,
    );
  }

  /// 활성 멤버별 공유(생성) 일정 수와 최근 공유 시각을 집계한다.
  ///
  /// 0건인 멤버도 결과에 포함해 리더가 미참여 멤버를 확인할 수 있게 하고,
  /// 리더는 sharedCount와 무관하게 항상 최상단에 오도록 정렬한다.
  /// 리더 내부/멤버 내부는 sharedCount 내림차순, 동률이면 이름 오름차순.
  List<MemberShareStat> _buildMemberShareStats(
    List<GroupMemberModel> activeMembers,
    List<GroupEventModel> events,
  ) {
    final counts = <String, int>{};
    final lastSharedAt = <String, DateTime>{};
    for (final event in events) {
      final userId = event.createdBy;
      counts[userId] = (counts[userId] ?? 0) + 1;
      final candidate = event.createdAt ?? event.startAt;
      final current = lastSharedAt[userId];
      if (current == null || candidate.isAfter(current)) {
        lastSharedAt[userId] = candidate;
      }
    }

    final stats = activeMembers
        .map(
          (member) => MemberShareStat(
            userId: member.userId,
            displayName: member.effectiveDisplayName,
            sharedCount: counts[member.userId] ?? 0,
            isLeader: member.isLeader,
            lastSharedAt: lastSharedAt[member.userId],
          ),
        )
        .toList(growable: false);

    stats.sort((left, right) {
      if (left.isLeader != right.isLeader) {
        return left.isLeader ? -1 : 1;
      }
      final byCount = right.sharedCount.compareTo(left.sharedCount);
      if (byCount != 0) {
        return byCount;
      }
      return left.displayName.compareTo(right.displayName);
    });
    return stats;
  }

  @override
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String groupId,
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  }) async {
    final events =
        await _eventRepository.getEventsForGroup(groupId, from, to);
    final memberEvents = events
        .where((event) => event.createdBy == memberUserId)
        .toList(growable: false)
      ..sort((left, right) => left.startAt.compareTo(right.startAt));
    return memberEvents;
  }

  _WeekRange _weekRange(DateTime now) {
    final localNow = planflowLocal(now);
    final startOfDay = DateTime(localNow.year, localNow.month, localNow.day);
    final offset = startOfDay.weekday - DateTime.monday;
    final start = startOfDay.subtract(Duration(days: offset));
    final end = start.add(const Duration(days: 7));
    return _WeekRange(start: start, end: end);
  }
}

class _WeekRange {
  const _WeekRange({
    required this.start,
    required this.end,
  });

  final DateTime start;
  final DateTime end;
}
