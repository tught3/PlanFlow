class GroupDeletionNotice {
  const GroupDeletionNotice({
    required this.id,
    required this.groupName,
    required this.createdAt,
  });

  final String id;
  final String groupName;
  final DateTime createdAt;

  factory GroupDeletionNotice.fromJson(Map<String, dynamic> json) {
    return GroupDeletionNotice(
      id: json['id'] as String,
      groupName: (json['group_name'] as String?) ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
