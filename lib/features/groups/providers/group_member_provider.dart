import 'package:flutter/foundation.dart';

import '../models/group_member_model.dart';
import '../models/group_model.dart';
import '../repositories/group_repository.dart';
import 'group_context_provider.dart';
import 'group_member_state.dart';

class GroupMemberProvider extends ChangeNotifier {
  GroupMemberProvider({
    GroupContextProvider? contextProvider,
    GroupRepository? repository,
  })  : _contextProvider = contextProvider ?? GroupContextProvider(),
        _ownsContextProvider = contextProvider == null,
        _repository = repository ?? GroupRepository.supabase();

  final GroupContextProvider _contextProvider;
  final bool _ownsContextProvider;
  final GroupRepository _repository;

  GroupMemberState _state = const GroupMemberState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupMemberState get state => _state;
  List<GroupMemberModel> get members => _state.members;
  GroupModel? get selectedGroup => _state.selectedGroup;
  String? get selectedGroupRole => _state.selectedGroupRole;
  bool get isLoading => _state.isLoading;
  bool get isSubmitting => _state.isSubmitting;
  String? get error => _state.error;
  bool get hasMembers => _state.hasMembers;
  bool get hasSelectedGroup => _state.hasSelectedGroup;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;

  Future<void> load(String userId) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(const GroupMemberState.initial());
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
      await _reloadMembers();
    } catch (error) {
      _setState(
        GroupMemberState(
          members: const <GroupMemberModel>[],
          selectedGroup: null,
          selectedGroupRole: null,
          isLoading: false,
          isSubmitting: false,
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

  Future<void> reload() async => refresh();

  Future<GroupMemberModel> removeMember(GroupMemberModel member) async {
    final currentUserId = _requireCurrentUserId();
    _requireSelectedGroup();
    if (!_state.isLeaderOfSelectedGroup) {
      throw StateError('멤버를 제거할 권한이 없어요.');
    }
    if (!member.isActive) {
      throw StateError('이미 제거된 멤버예요.');
    }
    if (member.userId == currentUserId) {
      throw StateError('자기 자신은 제거할 수 없어요.');
    }
    if (member.isLeader && _activeLeaderCount() <= 1) {
      throw StateError('마지막 리더는 제거할 수 없어요.');
    }

    _setState(
      _state.copyWith(
        isSubmitting: true,
        clearError: true,
      ),
    );
    try {
      final updated = await _repository.removeGroupMember(
        _requireSelectedGroup().id,
        member.userId,
      );
      await _reloadMembers();
      return updated;
    } catch (error) {
      _setState(
        _state.copyWith(
          isSubmitting: false,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  bool canRemoveMember(GroupMemberModel member) {
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return false;
    }
    if (!_state.isLeaderOfSelectedGroup) {
      return false;
    }
    if (!member.isActive) {
      return false;
    }
    if (member.userId == currentUserId) {
      return false;
    }
    if (member.isLeader && _activeLeaderCount() <= 1) {
      return false;
    }
    return true;
  }

  Future<void> _reloadMembers() async {
    final group = _contextProvider.selectedGroup;
    if (group == null || !group.isActive) {
      _setState(
        _state.copyWith(
          members: const <GroupMemberModel>[],
          selectedGroup: group,
          selectedGroupRole: _contextProvider.selectedGroupRole,
          clearSelectedGroup: group == null,
          clearSelectedGroupRole: group == null,
          isLoading: false,
          isSubmitting: false,
          clearError: true,
        ),
      );
      return;
    }

    final members = await _repository.listMembers(group.id);
    _setState(
      GroupMemberState(
        members: _sortMembers(members),
        selectedGroup: group,
        selectedGroupRole: _contextProvider.selectedGroupRole,
        isLoading: false,
        isSubmitting: false,
        error: null,
      ),
    );
  }

  List<GroupMemberModel> _sortMembers(List<GroupMemberModel> members) {
    final sorted = members.toList(growable: false);
    sorted.sort((a, b) {
      final statusOrder = _statusOrder(a.status).compareTo(_statusOrder(b.status));
      if (statusOrder != 0) {
        return statusOrder;
      }
      final roleOrder = _roleOrder(a.role).compareTo(_roleOrder(b.role));
      if (roleOrder != 0) {
        return roleOrder;
      }
      final aJoined = a.joinedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bJoined = b.joinedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aJoined.compareTo(bJoined);
    });
    return sorted;
  }

  int _activeLeaderCount() {
    return _state.members
        .where((member) => member.isActive && member.isLeader)
        .length;
  }

  int _statusOrder(String status) {
    return switch (status) {
      'active' => 0,
      'removed' => 1,
      _ => 2,
    };
  }

  int _roleOrder(String role) {
    return role == 'leader' ? 0 : 1;
  }

  GroupModel _requireSelectedGroup() {
    final group = _contextProvider.selectedGroup;
    if (group == null) {
      throw StateError('선택된 그룹이 없어요.');
    }
    return group;
  }

  String _requireCurrentUserId() {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    return userId;
  }

  void _setState(GroupMemberState nextState) {
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
