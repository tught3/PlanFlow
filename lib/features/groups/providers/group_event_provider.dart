import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/local_time.dart';
import '../models/group_event_model.dart';
import '../models/group_model.dart';
import '../models/group_role_delegation_model.dart';
import 'group_context_provider.dart';
import '../repositories/group_delegation_repository.dart';
import '../repositories/group_event_repository.dart';
import 'group_event_state.dart';

class GroupEventProvider extends ChangeNotifier {
  GroupEventProvider({
    GroupContextProvider? contextProvider,
    GroupEventRepository? repository,
    GroupDelegationRepository? delegationRepository,
    DateTime Function()? nowProvider,
    SupabaseClient? client,
  })  : _contextProvider = contextProvider ?? GroupContextProvider(),
        _ownsContextProvider = contextProvider == null,
        _repository =
            repository ?? GroupEventRepository.supabase(client: client),
        _delegationRepository = delegationRepository ??
            GroupDelegationRepository.supabase(client: client),
        _nowProvider = nowProvider ?? DateTime.now;

  final GroupContextProvider _contextProvider;
  final bool _ownsContextProvider;
  final GroupEventRepository _repository;
  final GroupDelegationRepository _delegationRepository;
  final DateTime Function() _nowProvider;

  GroupEventState _state = const GroupEventState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupEventState get state => _state;
  // 화면의 오늘/이번주 구분이 load 범위와 같은 시계를 쓰도록 주입된 nowProvider를
  // 로컬 시각으로 노출한다. 프로덕션에서는 planflowNow()와 동일하다.
  DateTime nowLocal() => planflowLocal(_nowProvider().toUtc());
  List<GroupEventModel> get events => _state.events;
  GroupModel? get selectedGroup => _state.selectedGroup;
  String? get selectedGroupRole => _state.selectedGroupRole;
  DateTime? get rangeStart => _state.rangeStart;
  DateTime? get rangeEnd => _state.rangeEnd;
  bool get isLoading => _state.isLoading;
  bool get isSubmitting => _state.isSubmitting;
  String? get error => _state.error;
  String? get message => _state.message;
  bool get hasEvents => _state.hasEvents;
  bool get hasSelectedGroup => _state.hasSelectedGroup;
  bool get isPersonalMode => _state.isPersonalMode;
  bool get isLeaderOfSelectedGroup => _state.isLeaderOfSelectedGroup;
  bool get canCreateEvent => _state.canCreateEvent;
  bool get canUpdateEvent => _state.canUpdateEvent;
  bool get canCancelEvent => _state.canCancelEvent;
  bool get canArchiveEvent => _state.canArchiveEvent;
  bool get canManageEvents => _state.canManageEvents;

