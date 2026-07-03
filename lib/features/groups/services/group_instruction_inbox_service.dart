import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/notification_service.dart';
import '../repositories/group_event_comment_repository.dart';
import '../repositories/group_event_repository.dart';

/// 팀 리더 지시(그룹 이벤트 코멘트) 수신함 서비스.
///
/// - [unconfirmedPersonalEventIds]: 미확인 지시가 있는 개인 이벤트 id 집합 반환
/// - [notifyNewInstructions]: 처음 등장한 미확인 지시에 대해 로컬 푸시 알림 발송
class GroupInstructionInboxService {
  GroupInstructionInboxService({
    GroupEventCommentRepository? commentRepository,
    GroupEventRepository? eventRepository,
    NotificationService? notificationService,
  })  : _commentRepositoryOverride = commentRepository,
        _eventRepositoryOverride = eventRepository,
        _notificationServiceOverride = notificationService;

  static const String _notifiedIdsKey = 'group_instruction_notified_ids';

  final GroupEventCommentRepository? _commentRepositoryOverride;
  final GroupEventRepository? _eventRepositoryOverride;
  final NotificationService? _notificationServiceOverride;

  // 지연 초기화 — Supabase 미초기화 환경(테스트 등)에서 생성자에서
  // 바로 repo 를 만들면 assert 오류가 나므로 실사용 시점에 생성한다.
  GroupEventCommentRepository? _commentRepositoryCache;
  GroupEventRepository? _eventRepositoryCache;
  NotificationService? _notificationServiceCache;

  GroupEventCommentRepository get _commentRepository =>
      _commentRepositoryCache ??=
          _commentRepositoryOverride ?? GroupEventCommentRepository.supabase();

  GroupEventRepository get _eventRepository =>
      _eventRepositoryCache ??=
          _eventRepositoryOverride ?? GroupEventRepository.supabase();

  NotificationService get _notificationService =>
      _notificationServiceCache ??=
          _notificationServiceOverride ?? NotificationService();

  /// 현재 사용자([userId])에게 미확인 지시가 있는 개인 이벤트 id 집합을 반환한다.
  ///
  /// - 에러 발생 시 빈 Set 반환 (defensive)
  /// - group_event.personal_event_id 가 null 인 경우 skip
  Future<Set<String>> unconfirmedPersonalEventIds({
    required String userId,
  }) async {
    if (userId.isEmpty) {
      return const <String>{};
    }

    try {
      final comments =
          await _commentRepository.unconfirmedForUser(userId);
      final result = <String>{};

      // 병렬로 그룹 이벤트를 조회해 personalEventId 를 수집한다.
      await Future.wait(
        comments.map((comment) async {
          try {
            final groupEvent = await _eventRepository
                .fetchGroupEvent(comment.groupEventId);
            final personalEventId = groupEvent.personalEventId;
            if (personalEventId != null && personalEventId.isNotEmpty) {
              result.add(personalEventId);
            }
          } catch (_) {
            // 개별 조회 실패는 skip — 다른 항목 처리 계속
          }
        }),
      );

      return result;
    } catch (error, stackTrace) {
      debugPrint(
        'GroupInstructionInboxService.unconfirmedPersonalEventIds 오류: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return const <String>{};
    }
  }

  /// 처음 도착한 미확인 지시에 대해 로컬 알림을 발송하고,
  /// 이미 알림을 보낸 코멘트 id 를 SharedPreferences 에 기록한다.
  ///
  /// - web / non-Android 환경에서는 no-op
  /// - 에러 발생 시 무시 (defensive)
  Future<void> notifyNewInstructions({required String userId}) async {
    if (kIsWeb) return;
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) return;
    if (userId.isEmpty) return;

    try {
      final comments =
          await _commentRepository.unconfirmedForUser(userId);
      if (comments.isEmpty) return;

      // 이미 알림을 보낸 id 로드
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_notifiedIdsKey);
      final notifiedIds = raw != null
          ? Set<String>.from(
              (jsonDecode(raw) as List<dynamic>).cast<String>(),
            )
          : <String>{};

      final newComments = comments
          .where((c) => !notifiedIds.contains(c.id))
          .toList(growable: false);

      if (newComments.isEmpty) return;

      final service = _notificationService;
      await service.initialize();

      for (final comment in newComments) {
        try {
          final notifId = _stableId('grp_instr:${comment.id}');
          // 즉시 알림 (scheduleEventReminder 는 미래 시간 필요 → show 사용)
          // NotificationService 에 즉시 표시 메서드가 없으므로
          // 1초 후로 예약하는 형태로 발송한다.
          final notifyAt = DateTime.now().add(const Duration(seconds: 1));
          await service.scheduleEventReminder(
            id: notifId,
            title: '팀 리더 지시',
            body: comment.content,
            notifyAt: notifyAt,
          );
          notifiedIds.add(comment.id);
        } catch (e, st) {
          debugPrint(
              'GroupInstructionInboxService 알림 발송 실패 (id=${comment.id}): $e');
          debugPrintStack(stackTrace: st);
        }
      }

      // 업데이트된 id 저장
      await prefs.setString(
        _notifiedIdsKey,
        jsonEncode(notifiedIds.toList(growable: false)),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'GroupInstructionInboxService.notifyNewInstructions 오류: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  int _stableId(String key) {
    var hash = 0x811c9dc5;
    for (final c in key.codeUnits) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
