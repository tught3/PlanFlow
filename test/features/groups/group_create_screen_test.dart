import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_create_screen.dart';

class FakeGroupRepository extends GroupRepository {
  FakeGroupRepository({
    this.throwOnCreate = false,
  });

  final bool throwOnCreate;
  final List<GroupModel> groups = <GroupModel>[];
  final Map<String, List<GroupMemberModel>> membersByGroupId =
      <String, List<GroupMemberModel>>{};
  int _groupSequence = 0;

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
  Future<GroupModel> createGroup(GroupModel group) async {
    if (throwOnCreate) {
      throw StateError('create failed');
    }

    final created = GroupModel(
      id: 'group-${++_groupSequence}',
      createdBy: group.createdBy,
      name: group.name,
      parentGroupId: group.parentGroupId,
      description: group.description,
      status: group.status,
      archivedAt: group.archivedAt,
      createdAt: group.createdAt,
      updatedAt: group.updatedAt,
    );
    groups.add(created);
    membersByGroupId[created.id] = <GroupMemberModel>[
      GroupMemberModel(
        id: 'member-${created.id}',
        groupId: created.id,
        userId: group.createdBy,
        role: 'leader',
      ),
    ];
    return created;
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows validation errors before submission', (tester) async {
    final repo = FakeGroupRepository();
    final provider = GroupContextProvider(repository: repo);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupCreateScreen(
          repository: repo,
          provider: provider,
          currentUserIdOverride: 'user-1',
          onCreated: (_) async {},
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('group-create-submit-button')));
    await tester.pump();

    expect(find.text('그룹 이름을 입력해 주세요.'), findsOneWidget);
  });

  testWidgets('creates a group and updates the selected context',
      (tester) async {
    final repo = FakeGroupRepository();
    final provider = GroupContextProvider(repository: repo);
    String? createdId;

    await tester.pumpWidget(
      MaterialApp(
        home: GroupCreateScreen(
          repository: repo,
          provider: provider,
          currentUserIdOverride: 'user-1',
          onCreated: (groupId) async {
            createdId = groupId;
          },
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('group-create-name-field')),
      '제품팀',
    );
    await tester.enterText(
      find.byKey(const ValueKey('group-create-description-field')),
      '핵심 기능 팀',
    );
    await tester.tap(find.byKey(const ValueKey('group-create-submit-button')));
    await tester.pumpAndSettle();

    expect(createdId, isNotNull);
    expect(repo.groups, hasLength(1));
    expect(provider.selectedGroup?.id, createdId);
    expect(provider.selectedGroup?.name, '제품팀');
    expect(find.text('생성 완료'), findsOneWidget);
  });

  testWidgets('shows an error banner when creation fails', (tester) async {
    final repo = FakeGroupRepository(throwOnCreate: true);
    final provider = GroupContextProvider(repository: repo);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupCreateScreen(
          repository: repo,
          provider: provider,
          currentUserIdOverride: 'user-1',
          onCreated: (_) async {},
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('group-create-name-field')),
      '제품팀',
    );
    await tester.tap(find.byKey(const ValueKey('group-create-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('그룹을 만들지 못했어요'), findsOneWidget);
    expect(find.textContaining('create failed'), findsOneWidget);
  });
}
