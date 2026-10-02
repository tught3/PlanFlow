class GroupDeletionNoticeModel {
  const GroupDeletionNoticeModel({
    required this.id,
    required this.deletedGroupId,
    required this.groupName,
    required this.deletedAt,
  });

  final String id;
  final String deletedGroupId;
  final String groupName;
  final DateTime deletedAt;

  factory GroupDeletionNoticeModel.fromJson(Map<String, dynamic> json) {
    return GroupDeletionNoticeModel(
      id: json['id'] as String,
      deletedGroupId: json['deleted_group_id'] as String,
      groupName: json['group_name'] as String,
      deletedAt: DateTime.parse(json['deleted_at'] as String),
    );
  }
}