  Future<void> load(String userId, {String? preferredGroupId}) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(const GroupEventState.initial());
      return;
    }

    _currentUserId = userId;
    _setState(
      _state.copyWith(
        isLoading: true,
        clearError: true,
        clearMessage: true,
      ),
    );

    try {
      await _contextProvider.load(userId, preferredGroupId: preferredGroupId);
      await _reloadEvents();
    } catch (error) {
      _setState(
        GroupEventState(
          events: const <GroupEventModel>[],
          selectedGroup: null,
          selectedGroupRole: null,
          rangeStart: null,
          rangeEnd: null,
          isLoading: false,
          isSubmitting: false,
          canCreateEvent: false,
          canUpdateEvent: false,
          canCancelEvent: false,
          canArchiveEvent: false,
          error: error.toString(),
          message: null,
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
    await load(userId, preferredGroupId: _state.selectedGroup?.id);
  }

  Future<GroupEventModel> createGroupEvent({
    required String title,
    String? description,
    String? location,
    required DateTime startAt,
    required DateTime endAt,
    required bool allDay,
    required String recurrenceType,
    DateTime? recurrenceUntil,
  }) async {
    final group = _requireSelectedGroup();
    if (!canCreateEvent) {
      throw StateError('현재 그룹에서는 일정을 만들 수 없어요.');
    }
    _validateRecurrenceType(recurrenceType);
    _validateTimeRange(startAt, endAt);
    _validateRecurrenceUntil(recurrenceUntil, startAt);
    final currentUserId = _requireCurrentUserId();

    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final created = await _repository.createGroupEvent(
        GroupEventModel(
          id: '',
          groupId: group.id,
          title: title.trim(),
          description: _emptyToNull(description),
          location: _emptyToNull(location),
          startAt: startAt,
          endAt: endAt,
          allDay: allDay,
          recurrenceType: recurrenceType,
          recurrenceUntil: recurrenceUntil,
          createdBy: currentUserId,
          status: 'active',
        ),
      );
      await refresh();
      _setState(
        _state.copyWith(
          isSubmitting: false,
          message: '그룹 일정을 만들었어요.',
        ),
      );
      return created;
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

  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    if (!_state.canUpdateEvent) {
      throw StateError('현재 그룹에서는 일정을 수정할 수 없어요.');
    }
    _requireCurrentUserId();
    _validateRecurrenceType(event.recurrenceType);
    _validateTimeRange(event.startAt, event.endAt);
    _validateRecurrenceUntil(event.recurrenceUntil, event.startAt);

    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final updated = await _repository.updateGroupEvent(event);
      await refresh();
      _setState(
        _state.copyWith(
          isSubmitting: false,
          message: '그룹 일정을 수정했어요.',
        ),
      );
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

  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    if (!_state.canCancelEvent) {
      throw StateError('현재 그룹에서는 일정을 취소할 수 없어요.');
    }
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final cancelled = await _repository.cancelGroupEvent(eventId);
      await refresh();
      _setState(
        _state.copyWith(
          isSubmitting: false,
          message: '그룹 일정을 취소했어요.',
        ),
      );
      return cancelled;
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

  Future<GroupEventModel> archiveGroupEvent(String eventId) async {
    if (!_state.canArchiveEvent) {
      throw StateError('현재 그룹에서는 일정을 보관할 수 없어요.');
    }
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final archived = await _repository.archiveGroupEvent(eventId);
      await refresh();
      _setState(
        _state.copyWith(
          isSubmitting: false,
          message: '그룹 일정을 보관했어요.',
        ),
      );
      return archived;
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

  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    return _repository.fetchGroupEvent(eventId);
  }

  bool canUpdateGroupEvent(GroupEventModel event) {
    return event.isActive && _state.canUpdateEvent;
  }

  bool canCancelGroupEvent(GroupEventModel event) {
    return event.isActive && _state.canCancelEvent;
  }

  bool canArchiveGroupEvent(GroupEventModel event) {
    return event.isActive && _state.canArchiveEvent;
  }

  Future<void> _reloadEvents() async {
    final group = _contextProvider.selectedGroup;
    if (group == null || !group.isActive) {
      _setState(
        _state.copyWith(
          events: const <GroupEventModel>[],
          selectedGroup: group,
          selectedGroupRole: _contextProvider.selectedGroupRole,
          clearRangeStart: true,
          clearRangeEnd: true,
          canCreateEvent: false,
          canUpdateEvent: false,
          canCancelEvent: false,
          canArchiveEvent: false,
          isLoading: false,
          clearError: true,
        ),
      );
      return;
    }

    final range = _defaultWeekRange();
    final events =
        await _repository.getEventsForGroup(group.id, range.start, range.end);
    final activePermissions = await _loadActivePermissions(group.id);
    final canCreate = activePermissions.contains('create_group_event');
    final canUpdate = activePermissions.contains('update_group_event');
    final canCancel = activePermissions.contains('cancel_group_event');
    _setState(
      GroupEventState(
        events: events,
        selectedGroup: group,
        selectedGroupRole: _contextProvider.selectedGroupRole,
        rangeStart: range.start,
        rangeEnd: range.end,
        isLoading: false,
        isSubmitting: false,
        canCreateEvent: canCreate,
        canUpdateEvent: canUpdate,
        canCancelEvent: canCancel,
        canArchiveEvent: canCancel,
        error: null,
        message: null,
      ),
    );
  }

  Future<Set<String>> _loadActivePermissions(String groupId) async {
    final permissions = <String>{};

    if (_contextProvider.isLeaderOfSelectedGroup) {
      permissions.addAll(<String>{
        'create_group_event',
        'update_group_event',
        'cancel_group_event',
      });
    } else if (_contextProvider.selectedGroupRole == 'member') {
      permissions.add('create_group_event');
    }

    final delegations = await _delegationRepository.getDelegationsForMe();
    final now = _nowProvider().toUtc();
    for (final delegation in delegations) {
      if (delegation.groupId != groupId || !delegation.isActive) {
        continue;
      }
      final startsAt = delegation.startsAt.toUtc();
      final endsAt = delegation.endsAt.toUtc();
      if (now.isBefore(startsAt) || !now.isBefore(endsAt)) {
        continue;
      }
      for (final permission in delegation.permissions) {
        if (GroupRoleDelegationModel.allowedPermissions.contains(permission)) {
          permissions.add(permission);
        }
      }
    }
    return permissions;
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

  ({DateTime start, DateTime end}) _defaultWeekRange() {
    final now = planflowLocal(_nowProvider().toUtc());
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - DateTime.monday));
    final weekEnd = weekStart.add(const Duration(days: 7));
    return (start: weekStart, end: weekEnd);
  }

  void _validateRecurrenceType(String recurrenceType) {
    if (!GroupEventModel.allowedRecurrenceTypes.contains(recurrenceType)) {
      throw StateError('허용되지 않은 반복 타입입니다.');
    }
  }

  void _validateTimeRange(DateTime startAt, DateTime endAt) {
    if (endAt.isBefore(startAt)) {
      throw StateError('종료 시각은 시작 시각보다 앞설 수 없습니다.');
    }
  }

  void _validateRecurrenceUntil(DateTime? recurrenceUntil, DateTime startAt) {
    if (recurrenceUntil != null && recurrenceUntil.isBefore(startAt)) {
      throw StateError('반복 종료 시각은 시작 시각보다 앞설 수 없습니다.');
    }
  }

  String? _emptyToNull(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  void _setState(GroupEventState nextState) {
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
