import 'group_json.dart';

class GroupMemberModel {
  const GroupMemberModel({
    required this.id,
    required this.groupId,
    required this.userId,
    this.role = 'member',
    this.status = 'active',
    this.displayName,
    this.profileName,
    this.profileEmail,
    this.profileInviteCode,
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
      displayName: optionalStringValue(json['display_name']),
      profileName: optionalStringValue(json['profile_display_name']) ??
          optionalStringValue(json['user_display_name']) ??
          optionalStringValue(_profileValue(json, 'display_name')) ??
          optionalStringValue(_profileValue(json, 'name')),
      profileEmail: optionalStringValue(json['profile_email']) ??
          optionalStringValue(json['user_email']) ??
          optionalStringValue(_profileValue(json, 'email')),
      profileInviteCode: optionalStringValue(json['profile_invite_code']) ??
          optionalStringValue(json['user_invite_code']) ??
          optionalStringValue(_profileValue(json, 'invite_code')),
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
  final String? displayName;
  final String? profileName;
  final String? profileEmail;
  final String? profileInviteCode;
  final DateTime? joinedAt;
  final DateTime? removedAt;
  final String? removedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isLeader => role == 'leader';

  bool get isActive => status == 'active';

  String get effectiveDisplayName {
    for (final value in <String?>[
      displayName,
      profileName,
      profileEmail,
      profileInviteCode,
    ]) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return _shortUserId(userId);
  }

  String get secondaryLabel {
    final email = profileEmail?.trim();
    if (email != null && email.isNotEmpty && email != effectiveDisplayName) {
      return email;
    }
    final inviteCode = profileInviteCode?.trim();
    if (inviteCode != null &&
        inviteCode.isNotEmpty &&
        inviteCode != effectiveDisplayName) {
      return '초대 코드 $inviteCode';
    }
    return _shortUserId(userId);
  }

  GroupMemberModel copyWith({
    String? id,
    String? groupId,
    String? userId,
    String? role,
    String? status,
    String? displayName,
    bool clearDisplayName = false,
    String? profileName,
    bool clearProfileName = false,
    String? profileEmail,
    bool clearProfileEmail = false,
    String? profileInviteCode,
    bool clearProfileInviteCode = false,
    DateTime? joinedAt,
    bool clearJoinedAt = false,
    DateTime? removedAt,
    bool clearRemovedAt = false,
    String? removedBy,
    bool clearRemovedBy = false,
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
      displayName: clearDisplayName ? null : displayName ?? this.displayName,
      profileName: clearProfileName ? null : profileName ?? this.profileName,
      profileEmail:
          clearProfileEmail ? null : profileEmail ?? this.profileEmail,
      profileInviteCode: clearProfileInviteCode
          ? null
          : profileInviteCode ?? this.profileInviteCode,
      joinedAt: clearJoinedAt ? null : joinedAt ?? this.joinedAt,
      removedAt: clearRemovedAt ? null : removedAt ?? this.removedAt,
      removedBy: clearRemovedBy ? null : removedBy ?? this.removedBy,
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
      'display_name': displayName,
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
      'display_name': displayName,
      'removed_at': utcIsoValue(removedAt),
      'removed_by': removedBy,
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  static Object? _profileValue(Map<String, dynamic> json, String key) {
    final profile = json['users'];
    if (profile is Map) {
      return profile[key];
    }
    final aliasedProfile = json['profile'];
    if (aliasedProfile is Map) {
      return aliasedProfile[key];
    }
    return null;
  }

  static String _shortUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 8) {
      return trimmed;
    }
    return trimmed.substring(0, 8);
  }
}
