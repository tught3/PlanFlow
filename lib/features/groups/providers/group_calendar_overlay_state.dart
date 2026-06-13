import '../models/calendar_overlay_item.dart';
import '../models/group_model.dart';

class GroupCalendarOverlayState {
  const GroupCalendarOverlayState({
    required this.items,
    required this.isLoading,
    this.selectedGroup,
    this.selectedGroupRole,
    this.rangeStart,
    this.rangeEnd,
    this.error,
  });

  const GroupCalendarOverlayState.initial()
      : items = const <CalendarOverlayItem>[],
        selectedGroup = null,
        selectedGroupRole = null,
        rangeStart = null,
        rangeEnd = null,
        isLoading = false,
        error = null;

  final List<CalendarOverlayItem> items;
  final GroupModel? selectedGroup;
  final String? selectedGroupRole;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final bool isLoading;
  final String? error;

  bool get hasSelectedGroup => selectedGroup != null;

  bool get isPersonalMode => selectedGroup == null;

  bool get hasItems => items.isNotEmpty;

  bool get isLeaderOfSelectedGroup => selectedGroupRole == 'leader';

  GroupCalendarOverlayState copyWith({
    List<CalendarOverlayItem>? items,
    GroupModel? selectedGroup,
    bool clearSelectedGroup = false,
    String? selectedGroupRole,
    bool clearSelectedGroupRole = false,
    DateTime? rangeStart,
    bool clearRangeStart = false,
    DateTime? rangeEnd,
    bool clearRangeEnd = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return GroupCalendarOverlayState(
      items: items ?? this.items,
      selectedGroup:
          clearSelectedGroup ? null : selectedGroup ?? this.selectedGroup,
      selectedGroupRole: clearSelectedGroupRole
          ? null
          : selectedGroupRole ?? this.selectedGroupRole,
      rangeStart: clearRangeStart ? null : rangeStart ?? this.rangeStart,
      rangeEnd: clearRangeEnd ? null : rangeEnd ?? this.rangeEnd,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}
