import '../models/group_event_model.dart';
import '../models/group_model.dart';
import '../repositories/group_dashboard_repository.dart';

class GroupDashboardState {
  const GroupDashboardState({
    required this.todayEventCount,
    required this.weekEventCount,
    required this.memberCount,
    required this.upcomingEvents,
    required this.isLoading,
    this.selectedGroup,
    this.selectedGroupRole,
    this.error,
    this.memberShareStats = const <MemberShareStat>[],
  });

  const GroupDashboardState.initial()
      : selectedGroup = null,
        selectedGroupRole = null,
        todayEventCount = 0,
        weekEventCount = 0,
        memberCount = 0,
        upcomingEvents = const <GroupEventModel>[],
        isLoading = false,
        error = null,
        memberShareStats = const <MemberShareStat>[];

  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final int todayEventCount;
  final int weekEventCount;
  final int memberCount;
  final List<GroupEventModel> upcomingEvents;
  final bool isLoading;
  final String? error;

  /// 멤버별 공유(생성) 일정 현황. 그룹 미선택/에러 시 빈 목록.
  final List<MemberShareStat> memberShareStats;

  bool get hasSelectedGroup => selectedGroup != null;

  bool get isPersonalMode => selectedGroup == null;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  bool get hasUpcomingEvents => upcomingEvents.isNotEmpty;

  GroupDashboardState copyWith({
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    int? todayEventCount,
    int? weekEventCount,
    int? memberCount,
    List<GroupEventModel>? upcomingEvents,
    bool? isLoading,
    String? error,
    bool clearError = false,
    List<MemberShareStat>? memberShareStats,
  }) {
    return GroupDashboardState(
      selectedGroup:
          clearSelectedGroup ? null : selectedGroup ?? this.selectedGroup,
      selectedGroupRole: clearSelectedGroupRole
          ? null
          : selectedGroupRole ?? this.selectedGroupRole,
      todayEventCount: todayEventCount ?? this.todayEventCount,
      weekEventCount: weekEventCount ?? this.weekEventCount,
      memberCount: memberCount ?? this.memberCount,
      upcomingEvents: upcomingEvents ?? this.upcomingEvents,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
      memberShareStats: memberShareStats ?? this.memberShareStats,
    );
  }
}
