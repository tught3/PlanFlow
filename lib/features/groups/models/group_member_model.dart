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
    this.displayName,
    this.email,
    this.inviteCode,
    this.createdAt,
    this.updatedAt,
  });

  factory GroupMemberModel.fromJson(Map<String, dynamic> json) {
    final userProfile = _userProfileFromJson(json);
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
      displayName: _firstNonEmptyString(<Object?>[
        json['display_name'],
        json['name'],
        json['nickname'],
        userProfile?['display_name'],
        userProfile?['name'],
        userProfile?['nickname'],
      ]),
      email: _firstNonEmptyString(<Object?>[
        json['email'],
        userProfile?['email'],
      ]),
      inviteCode: _firstNonEmptyString(<Object?>[
        json['invite_code'],
        userProfile?['invite_code'],
      ]),
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
  final String? displayName;
  final String? email;
  final String? inviteCode;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isLeader => role == 'leader';

  bool get isActive => status == 'active';

  String get displayLabel {
    final candidates = <String?>[displayName, email, userId];
    for (final candidate in candidates) {
      final value = candidate?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return userId;
  }

  GroupMemberModel copyWith({
    String? id,
    String? groupId,
    String? userId,
    String? role,
    String? status,
    DateTime? joinedAt,
    bool clearJoinedAt = false,
    DateTime? removedAt,
    bool clearRemovedAt = false,
    String? removedBy,
    bool clearRemovedBy = false,
    String? displayName,
    bool clearDisplayName = false,
    String? email,
    bool clearEmail = false,
    String? inviteCode,
    bool clearInviteCode = false,
    DateTime? createdAt,
    bool clearCreatedAt = false,
    DateTime? updatedAt,
    bool clearUpdatedAt = false,
  }) {
    return GroupMemberModel(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      userId: userId ?? this.userId,
      role: role ?? this.role,
      status: status ?? this.status,
      joinedAt: clearJoinedAt ? null : joinedAt ?? this.joinedAt,
      removedAt: clearRemovedAt ? null : removedAt ?? this.removedAt,
      removedBy: clearRemovedBy ? null : removedBy ?? this.removedBy,
      displayName: clearDisplayName ? null : displayName ?? this.displayName,
      email: clearEmail ? null : email ?? this.email,
      inviteCode: clearInviteCode ? null : inviteCode ?? this.inviteCode,
      createdAt: clearCreatedAt ? null : createdAt ?? this.createdAt,
      updatedAt: clearUpdatedAt ? null : updatedAt ?? this.updatedAt,
    );
  }

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
      if (displayName != null) 'display_name': displayName,
      if (email != null) 'email': email,
      if (inviteCode != null) 'invite_code': inviteCode,
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

  static Map<String, dynamic>? _userProfileFromJson(
    Map<String, dynamic> json,
  ) {
    final rawProfile = json['user'] ?? json['users'] ?? json['profile'];
    if (rawProfile is Map) {
      return Map<String, dynamic>.from(rawProfile);
    }
    return null;
  }

  static String? _firstNonEmptyString(Iterable<Object?> values) {
    for (final value in values) {
      final text = optionalStringValue(value)?.trim();
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }
}
