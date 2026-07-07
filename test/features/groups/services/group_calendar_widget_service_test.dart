import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
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
  _FakeGroupRepo(this._groups);
  final List<GroupModel> _groups;

  @override
  Future<List<GroupModel>> listGroups() async => _groups;
}

class _FakeEventRepo extends Fake implements GroupEventRepository {
  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async =>
      <GroupEventModel>[];
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
}
