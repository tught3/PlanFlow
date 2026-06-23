import 'package:flutter/foundation.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import '../models/group_model.dart';
import '../repositories/group_dashboard_repository.dart';
import 'group_context_provider.dart';
import 'group_dashboard_state.dart';

class GroupDashboardProvider extends ChangeNotifier {
  GroupDashboardProvider({
    GroupContextProvider? contextProvider,
    GroupDashboardRepository? repository,
    DateTime Function()? nowProvider,
  })  : _contextProvider = contextProvider ?? GroupContextProvider(),
        _ownsContextProvider = contextProvider == null,
        _repository = repository ?? GroupDashboardRepository.supabase(),
        _nowProvider = nowProvider ?? planflowNow;

  final GroupContextProvider _contextProvider;
  final bool _ownsContextProvider;
  final GroupDashboardRepository _repository;
  final DateTime Function() _nowProvider;

  GroupDashboardState _state = const GroupDashboardState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupDashboardState get state => _state;
  GroupModel? get selectedGroup => _state.selectedGroup;
  String? get selectedGroupRole => _state.selectedGroupRole;
  int get todayEventCount => _state.todayEventCount;
  int get weekEventCount => _state.weekEventCount;
  int get memberCount => _state.memberCount;
  List<GroupEventModel> get upcomingEvents => _state.upcomingEvents;
  bool get isLoading => _state.isLoading;
  String? get error => _state.error;
  bool get hasSelectedGroup => _state.hasSelectedGroup;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;
  bool get hasUpcomingEvents => _state.hasUpcomingEvents;

  Future<void> load(String userId) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(const GroupDashboardState.initial());
      return;
    }

    _currentUserId = userId;
    _setState(_state.copyWith(isLoading: true, clearError: true));

    try {
      await _contextProvider.load(userId);
      await _reloadDashboard();
    } catch (error) {
      _setState(
        GroupDashboardState(
          selectedGroup: null,
          selectedGroupRole: null,
          todayEventCount: 0,
          weekEventCount: 0,
          memberCount: 0,
          upcomingEvents: const <GroupEventModel>[],
          isLoading: false,
          error: error.toString(),
        ),
      );
    }
  }

  Future<void> refresh() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      await load('');
      return;
    }
    await load(userId);
  }

  Future<void> _reloadDashboard() async {
    final group = _contextProvider.selectedGroup;
    if (group == null || !group.isActive) {
      _setState(
        _state.copyWith(
          selectedGroup: group,
          selectedGroupRole: _contextProvider.selectedGroupRole,
          todayEventCount: 0,
          weekEventCount: 0,
          memberCount: 0,
          upcomingEvents: const <GroupEventModel>[],
          isLoading: false,
          clearError: true,
        ),
      );
      return;
    }

    final summary = await _repository.loadDashboard(
      groupId: group.id,
      now: _nowProvider(),
    );
    _setState(
      GroupDashboardState(
        selectedGroup: group,
        selectedGroupRole: _contextProvider.selectedGroupRole,
        todayEventCount: summary.todayEventCount,
        weekEventCount: summary.weekEventCount,
        memberCount: summary.memberCount,
        upcomingEvents: summary.upcomingEvents,
        isLoading: false,
        error: null,
      ),
    );
  }

  void _setState(GroupDashboardState nextState) {
    _state = nextState;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_ownsContextProvider) {
      _contextProvider.dispose();
    }
    _isDisposed = true;
    super.dispose();
  }
}
