import '../models/task_model.dart';

/// Task 화면용 불변 상태. plan_state.dart 패턴과 동일하게 수작성.
class TaskState {
  const TaskState({
    required this.tasks,
    required this.isLoading,
    required this.isSubmitting,
    this.activePlanId,
    this.error,
    this.message,
  });

  const TaskState.initial()
      : tasks = const <TaskModel>[],
        isLoading = false,
        isSubmitting = false,
        activePlanId = null,
        error = null,
        message = null;

  final List<TaskModel> tasks;

  /// 현재 표시 중인 Plan 필터. null이면 전체 Task 표시.
  final String? activePlanId;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;
  final String? message;

  bool get hasTasks => tasks.isNotEmpty;

  int get pendingCount =>
      tasks.where((task) => task.status == TaskStatus.pending).length;

  int get inProgressCount =>
      tasks.where((task) => task.status == TaskStatus.inProgress).length;

  int get completedCount =>
      tasks.where((task) => task.status == TaskStatus.completed).length;

  /// 완료되지 않은 작업(pending + in_progress).
  int get openCount => pendingCount + inProgressCount;

  /// 진행률(0.0 ~ 1.0). 작업이 없으면 0.
  double get progressRatio {
    if (tasks.isEmpty) {
      return 0;
    }
    return completedCount / tasks.length;
  }

  List<TaskModel> get pendingTasks => tasks
      .where((task) => task.status == TaskStatus.pending)
      .toList(growable: false);

  List<TaskModel> get inProgressTasks => tasks
      .where((task) => task.status == TaskStatus.inProgress)
      .toList(growable: false);

  List<TaskModel> get completedTasks => tasks
      .where((task) => task.status == TaskStatus.completed)
      .toList(growable: false);

  TaskState copyWith({
    List<TaskModel>? tasks,
    String? activePlanId,
    bool clearActivePlanId = false,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
    String? message,
    bool clearMessage = false,
  }) {
    return TaskState(
      tasks: tasks ?? this.tasks,
      activePlanId:
          clearActivePlanId ? null : activePlanId ?? this.activePlanId,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}
