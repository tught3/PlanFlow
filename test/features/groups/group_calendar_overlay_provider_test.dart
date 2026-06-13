import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_calendar_overlay_provider.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';

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

class _FakeGroupEventRepository extends GroupEventRepository {
  _FakeGroupEventRepository(this.eventsByGroupId);

  final Map<String, List<GroupEventModel>> eventsByGroupId;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return List<GroupEventModel>.from(eventsByGroupId[groupId] ?? const <GroupEventModel>[]);
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
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    createdAt: DateTime.utc(2026, 6, 11),
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
    status: 'active',
    createdAt: DateTime.utc(2026, 6, 11),
  );
}

GroupEventModel _groupEvent({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: 'leader-1',
    location: '회의실',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads selected group overlay items for the visible month', () async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          _group(id: 'group-1', name: '서울1팀', createdBy: 'leader-1'),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'leader-row',
              groupId: 'group-1',
              userId: 'leader-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final provider = GroupCalendarOverlayProvider(
      contextProvider: contextProvider,
      repository: _FakeGroupEventRepository(
        <String, List<GroupEventModel>>{
          'group-1': <GroupEventModel>[
            _groupEvent(
              id: 'group-event-1',
              groupId: 'group-1',
              title: '그룹 회의',
              startAt: DateTime.utc(2026, 6, 15, 9),
              endAt: DateTime.utc(2026, 6, 15, 10),
            ),
          ],
        },
      ),
    );

    await provider.loadForMonth('leader-1', DateTime(2026, 6, 1));

    expect(provider.isPersonalMode, isFalse);
    expect(provider.selectedGroup?.name, '서울1팀');
    expect(provider.items, hasLength(1));
    expect(provider.items.first.title, '그룹 회의');
    expect(provider.items.first.isGroup, isTrue);
  });

  test('stays in personal mode when there are no groups', () async {
    final provider = GroupCalendarOverlayProvider(
      contextProvider: GroupContextProvider(
        repository: _FakeGroupRepository(
          groups: const <GroupModel>[],
          membersByGroupId: const <String, List<GroupMemberModel>>{},
        ),
      ),
      repository: _FakeGroupEventRepository(
        const <String, List<GroupEventModel>>{},
      ),
    );

    await provider.loadForMonth('user-1', DateTime(2026, 6, 1));

    expect(provider.isPersonalMode, isTrue);
    expect(provider.items, isEmpty);
    expect(provider.error, isNull);
  });
}
