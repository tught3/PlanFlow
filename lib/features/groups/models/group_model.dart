import 'group_json.dart';

class GroupModel {
  const GroupModel({
    required this.id,
    required this.createdBy,
    required this.name,
    this.parentGroupId,
    this.description,
    this.status = 'active',
    this.archivedAt,
    this.createdAt,
    this.updatedAt,
  });

  factory GroupModel.fromJson(Map<String, dynamic> json) {
    return GroupModel(
      id: requiredStringValue(json['id'], 'id'),
      parentGroupId: optionalStringValue(json['parent_group_id']),
      name: requiredStringValue(json['name'], 'name'),
      description: optionalStringValue(json['description']),
      status: stringValue(json['status']).isEmpty
          ? 'active'
          : stringValue(json['status']),
      createdBy: requiredStringValue(json['created_by'], 'created_by'),
      archivedAt: dateTimeValue(json['archived_at']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String? parentGroupId;
  final String name;
  final String? description;
  final String status;
  final String createdBy;
  final DateTime? archivedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status == 'active';

  bool get isArchived => status == 'archived';

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'parent_group_id': parentGroupId,
      'name': name,
      'description': description,
      'status': status,
      'created_by': createdBy,
      'archived_at': utcIsoValue(archivedAt),
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'parent_group_id': parentGroupId,
      'name': name,
      'description': description,
      'status': status,
      'archived_at': utcIsoValue(archivedAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }
}
