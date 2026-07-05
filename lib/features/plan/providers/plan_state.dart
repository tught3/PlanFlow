import '../models/plan_model.dart';

/// Plan 화면용 불변 상태. group_event_state.dart 패턴과 동일하게 수작성.
class PlanState {
  const PlanState({
    required this.plans,
    required this.isLoading,
    required this.isSubmitting,
    this.error,
    this.message,
  });

  const PlanState.initial()
      : plans = const <PlanModel>[],
        isLoading = false,
        isSubmitting = false,
        error = null,
        message = null;

  final List<PlanModel> plans;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;
  final String? message;

  bool get hasPlans => plans.isNotEmpty;

  bool get hasActivePlans =>
      plans.any((plan) => plan.status == PlanStatus.active);

  int get activeCount =>
      plans.where((plan) => plan.status == PlanStatus.active).length;

  int get completedCount =>
      plans.where((plan) => plan.status == PlanStatus.completed).length;

  PlanState copyWith({
    List<PlanModel>? plans,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
    String? message,
    bool clearMessage = false,
  }) {
    return PlanState(
      plans: plans ?? this.plans,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}
