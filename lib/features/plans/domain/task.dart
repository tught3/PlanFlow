import 'package:freezed_annotation/freezed_annotation.dart';

part 'task.freezed.dart';
part 'task.g.dart';

/// Tasks 테이블에 대응하는 도메인 모델.
///
/// 하나의 [Plan] 하위에 여러 Task가 속하며, [sortOrder]로 정렬 순서를 관리한다.
/// JSON 직렬화는 Supabase 컬럼명(snake_case)을 기준으로 동작한다.
@freezed
class Task with _$Task {
  const Task._();

  const factory Task({
    required String id,
    @JsonKey(name: 'plan_id') required String planId,
    required String title,
    required String status,
    @JsonKey(name: 'sort_order') required int sortOrder,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _Task;

  factory Task.fromJson(Map<String, dynamic> json) => _$TaskFromJson(json);
}
