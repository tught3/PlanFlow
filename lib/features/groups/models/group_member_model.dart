import 'group_json.dart';

class GroupMemberModel {
  const GroupMemberModel({
    required this.id,
    required this.groupId,
    required this.userId,
    this.role = 'member',
    this.status = 'active',
    this.joinedAt,
    this.removedAt,
    this.removedBy,
    this.createdAt,
    this.updatedAt,
  });

  factory GroupMemberModel.fromJson(Map<String, dynamic> json) {
    return GroupMemberModel(
      id: requiredStringValue(json['id'], 'id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      userId: requiredStringValue(json['user_id'], 'user_id'),
      role: stringValue(json['role']).isEmpty
          ? 'member'
          : stringValue(json['role']),
      status: stringValue(json['status']).isEmpty
          ? 'active'
          : stringValue(json['status']),
      joinedAt: dateTimeValue(json['joined_at']),
      removedAt: dateTimeValue(json['removed_at']),
      removedBy: optionalStringValue(json['removed_by']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String groupId;
  final String userId;
  final String role;
  final String status;
  final DateTime? joinedAt;
  final DateTime? removedAt;
  final String? removedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isLeader => role == 'leader';

  bool get isActive => status == 'active';

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_id': groupId,
      'user_id': userId,
      'role': role,
      'status': status,
      'joined_at': utcIsoValue(joinedAt),
      'removed_at': utcIsoValue(removedAt),
      'removed_by': removedBy,
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'role': role,
      'status': status,
      'removed_at': utcIsoValue(removedAt),
      'removed_by': removedBy,
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }
}
