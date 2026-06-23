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
import 'package:planflow/features/groups/screens/group_event_create_screen.dart';

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
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

class FakeGroupDelegationRepository extends GroupDelegationRepository {
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
    return const <GroupRoleDelegationModel>[];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows validation errors before submission', (tester) async {
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
      repository: FakeGroupEventRepository(),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventCreateScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('group-event-create-submit-button')));
    await tester.pump();

    expect(find.text('제목을 입력해 주세요.'), findsOneWidget);
  });

  testWidgets('creates a group event with valid input', (tester) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventCreateScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('group-event-title-field')),
      '팀 회의',
    );
    await tester
        .tap(find.byKey(const ValueKey('group-event-create-submit-button')));
    await tester.pumpAndSettle();

    expect(eventRepo.lastCreatedTitle, '팀 회의');
  });
}
