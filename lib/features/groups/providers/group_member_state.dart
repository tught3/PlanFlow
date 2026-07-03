import '../models/group_member_model.dart';
import '../models/group_model.dart';

class GroupMemberState {
  const GroupMemberState({
    required this.members,
    required this.isLoading,
    required this.isSubmitting,
    this.selectedGroup,
    this.selectedGroupRole,
    this.error,
  });

  const GroupMemberState.initial()
      : members = const <GroupMemberModel>[],
        selectedGroup = null,
        selectedGroupRole = null,
        isLoading = false,
        isSubmitting = false,
        error = null;

  final List<GroupMemberModel> members;
  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;

  bool get hasSelectedGroup => selectedGroup != null;

  bool get isPersonalMode => selectedGroup == null;

  bool get hasMembers => members.isNotEmpty;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  GroupMemberState copyWith({
    List<GroupMemberModel>? members,
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
  }) {
    return GroupMemberState(
      members: members ?? this.members,
      selectedGroup:
          clearSelectedGroup ? null : selectedGroup ?? this.selectedGroup,
      selectedGroupRole: clearSelectedGroupRole
          ? null
          : selectedGroupRole ?? this.selectedGroupRole,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
    );
  }
}
