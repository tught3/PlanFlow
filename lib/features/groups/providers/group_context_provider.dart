import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/group_member_model.dart';
import '../models/group_model.dart';
import '../repositories/group_repository.dart';
import 'group_context_state.dart';

class GroupContextProvider extends ChangeNotifier {
  GroupContextProvider({
    GroupRepository? repository,
    SharedPreferences? preferences,
  })  : _repository = repository ?? GroupRepository.supabase(),
        _preferencesOverride = preferences;

  static const String _selectedGroupKeyPrefix =
      'planflow:group_context:selected_group_id:v1:';

  final GroupRepository _repository;
  final SharedPreferences? _preferencesOverride;

  GroupContextState _state = const GroupContextState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupContextState get state => _state;
  List<GroupModel> get groups => _state.groups;
  GroupModel? get selectedGroup => _state.selectedGroup;
  String? get selectedGroupRole => _state.selectedGroupRole;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLoading => _state.isLoading;
  String? get error => _state.error;
  bool get hasGroups => _state.hasGroups;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;

  Future<void> load(String userId, {String? preferredGroupId}) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(
        const GroupContextState(
          groups: <GroupModel>[],
          selectedGroup: null,
          selectedGroupRole: null,
          isLoading: false,
          error: null,
        ),
      );
      return;
    }

    _currentUserId = userId;
    _setState(_state.copyWith(isLoading: true, clearError: true));

    try {
      final groups = await _repository.listGroups();
      final memberships = await _loadMembershipsForGroups(groups, userId);
      final selectedGroupId = await _resolveSelectedGroupId(
        groups,
        memberships,
        preferredGroupId: preferredGroupId,
      );
      final selectedGroup = _findGroupById(groups, selectedGroupId);
      final selectedRole =
          selectedGroupId == null ? null : memberships[selectedGroupId]?.role;

      _setState(
        GroupContextState(
          groups: groups,
          selectedGroup: selectedGroup,
          selectedGroupRole: selectedRole,
          isLoading: false,
          error: null,
        ),
      );

      await _persistSelectedGroupId(selectedGroupId);
    } catch (error) {
      _setState(
        GroupContextState(
          groups: const <GroupModel>[],
          selectedGroup: null,
          selectedGroupRole: null,
          isLoading: false,
          error: error.toString(),
        ),
      );
    }
  }

  Future<void> refresh() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      _currentUserId = null;
      _setState(
        const GroupContextState(
          groups: <GroupModel>[],
          selectedGroup: null,
          selectedGroupRole: null,
          isLoading: false,
          error: null,
        ),
      );
      return;
    }
    await load(userId);
  }

  Future<void> selectGroup(String? groupId) async {
    if (groupId == null) {
      await clearSelectedGroup();
      return;
    }

    final group = _findGroupById(_state.groups, groupId);
    if (group == null) {
      throw StateError('선택할 수 없는 그룹입니다.');
    }

    final role = await _resolveRoleForGroup(groupId, _currentUserId);
    if (role == null) {
      throw StateError('선택할 수 없는 그룹입니다.');
    }

    _setState(
      _state.copyWith(
        selectedGroup: group,
        selectedGroupRole: role,
        clearError: true,
      ),
    );
    await _persistSelectedGroupId(groupId);
  }

  Future<void> clearSelectedGroup() async {
    _setState(
      _state.copyWith(
        clearSelectedGroup: true,
        clearSelectedGroupRole: true,
        clearError: true,
      ),
    );
    await _persistSelectedGroupId(null);
  }

  Future<Map<String, GroupMemberModel>> _loadMembershipsForGroups(
    List<GroupModel> groups,
    String userId,
  ) async {
    final futures = groups.map((group) async {
      final members = await _repository.listMembers(group.id);
      GroupMemberModel? activeMembership;
      for (final member in members) {
        if (member.userId == userId && member.status == 'active') {
          activeMembership = member;
          break;
        }
      }
      return MapEntry<String, GroupMemberModel?>(group.id, activeMembership);
    });

    final resolved = await Future.wait(futures);
    final memberships = <String, GroupMemberModel>{};
    for (final entry in resolved) {
      final membership = entry.value;
      if (membership != null) {
        memberships[entry.key] = membership;
      }
    }
    return memberships;
  }

  Future<String?> _resolveSelectedGroupId(
    List<GroupModel> groups,
    Map<String, GroupMemberModel> memberships, {
    String? preferredGroupId,
  }) async {
    final normalizedPreferredGroupId = preferredGroupId?.trim();
    if (normalizedPreferredGroupId != null &&
        normalizedPreferredGroupId.isNotEmpty &&
        groups.any((group) => group.id == normalizedPreferredGroupId) &&
        memberships.containsKey(normalizedPreferredGroupId)) {
      return normalizedPreferredGroupId;
    }

    final storedSelectedGroupId = await _readSelectedGroupId();
    if (storedSelectedGroupId != null &&
        groups.any((group) => group.id == storedSelectedGroupId) &&
        memberships.containsKey(storedSelectedGroupId)) {
      return storedSelectedGroupId;
    }

    final leaderGroup = _findPreferredGroup(
      groups,
      memberships,
      (membership) => membership.isLeader,
    );
    if (leaderGroup != null) {
      return leaderGroup.id;
    }

    final memberGroup = _findPreferredGroup(
      groups,
      memberships,
      (membership) => membership.isActive && !membership.isLeader,
    );
    if (memberGroup != null) {
      return memberGroup.id;
    }

    return null;
  }

  GroupModel? _findPreferredGroup(
    List<GroupModel> groups,
    Map<String, GroupMemberModel> memberships,
    bool Function(GroupMemberModel membership) predicate,
  ) {
    for (final group in groups) {
      final membership = memberships[group.id];
      if (membership != null && predicate(membership)) {
        return group;
      }
    }
    return null;
  }

  GroupModel? _findGroupById(List<GroupModel> groups, String? groupId) {
    if (groupId == null || groupId.isEmpty) {
      return null;
    }
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  Future<String?> _resolveRoleForGroup(String groupId, String? userId) async {
    if (userId == null || userId.isEmpty) {
      return null;
    }
    final members = await _repository.listMembers(groupId);
    for (final member in members) {
      if (member.userId == userId && member.status == 'active') {
        return member.role;
      }
    }
    return null;
  }

  Future<String?> _readSelectedGroupId() async {
    final preferences = await _resolvePreferences();
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      return null;
    }
    return preferences.getString(_selectedGroupKey(userId));
  }

  Future<void> _persistSelectedGroupId(String? groupId) async {
    final preferences = await _resolvePreferences();
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    final key = _selectedGroupKey(userId);
    if (groupId == null || groupId.isEmpty) {
      await preferences.remove(key);
      return;
    }
    await preferences.setString(key, groupId);
  }

  Future<SharedPreferences> _resolvePreferences() async {
    return _preferencesOverride ?? await SharedPreferences.getInstance();
  }

  String _selectedGroupKey(String userId) {
    return '$_selectedGroupKeyPrefix$userId';
  }

  void _setState(GroupContextState nextState) {
    _state = nextState;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
