import '../models/group_model.dart';

class GroupContextState {
  const GroupContextState({
    required this.groups,
    required this.isLoading,
    this.selectedGroup,
    this.selectedGroupRole,
    this.error,
  });

  const GroupContextState.initial()
      : groups = const <GroupModel>[],
        selectedGroup = null,
        selectedGroupRole = null,
        isLoading = false,
        error = null;

  final List<GroupModel> groups;
  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final bool isLoading;
  final String? error;

  bool get hasGroups => groups.isNotEmpty;

  bool get isPersonalMode => selectedGroup == null;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  GroupContextState copyWith({
    List<GroupModel>? groups,
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
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
    );
  }
}
