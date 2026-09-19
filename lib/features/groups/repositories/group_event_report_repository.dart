import 'package:supabase_flutter/supabase_flutter.dart';

/// 공유 그룹 일정 신고 사유 (DB check constraint와 동일한 값 집합).
abstract class GroupEventReportReason {
  static const String inappropriate = 'inappropriate';
  static const String spam = 'spam';
  static const String harassment = 'harassment';
  static const String other = 'other';

  static const Set<String> allowed = <String>{
    inappropriate,
    spam,
    harassment,
    other,
  };
}

/// 이미 같은 일정을 신고한 경우 (DB unique index 위반).
class AlreadyReportedException implements Exception {
  const AlreadyReportedException();
}

/// 정책 조사 결론(§10, 2026-09-19): 사용자 차단 기능은 1:1 기능(DM, 팔로우 등)이
/// 있는 서비스에만 필요하며 PlanFlow에는 1:1 기능이 없으므로 구현하지 않는다.
/// 신고 데이터는 운영자(admin email) RLS 정책 + Homepage admin 대시보드로 처리한다.

abstract class GroupEventReportRepository {
  const GroupEventReportRepository();

  factory GroupEventReportRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupEventReportRepository;

  Future<void> submitReport({
    required String groupEventId,
    required String groupId,
    required String reason,
    String? detail,
    String? contentOwnerId,
  });
}

class SupabaseGroupEventReportRepository extends GroupEventReportRepository {
  SupabaseGroupEventReportRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<void> submitReport({
    required String groupEventId,
    required String groupId,
    required String reason,
    String? detail,
    String? contentOwnerId,
  }) async {
    if (!GroupEventReportReason.allowed.contains(reason)) {
      throw StateError('허용되지 않은 신고 사유입니다.');
    }
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }

    final trimmedDetail = detail?.trim();
    final payload = <String, dynamic>{
      'reporter_id': user.id,
      'group_event_id': groupEventId,
      'group_id': groupId,
      'reason': reason,
      if (trimmedDetail != null && trimmedDetail.isNotEmpty)
        'detail': trimmedDetail,
      if (contentOwnerId != null && contentOwnerId.isNotEmpty)
        'content_owner_id': contentOwnerId,
    };

    try {
      await _client.from('group_event_reports').insert(payload);
    } on PostgrestException catch (error) {
      if (error.code == '23505' ||
          error.message.contains('duplicate key') ||
          error.message.contains('group_event_reports_reporter_event_uniq')) {
        throw const AlreadyReportedException();
      }
      rethrow;
    }
  }
}
