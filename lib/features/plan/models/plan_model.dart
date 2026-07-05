/// Plan 도메인 모델.
///
/// 개인 사용자의 목표/계획을 나타낸다. 모든 레코드는 `user_id`가 `auth.uid()`와
/// 일치하는 사용자만 접근할 수 있어야 한다(RLS 정책 + 쿼리 단 user_id 필터).
///
/// 프로젝트가 freezed/build_runner 코드 생성을 사용하지 않으므로, 기존 모델
/// (group_model.dart 등)과 동일하게 수작성 fromJson/toJson/copyWith 패턴을 따른다.
/// 이 패턴은 json_serializable 호환 JSON 구조를 그대로 보존한다.
class PlanModel {
  const PlanModel({
    required this.id,
    required this.userId,
    required this.title,
    this.description,
    this.status = PlanStatus.active,
    this.priority = PlanPriority.medium,
    this.targetDate,
    this.completedAt,
    this.createdAt,
    this.updatedAt,
  });

  /// Supabase row → 모델. snake_case → camelCase 매핑.
  factory PlanModel.fromJson(Map<String, dynamic> json) {
    return PlanModel(
      id: _requiredString(json['id'], 'id'),
      userId: _requiredString(json['user_id'], 'user_id'),
      title: _requiredString(json['title'], 'title'),
      description: _optionalString(json['description']),
      status: PlanStatus.fromJson(json['status']),
      priority: PlanPriority.fromJson(json['priority']),
      targetDate: _dateTime(json['target_date']),
      completedAt: _dateTime(json['completed_at']),
      createdAt: _dateTime(json['created_at']),
      updatedAt: _dateTime(json['updated_at']),
    );
  }

  final String id;

  /// 레코드 소유자. RLS 정책상 auth.uid()와 동일해야 한다.
  final String userId;
  final String title;
  final String? description;
  final PlanStatus status;
  final PlanPriority priority;
  final DateTime? targetDate;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status == PlanStatus.active;

  bool get isCompleted => status == PlanStatus.completed;

  bool get isArchived => status == PlanStatus.archived;

  bool get isOverdue {
    final date = targetDate;
    if (date == null) {
      return false;
    }
    return date.isBefore(DateTime.now().toUtc()) && !isCompleted;
  }

  PlanModel copyWith({
    String? id,
    String? userId,
    String? title,
    String? description,
    bool clearDescription = false,
    PlanStatus? status,
    PlanPriority? priority,
    DateTime? targetDate,
    bool clearTargetDate = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PlanModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      description:
          clearDescription ? null : description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      targetDate: clearTargetDate ? null : targetDate ?? this.targetDate,
      completedAt:
          clearCompletedAt ? null : completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 전체 row INSERT용. created_at/updated_at은 DB 기본값에 맡길 수 있지만
  /// 동기화/오프라인 케이스를 위해 포함한다.
  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'user_id': userId,
      'title': title,
      'description': description,
      'status': status.value,
      'priority': priority.value,
      'target_date': _utcIso(targetDate),
      'completed_at': _utcIso(completedAt),
      if (createdAt != null) 'created_at': _utcIso(createdAt),
      if (updatedAt != null) 'updated_at': _utcIso(updatedAt),
    };
  }

  /// UPDATE용 payload. user_id/created_at은 변경 불가.
  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'title': title,
      'description': description,
      'status': status.value,
      'priority': priority.value,
      'target_date': _utcIso(targetDate),
      'completed_at': _utcIso(completedAt),
      if (updatedAt != null) 'updated_at': _utcIso(updatedAt),
    };
  }

  // ── JSON 헬퍼 (group_json.dart 호환 로직 인라인 복제) ──────────────

  static String _requiredString(Object? value, String fieldName) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) {
      throw StateError('Missing required field: $fieldName');
    }
    return text;
  }

  static String? _optionalString(Object? value) {
    final text = value?.toString() ?? '';
    return text.isEmpty ? null : text;
  }

  static DateTime? _dateTime(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    return DateTime.tryParse(value.toString());
  }

  static String? _utcIso(DateTime? value) {
    return value?.toUtc().toIso8601String();
  }
}

/// Plan 상태 열거형.
enum PlanStatus {
  active('active'),
  completed('completed'),
  archived('archived');

  const PlanStatus(this.value);

  final String value;

  static PlanStatus fromJson(Object? raw) {
    final text = raw?.toString() ?? '';
    for (final status in PlanStatus.values) {
      if (status.value == text) {
        return status;
      }
    }
    return PlanStatus.active;
  }
}

/// Plan 우선순위 열거형.
enum PlanPriority {
  low('low'),
  medium('medium'),
  high('high');

  const PlanPriority(this.value);

  final String value;

  static PlanPriority fromJson(Object? raw) {
    final text = raw?.toString() ?? '';
    for (final priority in PlanPriority.values) {
      if (priority.value == text) {
        return priority;
      }
    }
    return PlanPriority.medium;
  }
}
