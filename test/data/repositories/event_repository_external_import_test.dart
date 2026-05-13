import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';

void main() {
  group('shouldKeepExistingEventForExternalImport', () {
    EventModel event({
      required String title,
      DateTime? createdAt,
      DateTime? updatedAt,
      DateTime? externalUpdatedAt,
      DateTime? lastSyncedAt,
      String? externalEtag,
    }) {
      return EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: title,
        startAt: DateTime.utc(2026, 5, 14, 0),
        endAt: DateTime.utc(2026, 5, 14, 1),
        source: 'naver_caldav',
        externalId: 'external-1',
        externalEtag: externalEtag,
        createdAt: createdAt,
        updatedAt: updatedAt,
        externalUpdatedAt: externalUpdatedAt,
        lastSyncedAt: lastSyncedAt,
      );
    }

    test('keeps local edit when it is newer than the last sync', () {
      final existing = event(
        title: '사용자가 고친 일정',
        updatedAt: DateTime.utc(2026, 5, 14, 2),
        lastSyncedAt: DateTime.utc(2026, 5, 14),
      );
      final incoming = event(
        title: '외부 캘린더 원본 일정',
        externalUpdatedAt: DateTime.utc(2026, 5, 15),
      );

      expect(
        shouldKeepExistingEventForExternalImport(
          existing: existing,
          incoming: incoming,
        ),
        isTrue,
      );
    });

    test('allows external overwrite when a stable external etag advances', () {
      final existing = event(
        title: '이전 로컬 일정',
        updatedAt: DateTime.utc(2026, 5, 14, 2),
        lastSyncedAt: DateTime.utc(2026, 5, 14),
        externalEtag: 'etag-1',
      );
      final incoming = event(
        title: '새 외부 일정',
        externalUpdatedAt: DateTime.utc(2026, 5, 14, 3),
        externalEtag: 'etag-2',
      );

      expect(
        shouldKeepExistingEventForExternalImport(
          existing: existing,
          incoming: incoming,
        ),
        isFalse,
      );
    });

    test('keeps local edit when import timestamp is the new sync time', () {
      final existing = event(
        title: '사용자가 고친 일정',
        updatedAt: DateTime.utc(2026, 5, 14, 2),
        lastSyncedAt: DateTime.utc(2026, 5, 14),
      );
      final incoming = event(
        title: '외부 캘린더 원본 일정',
        externalUpdatedAt: DateTime.utc(2026, 5, 14, 5),
      );

      expect(
        shouldKeepExistingEventForExternalImport(
          existing: existing,
          incoming: incoming,
        ),
        isTrue,
      );
    });

    test('does not block import when timestamps are missing', () {
      final existing = event(title: '기존 일정');
      final incoming = event(title: '외부 일정');

      expect(
        shouldKeepExistingEventForExternalImport(
          existing: existing,
          incoming: incoming,
        ),
        isFalse,
      );
    });
  });
}
