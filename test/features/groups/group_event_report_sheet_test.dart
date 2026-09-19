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
import 'package:planflow/features/groups/repositories/group_event_report_repository.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_event_detail_screen.dart';
import 'package:planflow/features/groups/widgets/group_event_report_sheet.dart';

class FakeGroupEventReportRepository extends GroupEventReportRepository {
  FakeGroupEventReportRepository({this.error});

  final Object? error;
  String? lastGroupEventId;
  String? lastGroupId;
  String? lastReason;
  String? lastDetail;
  String? lastContentOwnerId;
  int callCount = 0;

  @override
  Future<void> submitReport({
    required String groupEventId,
    required String groupId,
    required String reason,
    String? detail,
    String? contentOwnerId,
  }) async {
    callCount++;
    lastGroupEventId = groupEventId;
    lastGroupId = groupId;
    lastReason = reason;
    lastDetail = detail;
    lastContentOwnerId = contentOwnerId;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
  }
}

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
  FakeGroupEventRepository({required this.event});

  GroupEventModel event;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async => event;

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
}

class FakeGroupDelegationRepository extends GroupDelegationRepository {
  FakeGroupDelegationRepository();

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

GroupEventModel _event({
  required String id,
  required String groupId,
  required String title,
  String createdBy = 'user-1',
  String status = 'active',
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: DateTime.utc(2026, 6, 11, 1),
    endAt: DateTime.utc(2026, 6, 11, 2),
    createdBy: createdBy,
    status: status,
  );
}

Future<GroupEventProvider> _buildProvider({
  required GroupEventModel event,
  required String viewerId,
}) async {
  final contextProvider = GroupContextProvider(
    repository: FakeGroupRepository(
      groups: <GroupModel>[
        GroupModel(
          id: event.groupId,
          createdBy: 'leader-1',
          name: 'Group',
          createdAt: DateTime.utc(2026, 6, 11),
        ),
      ],
      membersByGroupId: <String, List<GroupMemberModel>>{
        event.groupId: <GroupMemberModel>[
          GroupMemberModel(
            id: 'member-1',
            groupId: event.groupId,
            userId: 'leader-1',
            role: 'leader',
          ),
          GroupMemberModel(
            id: 'member-2',
            groupId: event.groupId,
            userId: viewerId,
            role: 'member',
          ),
        ],
      },
    ),
  );
  await contextProvider.load(viewerId);
  return GroupEventProvider(
    contextProvider: contextProvider,
    repository: FakeGroupEventRepository(event: event),
    delegationRepository: FakeGroupDelegationRepository(),
    nowProvider: () => DateTime.utc(2026, 6, 11, 9),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('GroupEventReportSheet', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      GroupEventReportRepository? repository,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupEventReportSheet(
              groupEventId: 'event-1',
              groupId: 'group-1',
              contentOwnerId: 'creator-1',
              repository: repository,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders all reason chips', (tester) async {
      await pumpSheet(tester);
      expect(find.text('부적절한 콘텐츠'), findsOneWidget);
      expect(find.text('스팸/광고'), findsOneWidget);
      expect(find.text('괴롭힘 또는 피해 유발'), findsOneWidget);
      expect(find.text('기타'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-event-report-detail-field')),
          findsNothing);
    });

    testWidgets('shows detail field only for other reason and submits',
        (tester) async {
      final repository = FakeGroupEventReportRepository();
      await pumpSheet(tester, repository: repository);

      await tester.tap(find.text('기타'));
      await tester.pump();
      expect(find.byKey(const ValueKey('group-event-report-detail-field')),
          findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('group-event-report-detail-field')),
        '설명',
      );

      await tester.tap(
        find.byKey(const ValueKey('group-event-report-submit-button')),
      );
      await tester.pump();

      expect(repository.callCount, 1);
      expect(repository.lastGroupEventId, 'event-1');
      expect(repository.lastGroupId, 'group-1');
      expect(repository.lastReason, 'other');
      expect(repository.lastDetail, '설명');
      expect(repository.lastContentOwnerId, 'creator-1');
    });

    testWidgets('already-reported exception shows feedback and stays open',
        (tester) async {
      await pumpSheet(
        tester,
        repository: FakeGroupEventReportRepository(
          error: const AlreadyReportedException(),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('group-event-report-submit-button')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('group-event-report-status')),
        findsOneWidget,
      );
      expect(find.text('이미 신고 접수됨'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-event-report-submit-button')),
        findsOneWidget,
      );
    });

    testWidgets('generic failure shows error feedback', (tester) async {
      await pumpSheet(
        tester,
        repository: FakeGroupEventReportRepository(error: StateError('boom')),
      );

      await tester.tap(
        find.byKey(const ValueKey('group-event-report-submit-button')),
      );
      await tester.pump();

      expect(find.text('신고를 보내지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    });
  });

  group('GroupEventDetailScreen report action', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required GroupEventModel event,
      required String viewerId,
    }) async {
      final provider = await _buildProvider(event: event, viewerId: viewerId);
      await tester.pumpWidget(
        MaterialApp(
          home: GroupEventDetailScreen(
            eventId: event.id,
            event: event,
            provider: provider,
            currentUserIdOverride: viewerId,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('visible for another user\'s active shared event',
        (tester) async {
      await pumpDetail(
        tester,
        event: _event(
          id: 'event-1',
          groupId: 'group-1',
          title: '남의 일정',
          createdBy: 'leader-1',
        ),
        viewerId: 'user-1',
      );
      expect(
        find.byKey(const ValueKey('group-event-report-action')),
        findsOneWidget,
      );
    });

    testWidgets('hidden for own event', (tester) async {
      await pumpDetail(
        tester,
        event: _event(
          id: 'event-1',
          groupId: 'group-1',
          title: '내 일정',
          createdBy: 'user-1',
        ),
        viewerId: 'user-1',
      );
      expect(
        find.byKey(const ValueKey('group-event-report-action')),
        findsNothing,
      );
    });

    testWidgets('hidden for inactive event', (tester) async {
      await pumpDetail(
        tester,
        event: _event(
          id: 'event-1',
          groupId: 'group-1',
          title: '취소된 일정',
          createdBy: 'leader-1',
          status: 'cancelled',
        ),
        viewerId: 'user-1',
      );
      expect(
        find.byKey(const ValueKey('group-event-report-action')),
        findsNothing,
      );
    });
  });
}
