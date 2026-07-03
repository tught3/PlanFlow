import 'group_json.dart';

class GroupEventCommentModel {
  const GroupEventCommentModel({
    required this.id,
    required this.groupEventId,
    required this.groupId,
    required this.authorUserId,
    required this.targetUserId,
    required this.content,
    this.confirmedAt,
    this.createdAt,
    this.updatedAt,
  });

  factory GroupEventCommentModel.fromJson(Map<String, dynamic> json) {
    return GroupEventCommentModel(
      id: requiredStringValue(json['id'], 'id'),
      groupEventId: requiredStringValue(json['group_event_id'], 'group_event_id'),
      groupId: requiredStringValue(json['group_id'], 'group_id'),
      authorUserId: requiredStringValue(json['author_user_id'], 'author_user_id'),
      targetUserId: requiredStringValue(json['target_user_id'], 'target_user_id'),
      content: requiredStringValue(json['content'], 'content'),
      confirmedAt: dateTimeValue(json['confirmed_at']),
      createdAt: dateTimeValue(json['created_at']),
      updatedAt: dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String groupEventId;
  final String groupId;
  final String authorUserId;
  final String targetUserId;
  final String content;
  final DateTime? confirmedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isConfirmed => confirmedAt != null;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'group_event_id': groupEventId,
      'group_id': groupId,
      'author_user_id': authorUserId,
      'target_user_id': targetUserId,
      'content': content,
      'confirmed_at': utcIsoValue(confirmedAt),
      if (createdAt != null) 'created_at': utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'content': content,
      'confirmed_at': utcIsoValue(confirmedAt),
      if (updatedAt != null) 'updated_at': utcIsoValue(updatedAt),
    };
  }

  GroupEventCommentModel copyWith({
    String? id,
    String? groupEventId,
    String? groupId,
    String? authorUserId,
    String? targetUserId,
    String? content,
    DateTime? confirmedAt,
    bool clearConfirmedAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return GroupEventCommentModel(
      id: id ?? this.id,
      groupEventId: groupEventId ?? this.groupEventId,
      groupId: groupId ?? this.groupId,
      authorUserId: authorUserId ?? this.authorUserId,
      targetUserId: targetUserId ?? this.targetUserId,
      content: content ?? this.content,
      confirmedAt: clearConfirmedAt ? null : confirmedAt ?? this.confirmedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
