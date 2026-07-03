import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/services/group_event_share_service.dart';

void main() {
  test('shares upcoming manual personal events and skips duplicates', () async {
    final personalRepository = _FakeEventRepository(
      events: <EventModel>[
        _event(
          id: 'past',
          title: '지난 일정',
          startAt: DateTime.utc(2026, 6, 28, 1),
          endAt: DateTime.utc(2026, 6, 28, 2),
        ),
        _event(
          id: 'future-1',
          title: '팀 회의',
          startAt: DateTime.utc(2026, 6, 30, 3),
          endAt: DateTime.utc(2026, 6, 30, 4),
        ),
        _event(
          id: 'future-2',
          title: '외부 동기화 일정',
          startAt: DateTime.utc(2026, 7, 1, 3),
          endAt: DateTime.utc(2026, 7, 1, 4),
          source: 'google',
        ),
        _event(
          id: 'future-3',
          title: '고객 미팅',
          startAt: DateTime.utc(2026, 7, 2, 3),
          endAt: DateTime.utc(2026, 7, 2, 4),
        ),
      ],
    );
    final groupRepository = _FakeGroupEventRepository(
      initialEvents: <GroupEventModel>[
        _groupEvent(
          id: 'existing',
          groupId: 'group-1',
          title: '팀 회의',
          startAt: DateTime.utc(2026, 6, 30, 3),
          endAt: DateTime.utc(2026, 6, 30, 4),
        ),
      ],
    );
    final service = GroupEventShareService(
      eventRepository: personalRepository,
      groupEventRepository: groupRepository,
      nowProvider: () => DateTime.utc(2026, 6, 30, 9),
    );

    final result = await service.shareUpcomingManualEvents(
      userId: 'user-1',
      groupId: 'group-1',
    );

    expect(result.sharedCount, 1);
    expect(result.duplicateCount, 1);
    expect(result.skippedCount, 2);
    expect(result.failedCount, 0);
    expect(groupRepository.createdTitles, <String>['고객 미팅']);
    expect(personalRepository.updatedGroupLinks, <String, String>{
      'future-3': 'created-1',
    });
  });
}

EventModel _event({
  required String id,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
  String source = 'manual',
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt,
    endAt: endAt,
    source: source,
  );
}

GroupEventModel _groupEvent({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: 'user-1',
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required this.events});

  final List<EventModel> events;
  final Map<String, String> updatedGroupLinks = <String, String>{};

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return events.where((event) => event.id == eventId).firstOrNull;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return events.where((event) => event.userId == userId).toList();
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final index = events.indexWhere((item) => item.id == event.id);
    if (index == -1) {
      throw StateError('event not found');
    }
    events[index] = event;
    if (event.groupEventId != null) {
      updatedGroupLinks[event.id] = event.groupEventId!;
    }
    return event;
  }
}

class _FakeGroupEventRepository extends GroupEventRepository {
  _FakeGroupEventRepository({List<GroupEventModel>? initialEvents})
      : events = List<GroupEventModel>.from(initialEvents ?? const []);

  final List<GroupEventModel> events;
  final List<String> createdTitles = <String>[];

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    createdTitles.add(event.title);
    final created = GroupEventModel(
      id: 'created-${createdTitles.length}',
      groupId: event.groupId,
      title: event.title,
      description: event.description,
      location: event.location,
      startAt: event.startAt,
      endAt: event.endAt,
      allDay: event.allDay,
      recurrenceType: event.recurrenceType,
      recurrenceUntil: event.recurrenceUntil,
      createdBy: event.createdBy,
      personalEventId: event.personalEventId,
      status: 'active',
    );
    events.add(created);
    return created;
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return events.where((event) => event.groupId == groupId).toList();
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }
}
