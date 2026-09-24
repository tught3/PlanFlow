import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_deletion_notice.dart';

abstract class GroupDeletionNoticeRepository {
  const GroupDeletionNoticeRepository();

  factory GroupDeletionNoticeRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupDeletionNoticeRepository;

  Future<List<GroupDeletionNotice>> listPending();

  Future<void> acknowledge(String noticeId);
}

class SupabaseGroupDeletionNoticeRepository
    extends GroupDeletionNoticeRepository {
  SupabaseGroupDeletionNoticeRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<GroupDeletionNotice>> listPending() async {
    final response = await _client.rpc('list_my_group_deletion_notices');
    return (response as List<dynamic>)
        .map(
          (row) => GroupDeletionNotice.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> acknowledge(String noticeId) async {
    await _client.rpc(
      'acknowledge_group_deletion_notice',
      params: <String, dynamic>{'notice_id_input': noticeId},
    );
  }
}
