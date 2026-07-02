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

  testWidgets('기존 일정 공유 모달의 버튼 배치: 나중에/새로 만드는 일정부터는 테두리 버튼, '
      '오늘 이후 일정 공유는 강조 버튼', (tester) async {
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
    // '나중에'/'새로 만드는 일정부터'는 테두리(OutlinedButton), '오늘 이후 일정
    // 공유'는 강조(FilledButton)로 구분되어야 한다(회귀 방지: 3개가 모두
    // TextButton으로 뒤섞이던 이전 레이아웃 재발 방지).
    expect(
      find.ancestor(
        of: find.text('나중에'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('새로 만드는 일정부터'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('오늘 이후 일정 공유'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('나중에'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      "'나중에'를 고른 뒤에도 그룹 상세의 '기존 일정 공유하기' 버튼으로 다시 실행할 수 있다",
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    // 이미 '나중에'를 골라 프롬프트가 다시 뜨지 않는 상태를 재현.
    await preferences.setBool(
      'planflow:group_event_share_prompt:v1:user-1:group-1',
      true,
    );
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

    // '기존 일정 공유하기' 버튼은 ListView 하단 쪽이라 기본 테스트 뷰포트에서는
    // 스크롤 없이 보이지 않는다. 뷰포트를 넉넉히 키워 스크롤 없이 확인한다.
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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

    // 자동 프롬프트는 이미 껐으니 뜨지 않는다.
    expect(find.text('기존 일정을 공유할까요?'), findsNothing);

    // 대신 그룹 상세의 수동 진입점이 항상 남아있어야 한다.
    final shareButtonFinder = find.byKey(
      const ValueKey('group-detail-share-existing-events-button'),
    );
    expect(shareButtonFinder, findsOneWidget);

    await tester.tap(shareButtonFinder);
    await tester.pumpAndSettle();

    // 탭하면 동일한 확인 다이얼로그가 다시 뜬다(자동 프롬프트와 무관하게 재실행 가능).
    expect(find.text('기존 일정을 공유할까요?'), findsOneWidget);

    await tester.tap(find.text('취소'));
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
