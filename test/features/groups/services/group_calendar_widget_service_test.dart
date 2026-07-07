import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/services/group_calendar_widget_service.dart';
import 'package:planflow/services/home_widget_platform.dart';

/// saveWidgetData 호출을 기록하는 Fake 플랫폼.
class _FakePlatform extends HomeWidgetPlatform {
  final Map<String, Object?> saved = <String, Object?>{};

  @override
  bool get isSupported => true;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    saved[id] = data;
    return true;
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async =>
      true;

  @override
  Future<bool> setAppGroupId(String groupId) async => true;
}

class _FakeGroupRepo extends Fake implements GroupRepository {
  _FakeGroupRepo(this._groups, [this._members = const <GroupMemberModel>[]]);
  final List<GroupModel> _groups;
  final List<GroupMemberModel> _members;

  @override
  Future<List<GroupModel>> listGroups() async => _groups;

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async => _members;
}

class _FakeEventRepo extends Fake implements GroupEventRepository {
  _FakeEventRepo([this._events = const <GroupEventModel>[]]);
  final List<GroupEventModel> _events;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async =>
      _events;
}

GroupModel _group(String id, String name) => GroupModel(
      id: id,
      createdBy: 'owner-1',
      name: name,
    );

void main() {
  setUp(() {
    // _readSelectedGroupId가 SharedPreferences를 읽으므로 mock 초기화 필요.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('그룹이 있으면 gw_groups_json에 그룹 id/name이 저장된다', () async {
    final platform = _FakePlatform();
    final service = GroupCalendarWidgetService(
      groupRepository: _FakeGroupRepo(<GroupModel>[
        _group('g1', '팀 A'),
        _group('g2', '팀 B'),
      ]),
      eventRepository: _FakeEventRepo(),
      platform: platform,
    );

    await service.doRefreshForTesting('user-1');

    final raw = platform.saved['gw_groups_json'];
    expect(raw, isA<String>());
    final decoded = jsonDecode(raw as String) as List<dynamic>;
    final ids = decoded.map((e) => (e as Map)['id']).toList();
    final names = decoded.map((e) => (e as Map)['name']).toList();
    expect(ids, containsAll(<String>['g1', 'g2']));
    expect(names, containsAll(<String>['팀 A', '팀 B']));
  });

  test('그룹이 없으면 gw_groups_json이 빈 배열 "[]"로 저장된다', () async {
    final platform = _FakePlatform();
    final service = GroupCalendarWidgetService(
      groupRepository: _FakeGroupRepo(<GroupModel>[]),
      eventRepository: _FakeEventRepo(),
      platform: platform,
    );

    await service.doRefreshForTesting('user-1');

    expect(platform.saved['gw_groups_json'], '[]');
  });

  group('buildDisambiguatedDisplayNames', () {
    GroupMemberModel member(String userId, String name, DateTime joinedAt) =>
        GroupMemberModel(
          id: 'm-$userId',
          groupId: 'g1',
          userId: userId,
          displayName: name,
          joinedAt: joinedAt,
        );

    test('성이 겹치지 않으면 성 한 글자만 사용한다', () {
      final members = [
        member('u1', '김철수', DateTime(2026, 1, 1)),
        member('u2', '박민지', DateTime(2026, 1, 2)),
        member('u3', '이정훈', DateTime(2026, 1, 3)),
      ];

      final names = GroupCalendarWidgetService.buildDisambiguatedDisplayNames(
        members,
      );

      expect(names['u1'], '김');
      expect(names['u2'], '박');
      expect(names['u3'], '이');
    });

    test('성이 겹치면 가입 순서대로 A/B/C를 붙인다', () {
      final members = [
        member('u_later', '김민수', DateTime(2026, 2, 1)),
        member('u_first', '김철수', DateTime(2026, 1, 1)),
        member('u3', '이정훈', DateTime(2026, 1, 3)),
      ];

      final names = GroupCalendarWidgetService.buildDisambiguatedDisplayNames(
        members,
      );

      expect(names['u_first'], '김A');
      expect(names['u_later'], '김B');
      expect(names['u3'], '이');
    });
  });

  String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  test(
      '오늘의 gw_<gid>_occurrences_json 에 멤버별 표시이름 항목이 날짜×작성자 개수만큼 기록된다',
      () async {
    final today = planflowNow();
    GroupMemberModel member(String userId, String name, DateTime joinedAt) =>
        GroupMemberModel(
          id: 'm-$userId',
          groupId: 'g1',
          userId: userId,
          displayName: name,
          joinedAt: joinedAt,
        );
    GroupEventModel event(String id, String createdBy) => GroupEventModel(
          id: id,
          groupId: 'g1',
          title: '일정 $id',
          startAt: today.toUtc(),
          endAt: today.add(const Duration(hours: 1)).toUtc(),
          createdBy: createdBy,
        );

    final platform = _FakePlatform();
    final service = GroupCalendarWidgetService(
      groupRepository: _FakeGroupRepo(
        <GroupModel>[_group('g1', '팀 A')],
        <GroupMemberModel>[
          member('u1', '김철수', DateTime(2026, 1, 1)),
          member('u2', '박민지', DateTime(2026, 1, 2)),
        ],
      ),
      eventRepository: _FakeEventRepo(<GroupEventModel>[
        event('e1', 'u1'),
        event('e2', 'u1'),
        event('e3', 'u2'),
      ]),
      platform: platform,
    );

    await service.doRefreshForTesting('user-1');

    final raw = platform.saved['gw_g1_occurrences_json'] as String?;
    expect(raw, isNotNull);
    final items = (jsonDecode(raw!) as List<dynamic>)
        .cast<Map<String, dynamic>>();

    final todayStr = ymd(DateTime(today.year, today.month, today.day));
    final todayItems = items.where((e) => e['d'] == todayStr).toList();

    expect(todayItems.where((e) => e['n'] == '김').length, 2);
    expect(todayItems.where((e) => e['n'] == '박').length, 1);
    // critical 필드는 그룹 이벤트에 존재하지 않으므로 넣지 않는다.
    for (final item in items) {
      expect(item.containsKey('critical'), isFalse);
    }
  });

  test(
      '과거·미래 달의 이벤트도 gw_<gid>_occurrences_json 에 상대 날짜로 포함된다',
      () async {
    final now = planflowNow();
    final pastMonth = DateTime(now.year, now.month - 6, 15, 10);
    final futureMonth = DateTime(now.year, now.month + 6, 20, 14);

    GroupMemberModel member(String userId, String name, DateTime joinedAt) =>
        GroupMemberModel(
          id: 'm-$userId',
          groupId: 'g1',
          userId: userId,
          displayName: name,
          joinedAt: joinedAt,
        );
    GroupEventModel event(String id, String createdBy, DateTime start) =>
        GroupEventModel(
          id: id,
          groupId: 'g1',
          title: '일정 $id',
          startAt: planflowSeoulDateTimeToUtc(start),
          endAt: planflowSeoulDateTimeToUtc(start.add(const Duration(hours: 1))),
          createdBy: createdBy,
        );

    final platform = _FakePlatform();
    final service = GroupCalendarWidgetService(
      groupRepository: _FakeGroupRepo(
        <GroupModel>[_group('g1', '팀 A')],
        <GroupMemberModel>[
          member('u1', '최민수', DateTime(2026, 1, 1)),
        ],
      ),
      eventRepository: _FakeEventRepo(<GroupEventModel>[
        event('past', 'u1', pastMonth),
        event('future', 'u1', futureMonth),
      ]),
      platform: platform,
    );

    await service.doRefreshForTesting('user-1');

    final raw = platform.saved['gw_g1_occurrences_json'] as String?;
    expect(raw, isNotNull);
    final items = (jsonDecode(raw!) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final dates = items.map((e) => e['d']).toSet();

    expect(dates, contains(ymd(DateTime(pastMonth.year, pastMonth.month, pastMonth.day))));
    expect(dates, contains(ymd(DateTime(futureMonth.year, futureMonth.month, futureMonth.day))));
  });

  test('동명이인(성 겹침) A/B/C 표시이름이 occurrences_json의 n 필드에 정확히 반영된다', () async {
    final today = planflowNow();
    GroupMemberModel member(String userId, String name, DateTime joinedAt) =>
        GroupMemberModel(
          id: 'm-$userId',
          groupId: 'g1',
          userId: userId,
          displayName: name,
          joinedAt: joinedAt,
        );
    GroupEventModel event(String id, String createdBy) => GroupEventModel(
          id: id,
          groupId: 'g1',
          title: '일정 $id',
          startAt: today.toUtc(),
          endAt: today.add(const Duration(hours: 1)).toUtc(),
          createdBy: createdBy,
        );

    final platform = _FakePlatform();
    final service = GroupCalendarWidgetService(
      groupRepository: _FakeGroupRepo(
        <GroupModel>[_group('g1', '팀 A')],
        <GroupMemberModel>[
          member('u_first', '김철수', DateTime(2026, 1, 1)),
          member('u_later', '김민수', DateTime(2026, 2, 1)),
        ],
      ),
      eventRepository: _FakeEventRepo(<GroupEventModel>[
        event('e1', 'u_first'),
        event('e2', 'u_later'),
      ]),
      platform: platform,
    );

    await service.doRefreshForTesting('user-1');

    final raw = platform.saved['gw_g1_occurrences_json'] as String?;
    expect(raw, isNotNull);
    final items = (jsonDecode(raw!) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final names = items.map((e) => e['n']).toSet();

    expect(names, contains('김A'));
    expect(names, contains('김B'));
  });
}
