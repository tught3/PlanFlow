import 'package:freezed_annotation/freezed_annotation.dart';

part 'plan.freezed.dart';
part 'plan.g.dart';

/// Plans 테이블에 대응하는 도메인 모델.
///
/// JSON 직렬화는 Supabase 컬럼명(snake_case)을 기준으로 동작한다.
@freezed
class Plan with _$Plan {
  const Plan._();

  const factory Plan({
    required String id,
    @JsonKey(name: 'user_id') required String userId,
    required String title,
    String? description,
    required String status,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _Plan;

  factory Plan.fromJson(Map<String, dynamic> json) => _$PlanFromJson(json);
}
