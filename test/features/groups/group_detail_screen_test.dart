import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/features/groups/models/group_backup_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_backup_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_detail_screen.dart';
import 'package:planflow/features/groups/services/group_cleanup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // GroupDetailScreen._archiveGroup/_restoreGroup이 GroupCleanupService에
  // userId를 넘길 때 Supabase.instance.client.auth.currentUser?.id를 직접
  // 참조한다. 이 흐름을 태우는 테스트를 위해 home_screen_test.dart와 동일한
  // 패턴으로 실제 네트워크 호출 없이 Supabase 인스턴스를 1회 초기화해둔다.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('push 이력 없이 그룹 상세로 바로 들어와 팀을 나가도 GoError 없이 그룹 목록으로 이동한다',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    // 이 테스트는 팀 나가기 흐름만 검증하므로, 무관한 '기존 일정 공유' 자동
    // 프롬프트는 미리 꺼둔다(이미 골랐던 상태로 시뮬레이션).
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

    final router = GoRouter(
      initialLocation: '/groups/group-1',
      routes: [
        GoRoute(
          path: '/groups/group-1',
          builder: (_, __) => GroupDetailScreen(
            groupId: 'group-1',
            repository: repository,
            preferences: preferences,
            currentUserIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.groups,
          builder: (_, __) => const Scaffold(body: Text('그룹 목록')),
        ),
      ],
    );

    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('팀 나가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('그룹 목록'), findsOneWidget);
  });

  testWidgets('팀 나가기와 그룹 삭제는 모두 빨간 계열의 채움 버튼으로 구분된다', (tester) async {
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
            userId: 'leader-1',
            role: 'leader',
          ),
        ],
      },
    );

    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDetailScreen(
          groupId: 'group-1',
          repository: repository,
          preferences: preferences,
          currentUserIdOverride: 'leader-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leaveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '팀 나가기'),
    );
    final deleteButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '그룹 삭제'),
    );

    expect(
      leaveButton.style?.backgroundColor?.resolve(<WidgetState>{}),
      const Color(0xFFFFE4DD),
    );
    expect(
      leaveButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      const Color(0xFFB42318),
    );
    expect(
      deleteButton.style?.backgroundColor?.resolve(<WidgetState>{}),
      const Color(0xFFB42318),
    );
    expect(
      deleteButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      Colors.white,
    );
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

  testWidgets(
      '기존 일정 공유 모달의 버튼 배치: 나중에/새로 만드는 일정부터는 테두리 버튼, '
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

  testWidgets("'나중에'를 고른 뒤에도 그룹 상세의 '기존 일정 공유하기' 버튼으로 다시 실행할 수 있다",
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

  group('GroupCleanupService 배선', () {
    tearDown(() {
      GroupCleanupService.resetInstance();
    });

    testWidgets('그룹 보관 성공 시 GroupCleanupService.onGroupArchived가 호출된다',
        (tester) async {
      final recorder = _RecordingGroupCleanupService();
      GroupCleanupService.setInstance(recorder);

      final preferences = await SharedPreferences.getInstance();
      // 이 테스트는 보관 흐름만 검증하므로 무관한 '기존 일정 공유' 자동
      // 프롬프트는 미리 꺼둔다.
      await preferences.setBool(
        'planflow:group_event_share_prompt:v1:leader-1:group-1',
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
              userId: 'leader-1',
              role: 'leader',
            ),
          ],
        },
      );
      final backupRepository = _FakeGroupBackupRepository();

      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // _archiveGroup 성공 후 _handleBackNavigation()이 context.canPop()
      // (go_router extension)을 호출하므로, plain MaterialApp이 아니라
      // GoRouter가 필요하다(없으면 GoRouter.of(context) 예외).
      final router = GoRouter(
        initialLocation: '/groups/group-1',
        routes: [
          GoRoute(
            path: '/groups/group-1',
            builder: (_, __) => GroupDetailScreen(
              groupId: 'group-1',
              repository: repository,
              backupRepository: backupRepository,
              preferences: preferences,
              currentUserIdOverride: 'leader-1',
            ),
          ),
          GoRoute(
            path: AppRoutes.groups,
            builder: (_, __) => const Scaffold(body: Text('그룹 목록')),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(recorder.archivedCalls, isEmpty);

      await tester.tap(find.text('그룹 보관하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보관하기'));
      await tester.pumpAndSettle();

      expect(backupRepository.archiveGroupWithBackupCalls, <String>['group-1']);
      expect(recorder.archivedCalls, hasLength(1));
      expect(recorder.archivedCalls.single, 'group-1');
    });

    testWidgets('그룹 복원 성공 시 GroupCleanupService.onGroupRestored가 호출된다',
        (tester) async {
      final recorder = _RecordingGroupCleanupService();
      GroupCleanupService.setInstance(recorder);

      final preferences = await SharedPreferences.getInstance();
      final repository = _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            status: 'archived',
            createdAt: DateTime.utc(2026, 6, 29),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'leader-1',
              role: 'leader',
            ),
          ],
        },
      );
      final backupRepository = _FakeGroupBackupRepository(
        backupsByGroupId: <String, List<GroupBackupModel>>{
          'group-1': <GroupBackupModel>[
            GroupBackupModel(
              id: 'backup-1',
              groupId: 'group-1',
              backupType: 'archive',
              snapshot: const <String, dynamic>{},
            ),
          ],
        },
        restoredGroupId: 'group-1',
      );

      // _restoreGroup은 성공 후 (go_router가 아닌) 순수
      // Navigator.pop(context)을 직접 호출한다. GroupDetailScreen을
      // MaterialApp의 home으로 바로 두면(스택에 route가 1개뿐) pop이 "바닥
      // route를 제거하려 한다"는 예외를 낼 수 있으므로, 실제 사용처럼 다른
      // 화면 위에 push해 pop이 안전하게 동작하도록 스택을 만든다.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => GroupDetailScreen(
                        groupId: 'group-1',
                        repository: repository,
                        backupRepository: backupRepository,
                        preferences: preferences,
                        currentUserIdOverride: 'leader-1',
                      ),
                    ),
                  ),
                  child: const Text('그룹 상세로 이동'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('그룹 상세로 이동'));
      await tester.pumpAndSettle();

      expect(find.text('보관된 그룹입니다'), findsOneWidget);
      expect(recorder.restoredCalls, isEmpty);

      await tester.tap(find.text('그룹 복원하기'));
      await tester.pumpAndSettle();

      expect(backupRepository.restoreGroupFromBackupCalls, <String>['backup-1']);
      expect(recorder.restoredCalls, hasLength(1));
      expect(recorder.restoredCalls.single, 'group-1');
    });
  });
}

