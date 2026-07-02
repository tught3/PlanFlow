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
  List<MemberShareStat> get memberShareStats => _state.memberShareStats;
  bool get hasSelectedGroup => _state.hasSelectedGroup;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;
  bool get hasUpcomingEvents => _state.hasUpcomingEvents;

  Future<void> load(String userId, {String? preferredGroupId}) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(const GroupDashboardState.initial());
      return;
    }

    _currentUserId = userId;
    _setState(_state.copyWith(isLoading: true, clearError: true));

    try {
      await _contextProvider.load(userId, preferredGroupId: preferredGroupId);
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
          memberShareStats: const <MemberShareStat>[],
        ),
      );
    }
  }

  /// 특정 멤버가 [from]~[to] 구간에 공유한 그룹 일정을 조회한다.
  /// 대시보드 요약의 "이번 주" 집계와 무관한 별도 조회이며, 그룹이
  /// 선택되어 있지 않으면 빈 목록을 반환한다.
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  }) async {
    final group = _state.selectedGroup;
    if (group == null) {
      return const <GroupEventModel>[];
    }
    return _repository.fetchMemberEvents(
      groupId: group.id,
      memberUserId: memberUserId,
      from: from,
      to: to,
    );
  }

  Future<void> refresh() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      await load('');
      return;
    }
    await load(userId, preferredGroupId: _state.selectedGroup?.id);
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
          memberShareStats: const <MemberShareStat>[],
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
        memberShareStats: summary.memberShareStats,
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
