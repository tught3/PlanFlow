import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/group_event_share_service.dart';

void main() {
  group('GroupEventShareService', () {
    test(
      'shares only upcoming manual personal events into linked group copies',
      () async {
        final now = DateTime.utc(2026, 6, 30, 0);
        final repository = _MemoryEventRepository(<EventModel>[
          _event(
            id: 'past-manual',
            title: '지난 개인 일정',
            startAt: now.subtract(const Duration(days: 1)),
          ),
          _event(
            id: 'future-manual',
            title: '앞으로 개인 일정',
            startAt: now.add(const Duration(days: 1)),
            location: '서울역',
            supplies: const <String>['노트북'],
            participants: const <String>['팀장님'],
            isCritical: true,
            useStrongAlarm: true,
          ),
          _event(
            id: 'external',
            title: '구글 일정',
            startAt: now.add(const Duration(days: 2)),
            source: 'google',
          ),
          _event(
            id: 'linked-copy',
            title: '이미 링크된 복제 일정',
            startAt: now.add(const Duration(days: 3)),
            parentEventId: 'personal-origin',
          ),
        ]);
        final service = GroupEventShareService(repository: repository);

        final result = await service.shareUpcomingPersonalEvents(
          userId: 'user-1',
          groupId: 'group-1',
          now: now,
        );

        expect(result.createdCount, 1);
        expect(result.skippedCount, 0);
        final copy = result.created.single;
        expect(copy.id, isNot(''));
        expect(copy.title, '앞으로 개인 일정');
        expect(copy.source, GroupEventShareService.groupSource);
        expect(copy.externalCalendarId, 'group-1');
        expect(copy.externalId, 'group:group-1:personal:future-manual');
        expect(copy.parentEventId, isNull);
        expect(copy.location, '서울역');
        expect(copy.supplies, <String>['노트북']);
        expect(copy.participants, <String>['팀장님']);
        expect(copy.isCritical, isTrue);
        expect(copy.useStrongAlarm, isTrue);
      },
    );

    test(
      'skips group duplicates by external link or matching schedule',
      () async {
        final now = DateTime.utc(2026, 6, 30, 0);
        final linked = _event(
          id: 'personal-linked',
          title: '이미 공유됨',
          startAt: now.add(const Duration(days: 1)),
        );
        final duplicateBySchedule = _event(
          id: 'personal-duplicate',
          title: '중복   일정',
          startAt: now.add(const Duration(days: 2)),
        );
        final repository = _MemoryEventRepository(<EventModel>[
          linked,
          duplicateBySchedule,
          _event(
            id: 'group-linked',
            title: linked.title,
            startAt: linked.startAt!,
            source: GroupEventShareService.groupSource,
            externalId: 'group:group-1:personal:${linked.id}',
            externalCalendarId: 'group-1',
          ),
          _event(
            id: 'group-duplicate',
            title: '중복 일정',
            startAt: duplicateBySchedule.startAt!,
            source: GroupEventShareService.groupSource,
            externalCalendarId: 'group-1',
          ),
        ]);
        final service = GroupEventShareService(repository: repository);

        final result = await service.shareUpcomingPersonalEvents(
          userId: 'user-1',
          groupId: 'group-1',
          now: now,
        );

        expect(result.created, isEmpty);
        expect(result.skipped.map((event) => event.id), <String>[
          'personal-linked',
          'personal-duplicate',
        ]);
      },
    );

    test('creates a separate linked copy for a different group', () async {
      final now = DateTime.utc(2026, 6, 30, 0);
      final personal = _event(
        id: 'personal-1',
        title: '공유할 개인 일정',
        startAt: now.add(const Duration(days: 1)),
      );
      final repository = _MemoryEventRepository(<EventModel>[
        personal,
        _event(
          id: 'group-copy-1',
          title: personal.title,
          startAt: personal.startAt!,
          source: GroupEventShareService.groupSource,
          externalId: 'group:group-1:personal:${personal.id}',
          externalCalendarId: 'group-1',
        ),
      ]);
      final service = GroupEventShareService(repository: repository);

      final result = await service.shareUpcomingPersonalEvents(
        userId: 'user-1',
        groupId: 'group-2',
        now: now,
      );

      expect(result.created, hasLength(1));
      expect(result.created.single.externalCalendarId, 'group-2');
      expect(
        result.created.single.externalId,
        'group:group-2:personal:personal-1',
      );
    });

    test('updates linked group copies when personal event is edited', () async {
      final personal = _event(
        id: 'personal-1',
        title: '변경된 개인 일정',
        startAt: DateTime.utc(2026, 7, 1, 9),
        location: null,
        memo: null,
        isCritical: true,
      );
      final groupCopy = _event(
        id: 'group-copy-1',
        title: '이전 그룹 일정',
        startAt: DateTime.utc(2026, 7, 1, 8),
        location: '이전 장소',
        memo: '이전 메모',
        source: GroupEventShareService.groupSource,
        externalId: 'group:group-1:personal:${personal.id}',
        externalCalendarId: 'group-1',
      );
      final repository = _MemoryEventRepository(<EventModel>[
        personal,
        groupCopy,
      ]);
      final service = GroupEventShareService(repository: repository);

      final updated = await service.updateLinkedGroupCopiesFromPersonal(
        personalEvent: personal,
        groupId: 'group-1',
      );

      expect(updated, hasLength(1));
      expect(updated.single.id, 'group-copy-1');
      expect(updated.single.title, '변경된 개인 일정');
      expect(updated.single.location, isNull);
      expect(updated.single.memo, isNull);
      expect(updated.single.source, GroupEventShareService.groupSource);
      expect(updated.single.externalCalendarId, 'group-1');
      expect(
        updated.single.externalId,
        'group:group-1:personal:${personal.id}',
      );
      expect(updated.single.parentEventId, isNull);
      expect(updated.single.isCritical, isTrue);
    });

    test(
      'updates linked personal event from a group copy without changing scope',
      () async {
        final personal = _event(
          id: 'personal-1',
          title: '이전 개인 일정',
          startAt: DateTime.utc(2026, 7, 1, 9),
          source: 'manual',
        );
        final groupCopy = _event(
          id: 'group-copy-1',
          title: '그룹에서 바뀐 일정',
          startAt: DateTime.utc(2026, 7, 2, 10),
          location: '부산역',
          source: GroupEventShareService.groupSource,
          externalId: 'group:group-1:personal:${personal.id}',
          externalCalendarId: 'group-1',
        );
        final repository = _MemoryEventRepository(<EventModel>[
          personal,
          groupCopy,
        ]);
        final service = GroupEventShareService(repository: repository);

        final updated = await service.updateLinkedPersonalEventFromGroupCopy(
          groupEvent: groupCopy,
        );

        expect(updated, isNotNull);
        expect(updated!.id, personal.id);
        expect(updated.title, '그룹에서 바뀐 일정');
        expect(updated.startAt, DateTime.utc(2026, 7, 2, 10));
        expect(updated.location, '부산역');
        expect(updated.source, 'manual');
        expect(updated.externalCalendarId, isNull);
        expect(updated.parentEventId, isNull);
      },
    );
  });
}

