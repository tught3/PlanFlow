import '../models/group_member_model.dart';
import '../models/group_model.dart';

class GroupContextState {
  const GroupContextState({
    required this.groups,
    required this.isLoading,
    this.selectedGroup,
    this.selectedGroupRole,
    this.error,
    this.memberships = const <String, GroupMemberModel>{},
  });

  const GroupContextState.initial()
      : groups = const <GroupModel>[],
        selectedGroup = null,
        selectedGroupRole = null,
        isLoading = false,
        error = null,
        memberships = const <String, GroupMemberModel>{};

  final List<GroupModel> groups;
  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final bool isLoading;
  final String? error;

  /// 그룹 id -> 내 멤버십(역할 포함). 리더인 그룹 목록 계산 등에 쓴다.
  final Map<String, GroupMemberModel> memberships;

  bool get hasGroups => groups.isNotEmpty;

  bool get isPersonalMode => selectedGroup == null;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  /// 내가 리더인 활성 그룹 목록(설정탭 "리더 그룹 일정공유" 토글 등에 사용).
  List<GroupModel> get leaderGroups => groups
      .where((group) => memberships[group.id]?.isLeader == true)
      .toList(growable: false);

  GroupContextState copyWith({
    List<GroupModel>? groups,
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
    Map<String, GroupMemberModel>? memberships,
  }) {
    return GroupContextState(
      groups: groups ?? this.groups,
      selectedGroup:
          clearSelectedGroup ? null : selectedGroup ?? this.selectedGroup,
      selectedGroupRole: clearSelectedGroupRole
          ? null
          : selectedGroupRole ?? this.selectedGroupRole,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
      memberships: memberships ?? this.memberships,
    );
  }
}
