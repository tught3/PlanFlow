import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/features/groups/models/group_backup_model.dart';
import 'package:planflow/features/groups/providers/deleted_groups_provider.dart';
import 'package:planflow/features/groups/repositories/group_backup_repository.dart';
import 'package:planflow/features/groups/screens/deleted_groups_screen.dart';
import 'package:planflow/features/groups/services/group_membership_refresh_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // DeletedGroupsScreen._confirmRestore 안에서 Supabase.instance.client.auth
  // 와 Supabase.instance.client.from('groups')을 직접 참조한다. 화면 단위
  // 테스트에서도 다른 테스트 파일과 동일한 패턴으로 Supabase 인스턴스를 1회
  // 초기화해 네트워크 호출이 일어나더라도 isolate에서 예외가 나지 않도록 한다.
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

  group('DeletedGroupsScreen 복원 시 bus 신호', () {
    // DeletedGroupsScreen은 기본 GroupBackupRepository.supabase()를 사용해
    // listMyBackups를 호출하지만, 테스트 주입을 허용하도록 추가한
    // [deletedGroupsProvider] 파라미터로 fake를 주입해 Supabase RPC를 우회한다.
    Future<List<GroupBackupModel>> restoreHelper(
      WidgetTester tester,
      DeletedGroupsProvider provider,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // _confirmRestore 내부에서 GoRouter.of(context)를 호출하므로
      // 테스트에서도 GoRouter 스택을 만들어 둔다. 실제 라우트 이동은
      // Supabase 클라이언트가 mock이라 그룹을 찾지 못해 실패하지만,
      // try/catch로 무시되며 우리가 보는 부분(membership bus 신호)은 이미
      // 그 앞에 발행된다.
      final router = GoRouter(
        initialLocation: AppRoutes.deletedGroups,
        routes: [
          GoRoute(
            path: AppRoutes.deletedGroups,
            builder: (_, __) =>
                DeletedGroupsScreen(deletedGroupsProvider: provider),
          ),
          GoRoute(
            path: '/groups/:groupId',
            builder: (_, state) => Scaffold(
              body: Text('restored:${state.pathParameters['groupId']}'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      // 백업 카드에 있는 '복원하기' 버튼을 탭한다.
      await tester.tap(find.text('복원하기'));
      await tester.pumpAndSettle();
      // 확인 다이얼로그에서 '복원'을 탭해 실제 _confirmRestore 흐름을 태운다.
      // 다이얼로그의 '복원' 버튼은 _DeletedGroupCard의 '복원하기' 버튼과 구분이
      // 필요하므로 정확한 위치(AlertDialog 안쪽)로 한정한다.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('복원'),
        ),
      );
      await tester.pumpAndSettle();
      // _confirmRestore는 성공 후 Supabase.instance.client.from('groups')
      // 호출이 실패해 catch 블록으로 빠지고, future 사용자는 [GroupMembershipRefreshBus]
      // 신호만 검증하면 된다. 그렇지 않으면 테스트가 네트워크 에러로 어그러진다.
      // pump 한 번 더 돌려 microtask 큐를 비운다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      return provider.backups;
    }

    testWidgets('복원 성공 시 GroupMembershipRefreshBus가 정확히 한 번 notify된다',
        (tester) async {
      final backup = GroupBackupModel(
        id: 'backup-1',
        groupId: 'group-old',
        backupType: 'archive',
        snapshot: const <String, dynamic>{
          'group': <String, dynamic>{'name': '복원 그룹'},
        },
        createdAt: DateTime.utc(2026, 6, 29),
      );
      final fakeRepository = _FakeGroupBackupRepository(
        backups: <GroupBackupModel>[backup],
        restoredId: 'backup-1',
        restoredResult: GroupBackupModel(
          id: 'backup-1',
          groupId: 'group-old',
          backupType: 'archive',
          snapshot: const <String, dynamic>{
            'group': <String, dynamic>{'name': '복원 그룹'},
          },
          restoredAt: DateTime.utc(2026, 6, 30),
          restoredBy: 'leader-1',
        ),
      );
      final provider = DeletedGroupsProvider(repository: fakeRepository);
      addTearDown(provider.dispose);

      var membershipRefreshCount = 0;
      void countMembershipRefresh() => membershipRefreshCount += 1;
      GroupMembershipRefreshBus.instance.addListener(countMembershipRefresh);
      addTearDown(
        () => GroupMembershipRefreshBus.instance
            .removeListener(countMembershipRefresh),
      );

      await restoreHelper(tester, provider);

      expect(fakeRepository.restoreGroupFromBackupCalls, <String>['backup-1']);
      expect(membershipRefreshCount, 1,
          reason: '성공한 복원에서는 bus notify가 정확히 1회만 발행되어야 한다');
      expect(find.text('"복원 그룹" 복원 완료'), findsOneWidget,
          reason: '복원 완료 스낵바가 보여야 한다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('복원 RPC 실패 시 bus를 notify하지 않는다', (tester) async {
      final backup = GroupBackupModel(
        id: 'backup-1',
        groupId: 'group-old',
        backupType: 'archive',
        snapshot: const <String, dynamic>{
          'group': <String, dynamic>{'name': '실패 그룹'},
        },
        createdAt: DateTime.utc(2026, 6, 29),
      );
      final fakeRepository = _FakeGroupBackupRepository(
        backups: <GroupBackupModel>[backup],
        restoredId: 'backup-1',
        restoreError: StateError('restore failed'),
      );
      final provider = DeletedGroupsProvider(repository: fakeRepository);
      addTearDown(provider.dispose);

      var membershipRefreshCount = 0;
      void countMembershipRefresh() => membershipRefreshCount += 1;
      GroupMembershipRefreshBus.instance.addListener(countMembershipRefresh);
      addTearDown(
        () => GroupMembershipRefreshBus.instance
            .removeListener(countMembershipRefresh),
      );

      await restoreHelper(tester, provider);

      expect(fakeRepository.restoreGroupFromBackupCalls, <String>['backup-1']);
      expect(membershipRefreshCount, 0,
          reason: '실패한 복원에서는 membership bus notify가 발행되면 안 된다');
      expect(find.text('복원 실패: Bad state: restore failed'), findsOneWidget,
          reason: '실패 메시지가 스낵바로 안내되어야 한다');
      expect(find.text('복원하기'), findsOneWidget,
          reason: '실패 후에도 화면이 그대로 남아 있어야 한다');
      expect(tester.takeException(), isNull);
    });
  });
}

/// DeletedGroupsProvider에 들어가는 fake. [GroupBackupRepository]의 모든 메서드를
/// 위젯 테스트에서 안전한 형태로 구현해 Supabase RPC가 호출되지 않도록 한다.
/// listMyBackups는 [backups] 그대로 돌려주고, restoreGroupFromBackup는
/// [restoreError]가 있으면 던지고, 없으면 [restoredResult]를 돌려준다.
class _FakeGroupBackupRepository extends GroupBackupRepository {
  _FakeGroupBackupRepository({
    required this.backups,
    this.restoredId,
    this.restoredResult,
    this.restoreError,
  });

  final List<GroupBackupModel> backups;
  final String? restoredId;
  final GroupBackupModel? restoredResult;
  final Object? restoreError;

  final List<String> restoreGroupFromBackupCalls = <String>[];
  final List<String> listMyBackupsCalls = <String>[];

  @override
  Future<GroupBackupModel> createArchiveBackup(
    String groupId,
    Map<String, dynamic> snapshot,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupBackupModel>> getBackupsForGroup(String groupId) async {
    return <GroupBackupModel>[];
  }

  @override
  Future<GroupBackupModel> markBackupRestored(String backupId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupBackupModel> archiveGroupWithBackup(String groupId) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupBackupModel>> listMyBackups({
    String? backupType,
    List<String>? backupTypes,
  }) async {
    final types = backupTypes ?? <String>[if (backupType != null) backupType];
    listMyBackupsCalls.add(types.join(','));
    return backups;
  }

  @override
  Future<GroupBackupModel> restoreGroupFromBackup(String backupId) async {
    restoreGroupFromBackupCalls.add(backupId);
    final error = restoreError;
    if (error != null) {
      throw error;
    }
    final result = restoredResult;
    if (result != null) {
      return result;
    }
    return GroupBackupModel(
      id: backupId,
      groupId: restoredId ?? 'group-1',
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