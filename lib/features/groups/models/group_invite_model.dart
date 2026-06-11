import 'group_json.dart';

class GroupInviteModel {
  const GroupInviteModel({
    required this.id,
    required this.groupId,
    required this.invitedBy,
    required this.status,
    required this.expiresAt,
    this.invitedUserId,
    this.invitedEmail,
    this.invitedInviteCode,
    this.acceptedAt,
    this.rejectedAt,
    this.cancelledAt,
    this.expiredAt,
    this.actedBy,
    this.createdAt,
    this.updatedAt,
  });

  factory GroupInviteModel.fromJson(Map<String, dynamic> json) {
    return GroupInviteModel(
      id: requiredStringValue(json['id'], 'id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      invitedUserId: optionalStringValue(json['invited_user_id']),
      invitedEmail: optionalStringValue(json['invited_email']),
      invitedInviteCode: optionalStringValue(json['invited_invite_code']),
      invitedBy: requiredStringValue(json['invited_by'], 'invited_by'),
      status: stringValue(json['status']).isEmpty
          ? 'pending'
          : stringValue(json['status']),
      expiresAt: requiredDateTimeValue(json['expires_at'], 'expires_at'),
      acceptedAt: dateTimeValue(json['accepted_at']),
      rejectedAt: dateTimeValue(json['rejected_at']),
      cancelledAt: dateTimeValue(json['cancelled_at']),
      expiredAt: dateTimeValue(json['expired_at']),
      actedBy: optionalStringValue(json['acted_by']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String groupId;
  final String? invitedUserId;
  final String? invitedEmail;
  final String? invitedInviteCode;
  final String invitedBy;
  final String status;
  final DateTime expiresAt;
  final DateTime? acceptedAt;
  final DateTime? rejectedAt;
  final DateTime? cancelledAt;
  final DateTime? expiredAt;
  final String? actedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isPending => status == 'pending';

  bool get isAccepted => status == 'accepted';

  bool get isRejected => status == 'rejected';

  bool get isCancelled => status == 'cancelled';

  bool get isExpired => status == 'expired';

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_id': groupId,
      'invited_user_id': invitedUserId,
      'invited_email': invitedEmail,
      'invited_invite_code': invitedInviteCode,
      'invited_by': invitedBy,
      'status': status,
      'expires_at': utcIsoValue(expiresAt),
      'accepted_at': utcIsoValue(acceptedAt),
      'rejected_at': utcIsoValue(rejectedAt),
      'cancelled_at': utcIsoValue(cancelledAt),
      'expired_at': utcIsoValue(expiredAt),
      'acted_by': actedBy,
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }
}
