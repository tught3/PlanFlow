/// Task 도메인 모델.
///
/// [PlanModel]에 속하는 개별 작업(할 일) 단위를 나타낸다. 하나의 Plan 아래에
/// 여러 Task가 속할 수 있으며(`plan_id`로 부모 참조), 각 Task는
/// `pending → in_progress → completed` 상태 라이프사이클을 가진다.
///
/// 모든 레코드는 `user_id`가 `auth.uid()`와 일치하는 사용자만 접근할 수 있어야
/// 한다(RLS 정책 + 쿼리 단 user_id 필터).
///
/// 프로젝트가 freezed/build_runner 코드 생성을 사용하지 않으므로, 기존 모델
/// (plan_model.dart 등)과 동일하게 수작성 fromJson/toJson/copyWith 패턴을 따른다.
/// 이 패턴은 json_serializable 호환 JSON 구조를 그대로 보존한다.
class TaskModel {
  const TaskModel({
    required this.id,
    required this.userId,
    required this.planId,
    required this.title,
    this.description,
    this.status = TaskStatus.pending,
    this.priority = TaskPriority.medium,
    this.dueDate,
    this.completedAt,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
  });

  /// Supabase row → 모델. snake_case → camelCase 매핑.
  factory TaskModel.fromJson(Map<String, dynamic> json) {
    return TaskModel(
      id: _requiredString(json['id'], 'id'),
      userId: _requiredString(json['user_id'], 'user_id'),
      planId: _requiredString(json['plan_id'], 'plan_id'),
      title: _requiredString(json['title'], 'title'),
      description: _optionalString(json['description']),
      status: TaskStatus.fromJson(json['status']),
      priority: TaskPriority.fromJson(json['priority']),
      dueDate: _dateTime(json['due_date']),
      completedAt: _dateTime(json['completed_at']),
      sortOrder: _asInt(json['sort_order']) ?? 0,
      createdAt: _dateTime(json['created_at']),
      updatedAt: _dateTime(json['updated_at']),
    );
  }

  final String id;

  /// 레코드 소유자. RLS 정책상 auth.uid()와 동일해야 한다.
  final String userId;

  /// 부모 Plan 식별자. Task는 반드시 하나의 Plan에 속한다.
  final String planId;
  final String title;
  final String? description;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime? dueDate;
  final DateTime? completedAt;

  /// 목록 정렬 순서. 값이 작을수록 위에 표시.
  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // ── 상태 편의 getter ──────────────────────────────────

  bool get isPending => status == TaskStatus.pending;

  bool get isInProgress => status == TaskStatus.inProgress;

  bool get isCompleted => status == TaskStatus.completed;

  bool get isDone => isCompleted;

  /// 완료 여부와 무관하게 아직 끝내지 않은 작업(pending 또는 in_progress).
  bool get isOngoing => status == TaskStatus.pending || status == TaskStatus.inProgress;

  bool get isOverdue {
    final date = dueDate;
    if (date == null) {
      return false;
    }
    return date.isBefore(DateTime.now().toUtc()) && !isCompleted;
  }

  // ── 상태 전환 헬퍼 ────────────────────────────────────
  //
  // 이 모델은 상태 전환 유효성 검증(transition validation)을 캡슐화한다.
  // UI/Provider/Repository 어디서든 동일한 규칙이 적용되도록 허용 가능한
  // 전환만 반환하고, 그렇지 않으면 예외를 던진다.

  /// `pending → in_progress` 전환 후의 새 모델을 반환.
  ///
  /// [start]는 이미 진행 중이거나 완료된 작업에 대해 호출하면
  /// [StateError]를 던진다(역방향/재시작 금지).
  TaskModel start() {
    _requireTransition(from: TaskStatus.pending, to: TaskStatus.inProgress);
    return copyWith(status: TaskStatus.inProgress);
  }

  /// `in_progress → completed` 전환 후의 새 모델을 반환.
  /// `completed_at`을 현재 UTC 시각으로 설정한다.
  ///
  /// 이미 완료된 작업에 대해 호출하면 [StateError]를 던진다(멱등하지 않음).
  TaskModel complete({DateTime? at}) {
    _requireTransition(from: TaskStatus.inProgress, to: TaskStatus.completed);
    final now = at ?? DateTime.now().toUtc();
    return copyWith(status: TaskStatus.completed, completedAt: now);
  }

