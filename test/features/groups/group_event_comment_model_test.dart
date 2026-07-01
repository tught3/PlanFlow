import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/models/group_event_comment_model.dart';

void main() {
  group('GroupEventCommentModel', () {
    test('fromJson maps snake_case columns and isConfirmed reflects confirmed_at',
        () {
      final model = GroupEventCommentModel.fromJson(<String, dynamic>{
        'id': 'comment-1',
        'group_event_id': 'gevent-1',
        'group_id': 'group-1',
        'author_user_id': 'leader-1',
        'target_user_id': 'sharer-1',
        'content': '내일 자료 준비해 주세요.',
        'confirmed_at': null,
        'created_at': '2026-07-01T00:00:00Z',
        'updated_at': '2026-07-01T00:00:00Z',
      });

      expect(model.id, 'comment-1');
      expect(model.groupEventId, 'gevent-1');
      expect(model.authorUserId, 'leader-1');
      expect(model.targetUserId, 'sharer-1');
      expect(model.content, '내일 자료 준비해 주세요.');
      expect(model.isConfirmed, isFalse);
    });

    test('toJson round-trips back to an equal model', () {
      final original = GroupEventCommentModel(
        id: 'comment-1',
        groupEventId: 'gevent-1',
        groupId: 'group-1',
        authorUserId: 'leader-1',
        targetUserId: 'sharer-1',
        content: '지시 내용',
        confirmedAt: DateTime.utc(2026, 7, 1, 3),
      );

      final restored =
          GroupEventCommentModel.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.groupEventId, original.groupEventId);
      expect(restored.targetUserId, original.targetUserId);
      expect(restored.content, original.content);
      expect(restored.isConfirmed, isTrue);
      expect(restored.confirmedAt, original.confirmedAt);
    });

    test('copyWith clearConfirmedAt resets confirmation', () {
      final confirmed = GroupEventCommentModel(
        id: 'c',
        groupEventId: 'g',
        groupId: 'grp',
        authorUserId: 'a',
        targetUserId: 't',
        content: 'x',
        confirmedAt: DateTime.utc(2026, 7, 1),
      );

      expect(confirmed.isConfirmed, isTrue);
      expect(
        confirmed.copyWith(clearConfirmedAt: true).isConfirmed,
        isFalse,
      );
    });
  });
}
