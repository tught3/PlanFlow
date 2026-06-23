import 'package:flutter/material.dart';
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
import 'package:planflow/features/groups/screens/group_event_detail_screen.dart';

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
  FakeGroupEventRepository({
    required GroupEventModel event,
  }) : _event = event;

  GroupEventModel _event;
  String? lastCancelledId;
  String? lastArchivedId;

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) async {
    lastArchivedId = eventId;
    _event = GroupEventModel(
      id: _event.id,
      groupId: _event.groupId,
      title: _event.title,
      description: _event.description,
      location: _event.location,
      startAt: _event.startAt,
      endAt: _event.endAt,
      allDay: _event.allDay,
      recurrenceType: _event.recurrenceType,
      recurrenceUntil: _event.recurrenceUntil,
      createdBy: _event.createdBy,
      updatedBy: _event.updatedBy,
      cancelledAt: _event.cancelledAt,
      cancelledBy: _event.cancelledBy,
      status: 'archived',
      createdAt: _event.createdAt,
      updatedAt: _event.updatedAt,
    );
    return _event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    lastCancelledId = eventId;
    _event = GroupEventModel(
      id: _event.id,
      groupId: _event.groupId,
      title: _event.title,
      description: _event.description,
      location: _event.location,
      startAt: _event.startAt,
      endAt: _event.endAt,
      allDay: _event.allDay,
      recurrenceType: _event.recurrenceType,
      recurrenceUntil: _event.recurrenceUntil,
      createdBy: _event.createdBy,
      updatedBy: _event.updatedBy,
      cancelledAt: DateTime.utc(2026, 6, 11, 9),
      cancelledBy: 'user-1',
      status: 'cancelled',
      createdAt: _event.createdAt,
      updatedAt: _event.updatedAt,
    );
    return _event;
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return _event;
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
      String groupId) {
    throw UnimplementedError();
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
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: 'user-1',
    status: 'active',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows cancel and archive buttons for leaders', (tester) async {
    final event = _event(
      id: 'event-1',
      groupId: 'group-1',
      title: '주간 회의',
      startAt: DateTime.utc(2026, 6, 11, 1),
      endAt: DateTime.utc(2026, 6, 11, 2),
    );
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
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: FakeGroupEventRepository(event: event),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventDetailScreen(
          eventId: event.id,
          event: event,
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-event-detail-cancel-button')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('group-event-detail-archive-button')),
        findsOneWidget);
    expect(find.text('주간 회의'), findsOneWidget);
  });

  testWidgets('hides management buttons for members without delegation',
      (tester) async {
    final event = _event(
      id: 'event-1',
      groupId: 'group-1',
      title: '주간 회의',
      startAt: DateTime.utc(2026, 6, 11, 1),
      endAt: DateTime.utc(2026, 6, 11, 2),
    );
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
      repository: FakeGroupEventRepository(event: event),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventDetailScreen(
          eventId: event.id,
          event: event,
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-event-detail-cancel-button')),
        findsNothing);
    expect(find.byKey(const ValueKey('group-event-detail-archive-button')),
        findsNothing);
    expect(find.text('주간 회의'), findsOneWidget);
  });
}
