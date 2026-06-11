import '../models/group_event_model.dart';
import '../models/group_model.dart';

class GroupEventState {
  const GroupEventState({
    required this.events,
    required this.isLoading,
    required this.isSubmitting,
    required this.canCreateEvent,
    required this.canUpdateEvent,
    required this.canCancelEvent,
    required this.canArchiveEvent,
    this.selectedGroup,
    this.selectedGroupRole,
    this.rangeStart,
    this.rangeEnd,
    this.error,
    this.message,
  });

  const GroupEventState.initial()
      : events = const <GroupEventModel>[],
        selectedGroup = null,
        selectedGroupRole = null,
        rangeStart = null,
        rangeEnd = null,
        isLoading = false,
        isSubmitting = false,
        canCreateEvent = false,
        canUpdateEvent = false,
        canCancelEvent = false,
        canArchiveEvent = false,
        error = null,
        message = null;

  final List<GroupEventModel> events;
  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final bool isLoading;
  final bool isSubmitting;
  final bool canCreateEvent;
  final bool canUpdateEvent;
  final bool canCancelEvent;
  final bool canArchiveEvent;
  final String? error;
  final String? message;

  bool get hasEvents => events.isNotEmpty;

  bool get hasSelectedGroup => selectedGroup != null;

  bool get isPersonalMode => selectedGroup == null;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  bool get canManageEvents =>
      canUpdateEvent || canCancelEvent || canArchiveEvent;

  GroupEventState copyWith({
    List<GroupEventModel>? events,
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    DateTime? rangeStart,
    bool clearRangeStart = false,
    DateTime? rangeEnd,
    bool clearRangeEnd = false,
    bool? isLoading,
    bool? isSubmitting,
    bool? canCreateEvent,
    bool? canUpdateEvent,
    bool? canCancelEvent,
    bool? canArchiveEvent,
    String? error,
    bool clearError = false,
    String? message,
    bool clearMessage = false,
  }) {
    return GroupEventState(
      events: events ?? this.events,
      selectedGroup:
          clearSelectedGroup ? null : selectedGroup ?? this.selectedGroup,
      selectedGroupRole: clearSelectedGroupRole
          ? null
          : selectedGroupRole ?? this.selectedGroupRole,
      rangeStart: clearRangeStart ? null : rangeStart ?? this.rangeStart,
      rangeEnd: clearRangeEnd ? null : rangeEnd ?? this.rangeEnd,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      canCreateEvent: canCreateEvent ?? this.canCreateEvent,
      canUpdateEvent: canUpdateEvent ?? this.canUpdateEvent,
      canCancelEvent: canCancelEvent ?? this.canCancelEvent,
      canArchiveEvent: canArchiveEvent ?? this.canArchiveEvent,
      error: clearError ? null : error ?? this.error,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}
