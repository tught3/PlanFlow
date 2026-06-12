import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import 'group_event_repository.dart';
import 'group_repository.dart';

class GroupDashboardSummary {
  const GroupDashboardSummary({
    required this.todayEventCount,
    required this.weekEventCount,
    required this.memberCount,
    required this.upcomingEvents,
  });

  final int todayEventCount;
  final int weekEventCount;
  final int memberCount;
  final List<GroupEventModel> upcomingEvents;
}

abstract class GroupDashboardRepository {
  const GroupDashboardRepository();

  factory GroupDashboardRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupDashboardRepository;

  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
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

    return GroupDashboardSummary(
      todayEventCount: todayEvents.length,
      weekEventCount: events.length,
      memberCount: activeMembers.length,
      upcomingEvents: upcomingEvents,
    );
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
