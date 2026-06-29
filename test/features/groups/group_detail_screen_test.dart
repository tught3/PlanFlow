import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('처음 그룹 상세에 들어가면 기존 일정 공유 모달을 한 번만 보여준다', (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final repository = _FakeGroupRepository(
      groups: <GroupModel>[
        GroupModel(
          id: 'group-1',
          createdBy: 'leader-1',
          name: '우리 팀',
          createdAt: DateTime.utc(2026, 6, 29),
        ),
      ],
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          GroupMemberModel(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'member',
          ),
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDetailScreen(
          groupId: 'group-1',
          repository: repository,
          preferences: preferences,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('기존 일정을 공유할까요?'), findsOneWidget);

    await tester.tap(find.text('새로 만드는 일정부터'));
    await tester.pumpAndSettle();

    expect(
      preferences.getBool(
        'planflow:group_event_share_prompt:v1:user-1:group-1',
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: GroupDetailScreen(
          groupId: 'group-1',
          repository: repository,
          preferences: preferences,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('기존 일정을 공유할까요?'), findsNothing);
  });
}

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository({
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
