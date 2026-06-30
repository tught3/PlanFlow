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
import 'package:planflow/features/groups/screens/group_event_list_screen.dart';

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
    List<GroupEventModel>? initialEvents,
  }) : events = List<GroupEventModel>.from(initialEvents ?? const []);

  final List<GroupEventModel> events;

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
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
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return events.firstWhere((event) => event.id == eventId);
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
  String? displayName,
}) {
  return GroupMemberModel(
    id: id,
    groupId: groupId,
    userId: userId,
    role: role,
    displayName: displayName,
  );
}

GroupEventModel _event({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
  String createdBy = 'user-1',
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: createdBy,
    status: 'active',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows empty state and create button when there are no events',
      (tester) async {
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

    final groupRepository = FakeGroupRepository(
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
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventListScreen(
          provider: provider,
          groupRepository: groupRepository,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘은 아직 그룹 일정이 없어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-event-list-create-button')),
        findsOneWidget);
  });

  testWidgets('shows today and week event items', (tester) async {
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
      repository: FakeGroupEventRepository(
        initialEvents: <GroupEventModel>[
          _event(
            id: 'event-1',
            groupId: 'group-1',
            title: '오늘 회의',
            startAt: DateTime.utc(2026, 6, 11, 1),
            endAt: DateTime.utc(2026, 6, 11, 2),
          ),
          _event(
            id: 'event-2',
            groupId: 'group-1',
            title: '이번 주 일정',
            startAt: DateTime.utc(2026, 6, 13, 1),
            endAt: DateTime.utc(2026, 6, 13, 2),
          ),
        ],
      ),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    final groupRepository = FakeGroupRepository(
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
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventListScreen(
          provider: provider,
          groupRepository: groupRepository,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 회의'), findsOneWidget);
    expect(find.text('이번 주 일정'), findsWidgets);
  });

  testWidgets('공유된 일정 타일에 공유자(멤버 표시이름)를 보여준다', (tester) async {
    final members = <String, List<GroupMemberModel>>{
      'group-1': <GroupMemberModel>[
        _member(
          id: 'member-1',
          groupId: 'group-1',
          userId: 'user-1',
          role: 'leader',
        ),
        _member(
          id: 'member-2',
          groupId: 'group-1',
          userId: 'user-2',
          role: 'member',
          displayName: '엄대용',
        ),
      ],
    };
    final groups = <GroupModel>[
      _group(
        id: 'group-1',
        name: 'Leader Group',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 6, 11),
      ),
    ];
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(groups: groups, membersByGroupId: members),
    );
    final provider = GroupEventProvider(
      contextProvider: contextProvider,
      repository: FakeGroupEventRepository(
        initialEvents: <GroupEventModel>[
          _event(
            id: 'event-1',
            groupId: 'group-1',
            title: '팀 미팅',
            startAt: DateTime.utc(2026, 6, 11, 1),
            endAt: DateTime.utc(2026, 6, 11, 2),
            createdBy: 'user-2',
          ),
        ],
      ),
      delegationRepository: FakeGroupDelegationRepository(),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupEventListScreen(
          provider: provider,
          groupRepository:
              FakeGroupRepository(groups: groups, membersByGroupId: members),
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('팀 미팅'), findsOneWidget);
    expect(find.textContaining('공유 · 엄대용'), findsOneWidget);
  });
}
