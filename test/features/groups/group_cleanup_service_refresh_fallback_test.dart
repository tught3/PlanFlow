// GroupCleanupService의 `_refreshGroupContextProvider` 폴백 동작 회귀 테스트.
//
// 변경된 동작:
//   * onGroupArchived / onGroupRestored에 refreshGroupContext 옵션 추가
//     (기본 true). 호출자가 명시적으로 false로 두면 provider reload도
//     bus notify도 일어나지 않는다.
//   * provider가 주입되지 않은 경우, `_refreshGroupContextProvider`가 더는
//     debugPrint만 찍고 스킵하지 않고 `GroupMembershipRefreshBus`로 폴백
//     notify를 쏜다 (HomeScreen이 이 신호를 받아 group row를 다시 그린다).
//   * provider가 주입된 경우, 그 provider의 `load()`만 호출하고 bus로
//     "추가" notify를 하지 않는다(이중 갱신 방지).
//
// 이 파일은 service 내부의 Supabase 호출(알림·알람·위젯·캐시 정리)은
// provider를 주입하지 않거나 no-op 서비스 자리에 null을 넣어 우회해,
// 우리가 보고 싶은 refresh-context 경로만 격리해 검증한다.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/services/group_cleanup_service.dart';
import 'package:planflow/features/groups/services/group_membership_refresh_bus.dart';

void main() {
  // onGroupArchived 내부의 `_cancelGroupEventNotifications`가
  // Supabase.instance.client.from('group_events')를 호출해 mock URL이라
  // PostgrestException을 던진다. 모든 단계는 자체 try/catch로 감싸져 있어
  // 메서드 자체는 정상 완료한다. 그래도 Supabase 인스턴스가 비어 있으면
  // 생성자에서 바로 예외가 나므로 다른 테스트 파일과 동일하게 1회 초기화.
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
    // 이전 테스트에서 listener가 남아 있으면 안 되므로 매 케이스 시작마다
    // 명시적으로 정리한다.
    GroupCleanupService.resetInstance();
  });

  group('refreshGroupContext 폴백', () {
    test(
        'provider 미주입 + refreshGroupContext 기본값(true) → onGroupArchived가 bus를 정확히 한 번 notify',
        () async {
      var notifications = 0;
      void listener() => notifications += 1;
      GroupMembershipRefreshBus.instance.addListener(listener);
      addTearDown(
        () => GroupMembershipRefreshBus.instance.removeListener(listener),
      );

      final service = GroupCleanupService();
      await service.onGroupArchived('group-1', userId: 'user-1');

      expect(notifications, 1,
          reason: 'provider 없으면 _refreshGroupContextProvider가 bus로 폴백 notify를 한 번만 해야 한다');
    });

    test(
        'provider 미주입 + refreshGroupContext 기본값(true) → onGroupRestored도 bus를 정확히 한 번 notify',
        () async {
      var notifications = 0;
      void listener() => notifications += 1;
      GroupMembershipRefreshBus.instance.addListener(listener);
      addTearDown(
        () => GroupMembershipRefreshBus.instance.removeListener(listener),
      );

      final service = GroupCleanupService();
      await service.onGroupRestored('group-1', userId: 'user-1');

      expect(notifications, 1,
          reason: 'provider 없으면 _refreshGroupContextProvider가 bus로 폴백 notify를 한 번만 해야 한다');
    });

    test(
        'provider 주입 시 → bus를 추가로 notify하지 않고 provider.load만 한 번 호출한다 (중복 refresh 방지)',
        () async {
      var notifications = 0;
      void listener() => notifications += 1;
      GroupMembershipRefreshBus.instance.addListener(listener);
      addTearDown(
        () => GroupMembershipRefreshBus.instance.removeListener(listener),
      );

      final fakeRepo = _LoadCountingGroupRepository();
      final provider = GroupContextProvider(repository: fakeRepo);
      addTearDown(provider.dispose);

      final service = GroupCleanupService(contextProvider: provider);
      await service.onGroupArchived('group-1', userId: 'user-1');

      expect(notifications, 0,
          reason: 'provider가 있으면 bus 폴백은 발사되지 않아야 한다(이중 refresh 방지)');
      expect(fakeRepo.listGroupsCalls, 1,
          reason: 'provider.load()는 정확히 한 번만 호출되어야 한다');
    });

    test('refreshGroupContext:false → 어떤 notify도 발사되지 않는다', () async {
      var notifications = 0;
      void listener() => notifications += 1;
      GroupMembershipRefreshBus.instance.addListener(listener);
      addTearDown(
        () => GroupMembershipRefreshBus.instance.removeListener(listener),
      );

      final service = GroupCleanupService();
      await service.onGroupArchived(
        'group-1',
        userId: 'user-1',
        refreshGroupContext: false,
      );
      await service.onGroupRestored(
        'group-1',
        userId: 'user-1',
        refreshGroupContext: false,
      );

      expect(notifications, 0,
          reason: 'refreshGroupContext=false면 bus 폴백도 provider reload도 일어나선 안 된다');
    });

    test(
        'provider 주입 + refreshGroupContext:true → bus notify는 0회, provider.load는 1회',
        () async {
      var notifications = 0;
      void listener() => notifications += 1;
      GroupMembershipRefreshBus.instance.addListener(listener);
      addTearDown(
        () => GroupMembershipRefreshBus.instance.removeListener(listener),
      );

      final fakeRepo = _LoadCountingGroupRepository();
      final provider = GroupContextProvider(repository: fakeRepo);
      addTearDown(provider.dispose);

      final service = GroupCleanupService(contextProvider: provider);
      await service.onGroupArchived('group-1', userId: 'user-1');

      expect(notifications, 0);
      expect(fakeRepo.listGroupsCalls, 1);
    });
  });
}

/// GroupContextProvider의 listGroups() 호출 횟수만 세는 최소 fake.
/// 멤버 조회·Supabase 호출까지 가면 Supabase 의존성이 폭주하므로,
/// 그룹 목록과 멤버 목록은 모두 빈 값으로 돌려준다.
class _LoadCountingGroupRepository extends GroupRepository {
  int listGroupsCalls = 0;

  @override
  Future<List<GroupModel>> listGroups() async {
    listGroupsCalls += 1;
    return const <GroupModel>[];
  }

  @override
  Future<GroupModel?> fetchGroup(String groupId) async => null;

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async =>
      const <GroupMemberModel>[];

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteGroup(String groupId) {
    throw UnimplementedError();
  }
}