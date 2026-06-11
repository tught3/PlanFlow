import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_member_model.dart';
import '../models/group_model.dart';

abstract class GroupRepository {
  const GroupRepository();

  factory GroupRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupRepository;

  Future<List<GroupModel>> listGroups();

  Future<GroupModel?> fetchGroup(String groupId);

  Future<GroupModel> createGroup(GroupModel group);

  Future<GroupModel> updateGroup(GroupModel group);

  Future<List<GroupMemberModel>> listMembers(String groupId);

  Future<GroupMemberModel> addMember(GroupMemberModel member);

  Future<GroupMemberModel> updateMember(GroupMemberModel member);
}

class SupabaseGroupRepository extends GroupRepository {
  SupabaseGroupRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<GroupModel>> listGroups() async {
    final response = await _client
        .from('groups')
        .select()
        .order('created_at', ascending: false);
    return response
        .map<GroupModel>((row) => GroupModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    final response =
        await _client.from('groups').select().eq('id', groupId).maybeSingle();
    if (response == null) {
      return null;
    }
    return GroupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) async {
    final response = await _client
        .from('groups')
        .insert(group.toJson(includeId: group.id.trim().isNotEmpty))
        .select()
        .single();
    return GroupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) async {
    final response = await _client
        .from('groups')
        .update(group.toUpdateJson())
        .eq('id', group.id)
        .select()
        .single();
    return GroupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    final response = await _client
        .from('group_members')
        .select()
        .eq('group_id', groupId)
        .order('created_at', ascending: true);
    return response
        .map<GroupMemberModel>(
          (row) => GroupMemberModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) async {
    final response = await _client
        .from('group_members')
        .insert(member.toJson(includeId: member.id.trim().isNotEmpty))
        .select()
        .single();
    return GroupMemberModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) async {
    final response = await _client
        .from('group_members')
        .update(member.toUpdateJson())
        .eq('id', member.id)
        .select()
        .single();
    return GroupMemberModel.fromJson(_rowAsJson(response));
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
