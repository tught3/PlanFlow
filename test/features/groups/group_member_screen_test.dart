import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_member_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_member_screen.dart';

class FakeGroupRepository extends GroupRepository {
  FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;

  /// 테스트에서 updateMember 호출 횟수 추적
  int updateMemberCallCount = 0;

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
    return List<GroupMemberModel>.from(
      membersByGroupId[groupId] ?? const <GroupMemberModel>[],
    );
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    updateMemberCallCount++;
    final groupMembers = membersByGroupId[member.groupId];
    if (groupMembers == null) {
      throw StateError('missing group members');
    }
    final index = groupMembers.indexWhere((item) => item.id == member.id);
    if (index == -1) {
      throw StateError('missing member');
    }
    groupMembers[index] = member;
    return Future<GroupMemberModel>.value(member);
  }
}

class FakeGroupEventRepository extends GroupEventRepository {
  FakeGroupEventRepository({this.eventsByGroupId = const {}});

  final Map<String, List<GroupEventModel>> eventsByGroupId;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return List<GroupEventModel>.from(
      eventsByGroupId[groupId] ?? const <GroupEventModel>[],
    );
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
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
  String status = 'active',
}) {
  return GroupMemberModel(
    id: id,
    groupId: groupId,
    userId: userId,
    role: role,
    status: status,
    createdAt: DateTime.utc(2026, 6, 11),
  );
}

GroupEventModel _event({
  required String id,
  required String groupId,
  required String createdBy,
  required DateTime startAt,
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: 'event-$id',
    startAt: startAt,
    endAt: startAt.add(const Duration(hours: 1)),
    createdBy: createdBy,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows remove button for leader members', (tester) async {
    final repository = FakeGroupRepository(
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
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
          ),
          _member(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupMemberScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
          eventRepository: FakeGroupEventRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('멤버 관리'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-member-remove-member-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('group-member-remove-leader-1')),
        findsNothing);
  });

  testWidgets('hides remove button for non-leader members', (tester) async {
    final repository = FakeGroupRepository(
      groups: <GroupModel>[
        _group(
          id: 'group-1',
          name: 'Member Group',
          createdBy: 'user-2',
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
          _member(
            id: 'member-2',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupMemberScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
          eventRepository: FakeGroupEventRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('멤버 관리'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-member-remove-member-1')),
        findsNothing);
    expect(find.byKey(const ValueKey('group-member-remove-member-2')),
        findsNothing);
  });

  testWidgets('shows empty state when there is no selected group', (tester) async {
    final repository = FakeGroupRepository(
      groups: const <GroupModel>[],
      membersByGroupId: const <String, List<GroupMemberModel>>{},
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupMemberScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
          eventRepository: FakeGroupEventRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('그룹을 선택해야 멤버 목록을 볼 수 있어요.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('group-member-list-button')),
        findsOneWidget);
  });

  testWidgets(
      'shows per-member share stats: shared count and no-share hint',
      (tester) async {
    final repository = FakeGroupRepository(
      groups: <GroupModel>[
        _group(
          id: 'group-1',
          name: 'Share Stats Group',
          createdBy: 'user-1',
          createdAt: DateTime.utc(2026, 6, 11),
        ),
      ],
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          _member(
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
          ),
          _member(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
          ),
        ],
      },
    );
    final eventRepository = FakeGroupEventRepository(
      eventsByGroupId: <String, List<GroupEventModel>>{
        'group-1': <GroupEventModel>[
          _event(
            id: 'event-1',
            groupId: 'group-1',
            createdBy: 'user-1',
            startAt: DateTime.utc(2026, 6, 20, 9),
          ),
          _event(
            id: 'event-2',
            groupId: 'group-1',
            createdBy: 'user-1',
            startAt: DateTime.utc(2026, 6, 25, 9),
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupMemberScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
          eventRepository: eventRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leaderStatsFinder = find.byKey(
      const ValueKey('group-member-share-stats-leader-1'),
    );
    final memberStatsFinder = find.byKey(
      const ValueKey('group-member-share-stats-member-1'),
    );
    expect(leaderStatsFinder, findsOneWidget);
    expect(memberStatsFinder, findsOneWidget);

    final leaderStatsText = tester.widget<Text>(leaderStatsFinder).data ?? '';
    expect(leaderStatsText, contains('전체 공유 2건'));

    final memberStatsText = tester.widget<Text>(memberStatsFinder).data ?? '';
    expect(memberStatsText, '아직 공유한 일정이 없어요');
  });

  testWidgets(
      'duplicate display name validation prevents updateMember call',
      (tester) async {
    final repository = FakeGroupRepository(
      groups: <GroupModel>[
        _group(
          id: 'group-1',
          name: 'Test',
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
          ).copyWith(displayName: '민수'),
          _member(
            id: 'member-2',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
          ).copyWith(displayName: '영희'),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupMemberScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
          eventRepository: FakeGroupEventRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 본인('민수') 이름 변경 버튼을 눌러 다이얼로그를 연다.
    await tester.tap(find.text('이름 변경').first);
    await tester.pumpAndSettle();
    expect(find.text('멤버 이름 변경'), findsOneWidget);

    // 이미 다른 멤버('영희')가 쓰고 있는 이름으로 바꾸려 시도한다.
    await tester.enterText(
      find.byKey(const ValueKey('group-member-display-name-dialog-field')),
      '영희',
    );
    // enterText가 예약한 캐럿 스크롤 콜백을 텍스트필드가 아직 화면에 붙어있는
    // 동안 먼저 소진해, 다이얼로그가 닫힌 뒤(디태치된 뒤)에 실행되며 발생하는
    // 테스트 프레임워크 예외(RenderEditable._snapToPhysicalPixel: attached)를 피한다.
    await tester.pump();

    // 저장을 누르면 다이얼로그가 pop 되고 곧바로 중복검사 결과로 안내
    // 다이얼로그가 다시 열린다 — 실제 저장(updateMember)이 호출되지 않았는지가
    // 핵심 동작 보장이다.
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('이미 있는 이름입니다. 다른 이름으로 변경해 주세요.'), findsOneWidget);
    expect(repository.updateMemberCallCount, 0);
  });
}
