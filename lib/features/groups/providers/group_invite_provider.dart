import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_invite_model.dart';
import '../models/group_json.dart';
import '../repositories/group_invite_repository.dart';
import 'group_invite_state.dart';

class GroupInviteProvider extends ChangeNotifier {
  GroupInviteProvider({
    GroupInviteRepository? repository,
    Future<Map<String, dynamic>> Function(String userId)? profileLoader,
    SupabaseClient? client,
  })  : _repository = repository ?? GroupInviteRepository.supabase(),
        _profileLoader = profileLoader,
        _client = client;

  final GroupInviteRepository _repository;
  final Future<Map<String, dynamic>> Function(String userId)? _profileLoader;
  final SupabaseClient? _client;

  GroupInviteState _state = const GroupInviteState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  GroupInviteState get state => _state;
  List<GroupInviteModel> get pendingInvites => _state.pendingInvites;
  String? get currentInviteCode => _state.currentInviteCode;
  String? get currentDisplayName => _state.currentDisplayName;
  bool get isLoading => _state.isLoading;
  bool get isSubmitting => _state.isSubmitting;
  String? get error => _state.error;
  String? get message => _state.message;
  bool get hasPendingInvites => _state.hasPendingInvites;
  bool get hasInviteCode => _state.hasInviteCode;

  Future<void> load(String userId) async {
    if (userId.isEmpty) {
      _currentUserId = null;
      _setState(
        const GroupInviteState(
          pendingInvites: <GroupInviteModel>[],
          currentInviteCode: null,
          currentDisplayName: null,
          isLoading: false,
          isSubmitting: false,
          error: null,
          message: null,
        ),
      );
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
      final profile = await _loadProfile(userId);
      final pendingInvites = await _repository.getPendingInvitesForMe();
      _setState(
        GroupInviteState(
          pendingInvites: pendingInvites,
          currentInviteCode: stringValue(profile['invite_code']).trim(),
          currentDisplayName: stringValue(profile['display_name']).trim(),
          isLoading: false,
          isSubmitting: false,
          error: null,
          message: null,
        ),
      );
    } catch (error) {
      _setState(
        GroupInviteState(
          pendingInvites: const <GroupInviteModel>[],
          currentInviteCode: null,
          currentDisplayName: null,
          isLoading: false,
          isSubmitting: false,
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
    await load(userId);
  }

  Future<GroupInviteModel> createInviteByInviteCode({
    required String groupId,
    required String inviteCode,
  }) async {
    return _performSubmission(
      actionLabel: '초대를 보냈어요.',
      action: () => _repository.createInviteByInviteCode(
        groupId: groupId,
        inviteCode: inviteCode,
      ),
    );
  }

  Future<GroupInviteModel> createInviteByEmail({
    required String groupId,
    required String email,
  }) async {
    return _performSubmission(
      actionLabel: '이메일 초대를 보냈어요.',
      action: () => _repository.createInviteByEmail(
        groupId: groupId,
        email: email,
      ),
    );
  }

  Future<void> updateMyDisplayName(String displayName) async {
    final userId = _currentUserId;
    if (userId == null || userId.trim().isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    final trimmed = displayName.trim();
    _setState(
      _state.copyWith(
        isSubmitting: true,
        clearError: true,
        clearMessage: true,
      ),
    );
    try {
      final response = await _resolvedClient
          .from('users')
          .update(<String, dynamic>{
            'display_name': trimmed.isEmpty ? null : trimmed,
          })
          .eq('id', userId)
          .select('id,email,invite_code,display_name')
          .single();
      final profile = Map<String, dynamic>.from(response as Map);
      _setState(
        _state.copyWith(
          currentInviteCode: stringValue(profile['invite_code']).trim(),
          currentDisplayName: stringValue(profile['display_name']).trim(),
          isSubmitting: false,
          message: '내 이름을 저장했어요.',
        ),
      );
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

  Future<GroupInviteModel> acceptInvite(String inviteId) async {
    final updated = await _performSubmission(
      actionLabel: '초대를 수락했어요.',
      action: () => _repository.acceptInvite(inviteId),
      refreshAfterSuccess: true,
    );
    return updated;
  }

  Future<GroupInviteModel> acceptInviteLink({
    required String groupId,
    required String inviteToken,
  }) async {
    final updated = await _performSubmission(
      actionLabel: '그룹에 참여했어요.',
      action: () => _repository.acceptInviteLink(
        groupId: groupId,
        inviteToken: inviteToken,
      ),
      refreshAfterSuccess: true,
    );
    return updated;
  }

  Future<GroupInviteModel> rejectInvite(String inviteId) async {
    final updated = await _performSubmission(
      actionLabel: '초대를 거절했어요.',
      action: () => _repository.rejectInvite(inviteId),
      refreshAfterSuccess: true,
    );
    return updated;
  }

  Future<GroupInviteModel> cancelInvite(String inviteId) async {
    final updated = await _performSubmission(
      actionLabel: '초대를 취소했어요.',
      action: () => _repository.cancelInvite(inviteId),
      refreshAfterSuccess: true,
    );
    return updated;
  }

  Future<Map<String, dynamic>> _loadProfile(String userId) async {
    if (_profileLoader != null) {
      return _profileLoader(userId);
    }

    final response = await _resolvedClient
        .from('users')
        .select('id,email,invite_code,display_name')
        .eq('id', userId)
        .maybeSingle();
    if (response != null) {
      final profile = Map<String, dynamic>.from(response as Map);
      if (stringValue(profile['invite_code']).trim().isNotEmpty) {
        return profile;
      }
    }
    final ensured = await _resolvedClient
        .rpc('ensure_current_user_profile')
        .select()
        .single();
    return Map<String, dynamic>.from(ensured as Map);
  }

  Future<T> _performSubmission<T>({
    required String actionLabel,
    required Future<T> Function() action,
    bool refreshAfterSuccess = false,
  }) async {
    _setState(
      _state.copyWith(
        isSubmitting: true,
        clearError: true,
        clearMessage: true,
      ),
    );
    try {
      final result = await action();
      if (refreshAfterSuccess) {
        await refresh();
      }
      _setState(
        _state.copyWith(
          isSubmitting: false,
          message: actionLabel,
        ),
      );
      return result;
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

  void _setState(GroupInviteState nextState) {
    _state = nextState;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  SupabaseClient get _resolvedClient => _client ?? Supabase.instance.client;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