/// GroupCleanupService.onGroupArchived/onGroupRestored 호출 여부·순서를
/// 기록하는 테스트 전용 fake. 나머지 내부 로직(알림/알람/위젯 정리 등)은
/// 실제 Supabase/플랫폼 채널 호출을 필요로 해 이 위젯 테스트 범위 밖이므로
/// 오버라이드해 완전히 우회한다.
class _RecordingGroupCleanupService extends GroupCleanupService {
  final List<String> archivedCalls = <String>[];
  final List<String> restoredCalls = <String>[];

  @override
  Future<void> onGroupArchived(String groupId, {String? userId}) async {
    archivedCalls.add(groupId);
  }

  @override
  Future<void> onGroupRestored(String groupId, {String? userId}) async {
    restoredCalls.add(groupId);
  }
}

class _FakeGroupBackupRepository extends GroupBackupRepository {
  _FakeGroupBackupRepository({
    Map<String, List<GroupBackupModel>>? backupsByGroupId,
    this.restoredGroupId,
  }) : backupsByGroupId = backupsByGroupId ?? <String, List<GroupBackupModel>>{};

  final Map<String, List<GroupBackupModel>> backupsByGroupId;
  final String? restoredGroupId;

  final List<String> archiveGroupWithBackupCalls = <String>[];
  final List<String> restoreGroupFromBackupCalls = <String>[];

  @override
  Future<GroupBackupModel> createArchiveBackup(
    String groupId,
    Map<String, dynamic> snapshot,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupBackupModel>> getBackupsForGroup(String groupId) async {
    return backupsByGroupId[groupId] ?? const <GroupBackupModel>[];
  }

  @override
  Future<GroupBackupModel> markBackupRestored(String backupId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupBackupModel> archiveGroupWithBackup(String groupId) async {
    archiveGroupWithBackupCalls.add(groupId);
    return GroupBackupModel(
      id: 'backup-generated',
      groupId: groupId,
      backupType: 'archive',
      snapshot: const <String, dynamic>{},
    );
  }

  @override
  Future<List<GroupBackupModel>> listMyBackups({
    String? backupType,
    List<String>? backupTypes,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GroupBackupModel> restoreGroupFromBackup(String backupId) async {
    restoreGroupFromBackupCalls.add(backupId);
    return GroupBackupModel(
      id: backupId,
      groupId: restoredGroupId ?? 'group-1',
      backupType: 'archive',
      snapshot: const <String, dynamic>{},
      restoredAt: DateTime.utc(2026, 6, 30),
      restoredBy: 'leader-1',
    );
  }

  @override
  Future<void> permanentlyDeleteBackup(String backupId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupBackupModel> deleteGroupWithBackup(String groupId) {
    throw UnimplementedError();
  }
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

  @override
  Future<GroupMemberModel> leaveGroup(String groupId) async {
    return GroupMemberModel(
      id: 'member-left',
      groupId: groupId,
      userId: 'user-1',
      role: 'member',
      status: 'removed',
    );
  }
}
