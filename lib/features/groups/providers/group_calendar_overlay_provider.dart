import 'package:flutter/foundation.dart';

import '../models/calendar_overlay_item.dart';
import '../models/group_model.dart';
import '../repositories/group_event_repository.dart';
import 'group_context_provider.dart';
import 'group_calendar_overlay_state.dart';

class GroupCalendarOverlayProvider extends ChangeNotifier {
  GroupCalendarOverlayProvider({
    GroupContextProvider? contextProvider,
    GroupEventRepository? repository,
  })  : _contextProvider = contextProvider ?? GroupContextProvider(),
        _ownsContextProvider = contextProvider == null,
        _repository = repository ?? GroupEventRepository.supabase();

  final GroupContextProvider _contextProvider;
  final bool _ownsContextProvider;
  final GroupEventRepository _repository;

  GroupCalendarOverlayState _state = const GroupCalendarOverlayState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupCalendarOverlayState get state => _state;
  List<CalendarOverlayItem> get items => _state.items;
  GroupModel? get selectedGroup => _state.selectedGroup;
  String? get selectedGroupRole => _state.selectedGroupRole;
  bool get isLoading => _state.isLoading;
  String? get error => _state.error;
  bool get hasSelectedGroup => _state.hasSelectedGroup;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;
  bool get hasItems => _state.hasItems;

  Future<void> load(
    String userId, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(const GroupCalendarOverlayState.initial());
      return;
    }

    _currentUserId = userId;
    _setState(
      _state.copyWith(
        isLoading: true,
        clearError: true,
      ),
    );

    try {
      await _contextProvider.load(userId);
      if (_contextProvider.error != null) {
        throw StateError(_contextProvider.error!);
      }
      final group = _contextProvider.selectedGroup;
      if (group == null || !group.isActive) {
        _setState(
          GroupCalendarOverlayState(
            items: const <CalendarOverlayItem>[],
            selectedGroup: null,
            selectedGroupRole: null,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            isLoading: false,
            error: null,
          ),
        );
        return;
      }

      final events =
          await _repository.getEventsForGroup(group.id, rangeStart, rangeEnd);
      _setState(
        GroupCalendarOverlayState(
          items: events
              .map(
                (event) => CalendarOverlayItem.fromGroupEvent(
                  event,
                  groupName: group.name,
                ),
              )
              .toList(growable: false),
          selectedGroup: group,
          selectedGroupRole: _contextProvider.selectedGroupRole,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          isLoading: false,
          error: null,
        ),
      );
    } catch (error) {
      _setState(
        GroupCalendarOverlayState(
          items: const <CalendarOverlayItem>[],
          selectedGroup: _contextProvider.selectedGroup,
          selectedGroupRole: _contextProvider.selectedGroupRole,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          isLoading: false,
          error: error.toString(),
        ),
      );
    }
  }

  Future<void> refresh() async {
    final userId = _currentUserId;
    final rangeStart = _state.rangeStart;
    final rangeEnd = _state.rangeEnd;
    if (userId == null || userId.isEmpty || rangeStart == null || rangeEnd == null) {
      await load('', rangeStart: DateTime.now(), rangeEnd: DateTime.now());
      return;
    }
    await load(userId, rangeStart: rangeStart, rangeEnd: rangeEnd);
  }

  Future<void> clear() async {
    _currentUserId = null;
    _setState(const GroupCalendarOverlayState.initial());
  }

  Future<void> loadForMonth(
    String userId,
    DateTime focusedMonth,
  ) async {
    final monthStart = DateTime(focusedMonth.year, focusedMonth.month);
    final monthEnd = DateTime(focusedMonth.year, focusedMonth.month + 1);
    await load(
      userId,
      rangeStart: monthStart,
      rangeEnd: monthEnd,
    );
  }

  void _setState(GroupCalendarOverlayState nextState) {
    _state = nextState;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (_ownsContextProvider) {
      _contextProvider.dispose();
    }
    super.dispose();
  }
}
