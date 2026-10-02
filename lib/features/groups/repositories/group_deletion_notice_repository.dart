import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_deletion_notice_model.dart';

abstract class GroupDeletionNoticeRepository {
  const GroupDeletionNoticeRepository();

  factory GroupDeletionNoticeRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupDeletionNoticeRepository;

  Future<List<GroupDeletionNoticeModel>> listPendingForUser(String userId);

  Future<void> acknowledge({
    required String noticeId,
    required String userId,
  });
}

class SupabaseGroupDeletionNoticeRepository
    extends GroupDeletionNoticeRepository {
  SupabaseGroupDeletionNoticeRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<GroupDeletionNoticeModel>> listPendingForUser(
    String userId,
  ) async {
    final response = await _client
        .from('group_deletion_notices')
        .select('id, deleted_group_id, group_name, deleted_at')
        .eq('recipient_user_id', userId)
        .isFilter('acknowledged_at', null)
        .order('deleted_at');
    return response
        .map<GroupDeletionNoticeModel>(
          (row) => GroupDeletionNoticeModel.fromJson(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> acknowledge({
    required String noticeId,
    required String userId,
  }) async {
    await _client
        .from('group_deletion_notices')
        .update(<String, dynamic>{
          'acknowledged_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', noticeId)
        .eq('recipient_user_id', userId)
        .isFilter('acknowledged_at', null);
  }
}