EventModel _event({
  required String id,
  required String title,
  required DateTime startAt,
  String userId = 'user-1',
  DateTime? endAt,
  String? location,
  String? memo,
  List<String> supplies = const <String>[],
  List<String> participants = const <String>[],
  bool isCritical = false,
  bool useStrongAlarm = false,
  String source = 'manual',
  String? externalId,
  String? externalCalendarId,
  String? parentEventId,
}) {
  return EventModel(
    id: id,
    userId: userId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    location: location,
    memo: memo,
    supplies: supplies,
    participants: participants,
    isCritical: isCritical,
    useStrongAlarm: useStrongAlarm,
    source: source,
    externalId: externalId,
    externalCalendarId: externalCalendarId,
    parentEventId: parentEventId,
  );
}

class _MemoryEventRepository extends EventRepository {
  _MemoryEventRepository(List<EventModel> events) : _events = [...events];

  final List<EventModel> _events;
  var _nextId = 1;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return _events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in _events) {
      if (event.id == eventId && (userId == null || event.userId == userId)) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    final saved = EventModel(
      id: event.id.trim().isEmpty ? 'created-${_nextId++}' : event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      useStrongAlarm: event.useStrongAlarm,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
      category: event.category,
      source: event.source,
      externalId: event.externalId,
      externalCalendarId: event.externalCalendarId,
      externalEtag: event.externalEtag,
      externalUpdatedAt: event.externalUpdatedAt,
      lastSyncedAt: event.lastSyncedAt,
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
    _events.add(saved);
    return saved;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final index = _events.indexWhere((existing) => existing.id == event.id);
    if (index < 0) {
      throw StateError('Event not found: ${event.id}');
    }
    _events[index] = event;
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    _events.removeWhere(
      (event) =>
          event.id == eventId && (userId == null || event.userId == userId),
    );
  }
}
