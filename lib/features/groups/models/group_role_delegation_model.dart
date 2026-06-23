import 'group_json.dart';

class GroupRoleDelegationModel {
  const GroupRoleDelegationModel({
    required this.id,
    required this.groupId,
    required this.delegatorUserId,
    required this.delegateUserId,
    required this.permissions,
    required this.startsAt,
    required this.endsAt,
    required this.status,
    this.cancelledAt,
    this.cancelledBy,
    this.createdAt,
    this.updatedAt,
  });

  static const Set<String> allowedPermissions = <String>{
    'create_group_event',
    'update_group_event',
    'cancel_group_event',
    'view_group_dashboard',
  };

  factory GroupRoleDelegationModel.fromJson(Map<String, dynamic> json) {
    return GroupRoleDelegationModel(
      id: requiredStringValue(json['id'], 'id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      delegatorUserId:
          requiredStringValue(json['delegator_user_id'], 'delegator_user_id'),
      delegateUserId:
          requiredStringValue(json['delegate_user_id'], 'delegate_user_id'),
      permissions: stringListValue(json['permissions']),
      startsAt: requiredDateTimeValue(json['starts_at'], 'starts_at'),
      endsAt: requiredDateTimeValue(json['ends_at'], 'ends_at'),
      status: stringValue(json['status']).isEmpty
          ? 'active'
          : stringValue(json['status']),
      cancelledAt: dateTimeValue(json['cancelled_at']),
      cancelledBy: optionalStringValue(json['cancelled_by']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String groupId;
  final String delegatorUserId;
  final String delegateUserId;
  final List<String> permissions;
  final DateTime startsAt;
  final DateTime endsAt;
  final String status;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status == 'active';

  bool get isExpired => status == 'expired';

  bool get isCancelled => status == 'cancelled';

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_id': groupId,
      'delegator_user_id': delegatorUserId,
      'delegate_user_id': delegateUserId,
      'permissions': permissions,
      'starts_at': utcIsoValue(startsAt),
      'ends_at': utcIsoValue(endsAt),
      'status': status,
      'cancelled_at': utcIsoValue(cancelledAt),
      'cancelled_by': cancelledBy,
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'status': status,
      'cancelled_at': utcIsoValue(cancelledAt),
      'cancelled_by': cancelledBy,
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }
}
