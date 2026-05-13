import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/event_prefetch_service.dart';

void main() {
  const userId = 'user-wave1';
  const otherUserId = 'user-wave1-other';

  setUp(() {
    EventPrefetchService().invalidate();
  });

  group('EventPrefetchService.warmUp', () {
    test('warmUp caches fresh events for the user', () async {
      final cachedEvents = <EventModel>[
        EventModel(
          id: 'event-1',
          userId: userId,
          title: '회의',
          startAt: DateTime(2026, 5, 1, 9, 0),
        ),
      ];
      final repository = _FakeEventRepository(() async => cachedEvents);
      await EventPrefetchService().warmUp(userId, repository: repository);

      final actual = EventPrefetchService().getCached(userId);
      expect(actual, isNotNull);
      expect(actual!.length, 1);
      expect(actual.first.id, 'event-1');
      expect(EventPrefetchService().isFresh(userId), isTrue);
      expect(repository.listEventsCallCount, 1);
    });

    test('warmUp ignores duplicate concurrent requests for same user',
        () async {
      final gate = Completer<List<EventModel>>();
      final cachedEvents = <EventModel>[
        EventModel(
          id: 'event-2',
          userId: userId,
          title: '동시 요청',
          startAt: DateTime(2026, 5, 1, 11, 0),
        ),
      ];
      final repository = _FakeEventRepository(() async => gate.future);

      final futureA =
          EventPrefetchService().warmUp(userId, repository: repository);
      await Future<void>.delayed(Duration.zero);
      final futureB =
          EventPrefetchService().warmUp(userId, repository: repository);

      gate.complete(cachedEvents);
      await Future.wait([futureA, futureB]);

      expect(repository.listEventsCallCount, 1);
      expect(EventPrefetchService().getCached(userId), isNotNull);
    });

    test('warmUp failure does not replace an existing cache', () async {
      final existing = <EventModel>[
        EventModel(
          id: 'event-3',
          userId: userId,
          title: '기존 캐시',
          startAt: DateTime(2026, 5, 1, 10, 0),
        ),
      ];
      EventPrefetchService().store(userId, existing);

      final failingRepository = _FakeEventRepository(
        () => throw Exception('listEvents 실패'),
      );
      await EventPrefetchService()
          .warmUp(userId, repository: failingRepository);

      final cached = EventPrefetchService().getCached(userId);
      expect(cached, isNotNull);
      expect(cached!.first.id, 'event-3');
    });
  });

  group('EventPrefetchService.invalidate', () {
    test('invalidate removes only the given user cache when userId is given',
        () {
      EventPrefetchService().store(
        userId,
        [
          EventModel(
            id: 'event-4',
            userId: userId,
            title: '내 일정',
            startAt: DateTime(2026, 5, 1, 14, 0),
          ),
        ],
      );
      EventPrefetchService().store(
        otherUserId,
        [
          EventModel(
            id: 'event-5',
            userId: otherUserId,
            title: '다른 유저',
            startAt: DateTime(2026, 5, 1, 15, 0),
          ),
        ],
      );

      EventPrefetchService().invalidate(userId: userId);

      expect(EventPrefetchService().getCached(userId), isNull);
      expect(EventPrefetchService().getCached(otherUserId), isNotNull);
    });

    test(
      'getCached returns null when a custom max age is already expired',
      () {
        EventPrefetchService().store(
          userId,
          [
            EventModel(
              id: 'event-6',
              userId: userId,
              title: '짧은 유효시간',
              startAt: DateTime(2026, 5, 1, 16, 0),
            ),
          ],
        );

        final stale = EventPrefetchService().getCached(
          userId,
          maxAge: const Duration(milliseconds: -1),
        );
        expect(stale, isNull);
      },
    );
  });
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this._onListEvents);

  final Future<List<EventModel>> Function() _onListEvents;
  int listEventsCallCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    listEventsCallCount += 1;
    return _onListEvents();
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    return Future<EventModel>.value(event);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    return Future<EventModel>.value(event);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) {
    return Future<EventModel?>.value(null);
  }

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) {
    return Future<EventModel?>.value(null);
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) {
    return Future<List<EventModel>>.value(const <EventModel>[]);
  }

  @override
  Future<EventModel?> findEventByTitleAndStart({
    required String title,
    required DateTime startAt,
    String? userId,
    Duration tolerance = const Duration(minutes: 1),
    Set<String> excludedSources = const <String>{},
  }) {
    return Future<EventModel?>.value(null);
  }

  @override
  Future<EventModel?> attachExternalSyncMetadataIfCompatible({
    required EventModel existing,
    required EventModel incoming,
  }) {
    return Future<EventModel?>.value(null);
  }

  @override
  Future<EventModel> updateSuppliesChecked({
    required String eventId,
    required List<String> suppliesChecked,
    String? userId,
  }) {
    return Future<EventModel>.value(
      EventModel(
        id: eventId,
        userId: userId ?? '',
        title: 'temp',
        startAt: DateTime(2026, 5, 1),
      ),
    );
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    return Future<void>.value();
  }

  @override
  Future<EventModel> upsertEvent(EventModel event) {
    return Future<EventModel>.value(event);
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) {
    return Future<EventModel>.value(event);
  }
}
