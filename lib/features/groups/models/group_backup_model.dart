import 'group_json.dart';

class GroupBackupModel {
  const GroupBackupModel({
    required this.id,
    required this.groupId,
    required this.backupType,
    required this.snapshot,
    required this.createdBy,
    this.createdAt,
    this.restoredAt,
    this.restoredBy,
  });

  static const Set<String> allowedBackupTypes = <String>{
    'archive',
    'delete',
  };

  factory GroupBackupModel.fromJson(Map<String, dynamic> json) {
    final snapshotValue = json['snapshot'];
    final snapshot = snapshotValue is Map<String, dynamic>
        ? Map<String, dynamic>.from(snapshotValue)
        : snapshotValue is Map
            ? Map<String, dynamic>.from(snapshotValue)
            : <String, dynamic>{};

    return GroupBackupModel(
      id: requiredStringValue(json['id'], 'id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      backupType: stringValue(json['backup_type']).isEmpty
          ? 'archive'
          : stringValue(json['backup_type']),
      snapshot: snapshot,
      createdBy: requiredStringValue(json['created_by'], 'created_by'),
      createdAt: dateTimeValue(json['created_at']),
      restoredAt: dateTimeValue(json['restored_at']),
      restoredBy: optionalStringValue(json['restored_by']),
    );
  }

  final String id;
  final String groupId;
  final String backupType;
  final Map<String, dynamic> snapshot;
  final String createdBy;
  final DateTime? createdAt;
  final DateTime? restoredAt;
  final String? restoredBy;

  bool get isArchive => backupType == 'archive';

  bool get isDelete => backupType == 'delete';

  bool get isRestored => restoredAt != null;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_id': groupId,
      'backup_type': backupType,
      'snapshot': snapshot,
      'created_by': createdBy,
      'created_at': utcIsoValue(createdAt),
      'restored_at': utcIsoValue(restoredAt),
      'restored_by': restoredBy,
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'restored_at': utcIsoValue(restoredAt),
      'restored_by': restoredBy,
    };
  }
}
