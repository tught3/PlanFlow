import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/models/group_role_delegation_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_event_provider.dart';
import 'package:planflow/features/groups/repositories/group_delegation_repository.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';

class FakeGroupRepository extends GroupRepository {
  FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;

  @override
  Future<List<GroupModel>> listGroups() async => groups;

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    return membersByGroupId[groupId] ?? const <GroupMemberModel>[];
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }
}

class FakeGroupEventRepository extends GroupEventRepository {
  FakeGroupEventRepository({List<GroupEventModel>? initialEvents})
      : events = List<GroupEventModel>.from(initialEvents ?? const []);

  final List<GroupEventModel> events;
  String? lastCreatedTitle;
  String? lastUpdatedId;
  String? lastCancelledId;
  String? lastArchivedId;

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) async {
    lastArchivedId = eventId;
    final event = events.firstWhere((item) => item.id == eventId);
    final archived = GroupEventModel(
      id: event.id,
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
      updatedBy: event.updatedBy,
      cancelledAt: event.cancelledAt,
      cancelledBy: event.cancelledBy,
      status: 'archived',
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
    events.removeWhere((item) => item.id == eventId);
    events.add(archived);
    return archived;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    lastCancelledId = eventId;
    final event = events.firstWhere((item) => item.id == eventId);
    final cancelled = GroupEventModel(
      id: event.id,
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
      updatedBy: event.updatedBy,
      cancelledAt: DateTime.utc(2026, 6, 11, 9),
      cancelledBy: 'user-1',
      status: 'cancelled',
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
    events.removeWhere((item) => item.id == eventId);
    events.add(cancelled);
    return cancelled;
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    lastCreatedTitle = event.title;
    final created = GroupEventModel(
      id: 'event-${events.length + 1}',
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
      updatedBy: event.updatedBy,
      cancelledAt: event.cancelledAt,
      cancelledBy: event.cancelledBy,
      status: 'active',
      createdAt: DateTime.utc(2026, 6, 11, 9),
      updatedAt: DateTime.utc(2026, 6, 11, 9),
    );
    events.add(created);
    return created;
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return events
        .where(
          (event) =>
              event.groupId == groupId &&
              event.status == 'active' &&
              !event.startAt.isAfter(to) &&
              !event.endAt.isBefore(from),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    lastUpdatedId = event.id;
    final index = events.indexWhere((item) => item.id == event.id);
    if (index == -1) {
      throw StateError('event not found');
    }
    events[index] = event;
    return event;
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return events.firstWhere((event) => event.id == eventId);
  }
}

class FakeGroupDelegationRepository extends GroupDelegationRepository {
  FakeGroupDelegationRepository({
    List<GroupRoleDelegationModel>? delegations,
  }) : delegations = List<GroupRoleDelegationModel>.from(
          delegations ?? const <GroupRoleDelegationModel>[],
        );

  final List<GroupRoleDelegationModel> delegations;

  @override
  Future<GroupRoleDelegationModel> cancelDelegation(String delegationId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupRoleDelegationModel> createDelegation({
    required String groupId,
    required String delegateUserId,
    required List<String> permissions,
    required DateTime startsAt,
    required DateTime endsAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupRoleDelegationModel>> getDelegationsForGroup(
    String groupId,
  ) async {
    return delegations.where((item) => item.groupId == groupId).toList();
  }

  @override
  Future<List<GroupRoleDelegationModel>> getDelegationsForMe() async {
    return List<GroupRoleDelegationModel>.from(delegations);
  }
}

GroupModel _group({
  required String id,
  required String name,
  required String createdBy,
  required DateTime createdAt,
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    createdAt: createdAt,
  );
}

GroupMemberModel _member({
  required String id,
  required String groupId,
  required String userId,
  required String role,
}) {
  return GroupMemberModel(
    id: id,
    groupId: groupId,
    userId: userId,
    role: role,
  );
}

GroupEventModel _event({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
  String status = 'active',
  bool allDay = false,
  String recurrenceType = 'none',
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    allDay: allDay,
    recurrenceType: recurrenceType,
    createdBy: 'user-1',
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads selected group events and grants leader permissions', () async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final eventRepo = FakeGroupEventRepository(
      initialEvents: <GroupEventModel>[
        _event(
          id: 'event-1',
          groupId: 'group-1',
          title: '주간 회의',
          startAt: DateTime.utc(2026, 6, 11, 1),
          endAt: DateTime.utc(2026, 6, 11, 2),
        ),
      ],
    );
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: eventRepo,
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.name, 'Leader Group');
    expect(provider.events, hasLength(1));
    expect(provider.canCreateEvent, isTrue);
    expect(provider.canManageEvents, isTrue);
  });

  test('member delegation grants create and cancel permissions', () async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Member Group',
            createdBy: 'leader-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: FakeGroupEventRepository(),
      delegationRepository: FakeGroupDelegationRepository(
        delegations: <GroupRoleDelegationModel>[
          GroupRoleDelegationModel(
            id: 'delegation-1',
            groupId: 'group-1',
            delegatorUserId: 'leader-1',
            delegateUserId: 'user-1',
            permissions: <String>[
              'create_group_event',
              'cancel_group_event',
            ],
            startsAt: DateTime.utc(2026, 6, 11, 0),
            endsAt: DateTime.utc(2026, 6, 12, 0),
            status: 'active',
          ),
        ],
      ),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.name, 'Member Group');
    expect(provider.selectedGroupRole, 'member');
    expect(provider.canCreateEvent, isTrue);
    expect(provider.canCancelEvent, isTrue);
    expect(provider.canManageEvents, isTrue);
  });

  test('active group members can create group events without delegation',
      () async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Member Group',
            createdBy: 'leader-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: FakeGroupEventRepository(),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');

    expect(provider.selectedGroupRole, 'member');
    expect(provider.canCreateEvent, isTrue);
    expect(provider.canManageEvents, isFalse);
  });

  test('createGroupEvent stores the event and refreshes the list', () async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final eventRepo = FakeGroupEventRepository();
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: eventRepo,
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');
    await provider.createGroupEvent(
      title: '팀 미팅',
      description: '주간 공유',
      location: '회의실 A',
      startAt: DateTime.utc(2026, 6, 12, 1),
      endAt: DateTime.utc(2026, 6, 12, 2),
      allDay: false,
      recurrenceType: 'none',
    );

    expect(eventRepo.lastCreatedTitle, '팀 미팅');
    expect(provider.events, hasLength(1));
    expect(provider.message, '그룹 일정을 만들었어요.');
  });
}