  /// 작업을 다시 `pending`으로 되돌린다(재개).
  ///
  /// 허용 전환: `completed → pending`, `in_progress → pending`.
  /// `completedAt`은 해제(clear)한다.
  TaskModel resetToPending() {
    final allowed = <TaskStatus>{TaskStatus.completed, TaskStatus.inProgress};
    if (!allowed.contains(status)) {
      throw StateError(
        '상태를 pending으로 되돌릴 수 없어요(현재 상태: ${status.value}).',
      );
    }
    return copyWith(
      status: TaskStatus.pending,
      clearCompletedAt: true,
    );
  }

  /// 임의의 상태로 직접 전환(검증 포함). 관리자/수정 화면에서 사용.
  TaskModel withStatus(TaskStatus next, {DateTime? at}) {
    if (next == status) {
      return this;
    }
    switch (next) {
      case TaskStatus.pending:
        return resetToPending();
      case TaskStatus.inProgress:
        return start();
      case TaskStatus.completed:
        return complete(at: at);
    }
  }

  void _requireTransition({
    required TaskStatus from,
    required TaskStatus to,
  }) {
    if (status != from) {
      throw StateError(
        '잘못된 상태 전환입니다: ${status.value} → ${to.value}. '
        '필요한 현재 상태: ${from.value}.',
      );
    }
  }

  // ── 직렬화 ────────────────────────────────────────────

  TaskModel copyWith({
    String? id,
    String? userId,
    String? planId,
    String? title,
    String? description,
    bool clearDescription = false,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? dueDate,
    bool clearDueDate = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TaskModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      planId: planId ?? this.planId,
      title: title ?? this.title,
      description:
          clearDescription ? null : description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      dueDate: clearDueDate ? null : dueDate ?? this.dueDate,
      completedAt:
          clearCompletedAt ? null : completedAt ?? this.completedAt,
      sortOrder: sortOrder ?? this.sortOrder,
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
      'plan_id': planId,
      'title': title,
      'description': description,
      'status': status.value,
      'priority': priority.value,
      'due_date': _utcIso(dueDate),
      'completed_at': _utcIso(completedAt),
      'sort_order': sortOrder,
      if (createdAt != null) 'created_at': _utcIso(createdAt),
      if (updatedAt != null) 'updated_at': _utcIso(updatedAt),
    };
  }

  /// UPDATE용 payload. user_id/plan_id/created_at은 변경 불가.
  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'title': title,
      'description': description,
      'status': status.value,
      'priority': priority.value,
      'due_date': _utcIso(dueDate),
      'completed_at': _utcIso(completedAt),
      'sort_order': sortOrder,
      if (updatedAt != null) 'updated_at': _utcIso(updatedAt),
    };
  }

  // ── JSON 헬퍼 (plan_json.dart 호환 로직 인라인 복제) ──────────────

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

  static int? _asInt(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    return int.tryParse(value.toString());
  }

  static String? _utcIso(DateTime? value) {
    return value?.toUtc().toIso8601String();
  }
}

/// Task 상태 열거형.
///
/// 라이프사이클: `pending → in_progress → completed`.
/// `pending`으로 되돌리는 것(completed/in_progress → pending)은 허용되지만,
/// 역방향 점프(completed → in_progress 등)는 허용하지 않는다.
enum TaskStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed');

  const TaskStatus(this.value);

  final String value;

  static TaskStatus fromJson(Object? raw) {
    final text = raw?.toString() ?? '';
    for (final status in TaskStatus.values) {
      if (status.value == text) {
        return status;
      }
    }
    return TaskStatus.pending;
  }

  /// 한글 표시 라벨.
  String get label => switch (this) {
        TaskStatus.pending => '할 일',
        TaskStatus.inProgress => '진행 중',
        TaskStatus.completed => '완료',
      };
}

/// Task 우선순위 열거형.
enum TaskPriority {
  low('low'),
  medium('medium'),
  high('high');

  const TaskPriority(this.value);

  final String value;

  static TaskPriority fromJson(Object? raw) {
    final text = raw?.toString() ?? '';
    for (final priority in TaskPriority.values) {
      if (priority.value == text) {
        return priority;
      }
    }
    return TaskPriority.medium;
  }
}
