import 'group_json.dart';

class GroupEventModel {
  const GroupEventModel({
    required this.id,
    required this.groupId,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.createdBy,
    this.description,
    this.location,
    this.allDay = false,
    this.recurrenceType = 'none',
    this.recurrenceUntil,
    this.updatedBy,
    this.cancelledAt,
    this.cancelledBy,
    this.personalEventId,
    this.status = 'active',
    this.createdAt,
    this.updatedAt,
  });

  static const Set<String> allowedRecurrenceTypes = <String>{
    'none',
    'daily',
    'weekly',
    'monthly',
  };

  factory GroupEventModel.fromJson(Map<String, dynamic> json) {
    return GroupEventModel(
      id: requiredStringValue(json['id'], 'id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      title: requiredStringValue(json['title'], 'title'),
      description: optionalStringValue(json['description']),
      location: optionalStringValue(json['location']),
      startAt: requiredDateTimeValue(json['start_at'], 'start_at'),
      endAt: requiredDateTimeValue(json['end_at'], 'end_at'),
      allDay: json['all_day'] == true,
      recurrenceType: stringValue(json['recurrence_type']).isEmpty
          ? 'none'
          : stringValue(json['recurrence_type']),
      recurrenceUntil: dateTimeValue(json['recurrence_until']),
      createdBy: requiredStringValue(json['created_by'], 'created_by'),
      updatedBy: optionalStringValue(json['updated_by']),
      cancelledAt: dateTimeValue(json['cancelled_at']),
      cancelledBy: optionalStringValue(json['cancelled_by']),
      personalEventId: optionalStringValue(json['personal_event_id']),
      status: stringValue(json['status']).isEmpty
          ? 'active'
          : stringValue(json['status']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String groupId;
  final String title;
  final String? description;
  final String? location;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String recurrenceType;
  final DateTime? recurrenceUntil;
  final String createdBy;
  final String? updatedBy;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final String? personalEventId;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status == 'active';

  bool get isCancelled => status == 'cancelled';

  bool get isArchived => status == 'archived';

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_id': groupId,
      'title': title,
      'description': description,
      'location': location,
      'start_at': utcIsoValue(startAt),
      'end_at': utcIsoValue(endAt),
      'all_day': allDay,
      'recurrence_type': recurrenceType,
      'recurrence_until': utcIsoValue(recurrenceUntil),
      'created_by': createdBy,
      'updated_by': updatedBy,
      'cancelled_at': utcIsoValue(cancelledAt),
      'cancelled_by': cancelledBy,
      'personal_event_id': personalEventId,
      'status': status,
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'title': title,
      'description': description,
      'location': location,
      'start_at': utcIsoValue(startAt),
      'end_at': utcIsoValue(endAt),
      'all_day': allDay,
      'recurrence_type': recurrenceType,
      'recurrence_until': utcIsoValue(recurrenceUntil),
      'updated_by': updatedBy,
      'cancelled_at': utcIsoValue(cancelledAt),
      'cancelled_by': cancelledBy,
      'personal_event_id': personalEventId,
      'status': status,
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  GroupEventModel copyWith({
    String? id,
    String? groupId,
    String? title,
    String? description,
    bool clearDescription = false,
    String? location,
    bool clearLocation = false,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    String? recurrenceType,
    DateTime? recurrenceUntil,
    bool clearRecurrenceUntil = false,
    String? createdBy,
    String? updatedBy,
    bool clearUpdatedBy = false,
    DateTime? cancelledAt,
    bool clearCancelledAt = false,
    String? cancelledBy,
    bool clearCancelledBy = false,
    String? personalEventId,
    bool clearPersonalEventId = false,
    String? status,
    DateTime? createdAt,
    bool clearCreatedAt = false,
    DateTime? updatedAt,
    bool clearUpdatedAt = false,
  }) {
    return GroupEventModel(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      title: title ?? this.title,
      description: clearDescription ? null : description ?? this.description,
      location: clearLocation ? null : location ?? this.location,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      recurrenceType: recurrenceType ?? this.recurrenceType,
      recurrenceUntil:
          clearRecurrenceUntil ? null : recurrenceUntil ?? this.recurrenceUntil,
      createdBy: createdBy ?? this.createdBy,
      updatedBy: clearUpdatedBy ? null : updatedBy ?? this.updatedBy,
      cancelledAt: clearCancelledAt ? null : cancelledAt ?? this.cancelledAt,
      cancelledBy: clearCancelledBy ? null : cancelledBy ?? this.cancelledBy,
      personalEventId:
          clearPersonalEventId ? null : personalEventId ?? this.personalEventId,
      status: status ?? this.status,
      createdAt: clearCreatedAt ? null : createdAt ?? this.createdAt,
      updatedAt: clearUpdatedAt ? null : updatedAt ?? this.updatedAt,
    );
  }
}
