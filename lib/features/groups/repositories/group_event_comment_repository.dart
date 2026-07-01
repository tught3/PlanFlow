import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_event_comment_model.dart';

abstract class GroupEventCommentRepository {
  const GroupEventCommentRepository();

  factory GroupEventCommentRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupEventCommentRepository;

  Future<List<GroupEventCommentModel>> getCommentsForEvent(String groupEventId);

  Future<GroupEventCommentModel> createComment(GroupEventCommentModel comment);

  Future<GroupEventCommentModel> confirmComment(String commentId);

  Future<List<GroupEventCommentModel>> unconfirmedForUser(String userId);
}

class SupabaseGroupEventCommentRepository extends GroupEventCommentRepository {
  SupabaseGroupEventCommentRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<GroupEventCommentModel>> getCommentsForEvent(
      String groupEventId) async {
    final response = await _client
        .from('group_event_comments')
        .select()
        .eq('group_event_id', groupEventId)
        .order('created_at', ascending: false);
    return response
        .map<GroupEventCommentModel>(
            (row) => GroupEventCommentModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<GroupEventCommentModel> createComment(
      GroupEventCommentModel comment) async {
    final currentUser = _requireCurrentUser();

    final response = await _client
        .from('group_event_comments')
        .insert(
          comment.copyWith(authorUserId: currentUser.id).toJson(includeId: false),
        )
        .select()
        .single();
    return GroupEventCommentModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupEventCommentModel> confirmComment(String commentId) async {
    final currentUser = _requireCurrentUser();

    final response = await _client
        .from('group_event_comments')
        .update(
          <String, dynamic>{
            'confirmed_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        )
        .eq('id', commentId)
        .eq('target_user_id', currentUser.id)
        .select()
        .single();
    return GroupEventCommentModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupEventCommentModel>> unconfirmedForUser(String userId) async {
    final response = await _client
        .from('group_event_comments')
        .select()
        .eq('target_user_id', userId)
        .filter('confirmed_at', 'is', null)
        .order('created_at', ascending: false);
    return response
        .map<GroupEventCommentModel>(
            (row) => GroupEventCommentModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  User _requireCurrentUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    return user;
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
