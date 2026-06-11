import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_event_model.dart';

abstract class GroupEventRepository {
  const GroupEventRepository();

  factory GroupEventRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupEventRepository;

  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  );

  Future<GroupEventModel> createGroupEvent(GroupEventModel event);

  Future<GroupEventModel> updateGroupEvent(GroupEventModel event);

  Future<GroupEventModel> cancelGroupEvent(String eventId);

  Future<GroupEventModel> archiveGroupEvent(String eventId);
}

class SupabaseGroupEventRepository extends GroupEventRepository {
  SupabaseGroupEventRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    final response = await _client
        .from('group_events')
        .select()
        .eq('group_id', groupId)
        .eq('status', 'active')
        .lte('start_at', to.toUtc().toIso8601String())
        .gte('end_at', from.toUtc().toIso8601String())
        .order('start_at', ascending: true);
    return response
        .map<GroupEventModel>(
            (row) => GroupEventModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    final currentUser = _requireCurrentUser();
    _validateRecurrenceType(event.recurrenceType);
    _validateTimeRange(event.startAt, event.endAt);
    _validateRecurrenceUntil(event.recurrenceUntil, event.startAt);

    final response = await _client
        .from('group_events')
        .insert(
          event
              .copyWithCreatedBy(currentUser.id)
              .copyWithStatus('active')
              .toJson(includeId: event.id.trim().isNotEmpty),
        )
        .select()
        .single();
    return GroupEventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    final currentUser = _requireCurrentUser();
    _validateRecurrenceType(event.recurrenceType);
    _validateTimeRange(event.startAt, event.endAt);
    _validateRecurrenceUntil(event.recurrenceUntil, event.startAt);

    final response = await _client
        .from('group_events')
        .update(
          event.copyWithUpdatedBy(currentUser.id).toUpdateJson(),
        )
        .eq('id', event.id)
        .select()
        .single();
    return GroupEventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    final currentUser = _requireCurrentUser();
    final event = await _fetchEvent(eventId);
    if (event.status != 'active') {
      throw StateError('활성 일정만 취소할 수 있습니다.');
    }

    final response = await _client
        .from('group_events')
        .update(
          <String, dynamic>{
            'status': 'cancelled',
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
            'cancelled_by': currentUser.id,
            'updated_by': currentUser.id,
          },
        )
        .eq('id', eventId)
        .select()
        .single();
    return GroupEventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) async {
    final currentUser = _requireCurrentUser();
    final event = await _fetchEvent(eventId);
    if (event.status != 'active') {
      throw StateError('활성 일정만 보관할 수 있습니다.');
    }

    final response = await _client
        .from('group_events')
        .update(
          <String, dynamic>{
            'status': 'archived',
            'updated_by': currentUser.id,
          },
        )
        .eq('id', eventId)
        .select()
        .single();
    return GroupEventModel.fromJson(_rowAsJson(response));
  }

  User _requireCurrentUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    return user;
  }

  Future<GroupEventModel> _fetchEvent(String eventId) async {
    final response =
        await _client.from('group_events').select().eq('id', eventId).single();
    return GroupEventModel.fromJson(_rowAsJson(response));
  }

  void _validateRecurrenceType(String recurrenceType) {
    if (!GroupEventModel.allowedRecurrenceTypes.contains(recurrenceType)) {
      throw StateError('허용되지 않은 반복 타입입니다.');
    }
  }

  void _validateTimeRange(DateTime startAt, DateTime endAt) {
    if (endAt.isBefore(startAt)) {
      throw StateError('종료 시각은 시작 시각보다 앞설 수 없습니다.');
    }
  }

  void _validateRecurrenceUntil(DateTime? recurrenceUntil, DateTime startAt) {
    if (recurrenceUntil != null && recurrenceUntil.isBefore(startAt)) {
      throw StateError('반복 종료 시각은 시작 시각보다 앞설 수 없습니다.');
    }
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}

extension on GroupEventModel {
  GroupEventModel copyWithCreatedBy(String createdBy) {
    return GroupEventModel(
      id: id,
      groupId: groupId,
      title: title,
      description: description,
      location: location,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      recurrenceType: recurrenceType,
      recurrenceUntil: recurrenceUntil,
      createdBy: createdBy,
      updatedBy: updatedBy,
      cancelledAt: cancelledAt,
      cancelledBy: cancelledBy,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  GroupEventModel copyWithUpdatedBy(String updatedBy) {
    return GroupEventModel(
      id: id,
      groupId: groupId,
      title: title,
      description: description,
      location: location,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      recurrenceType: recurrenceType,
      recurrenceUntil: recurrenceUntil,
      createdBy: createdBy,
      updatedBy: updatedBy,
      cancelledAt: cancelledAt,
      cancelledBy: cancelledBy,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  GroupEventModel copyWithStatus(String status) {
    return GroupEventModel(
      id: id,
      groupId: groupId,
      title: title,
      description: description,
      location: location,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      recurrenceType: recurrenceType,
      recurrenceUntil: recurrenceUntil,
      createdBy: createdBy,
      updatedBy: updatedBy,
      cancelledAt: cancelledAt,
      cancelledBy: cancelledBy,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
