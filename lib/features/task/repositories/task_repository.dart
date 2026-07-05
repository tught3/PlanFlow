import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/task_model.dart';

/// Task CRUD 리포지토리.
///
/// 모든 쿼리는 **반드시** 현재 로그인 사용자(auth.uid())의 레코드만 반환하도록
/// `.eq('user_id', currentUserId)` 필터를 명시적으로 포함한다.
/// 이는 DB RLS 정책(auth.uid() = user_id)과 병행하는 defence-in-depth이며,
/// RLS가 미설정되거나 우회되는 환경(예: service_role 키 사용)에서도
/// 데이터 누출을 방지한다.
abstract class TaskRepository {
  const TaskRepository();

  factory TaskRepository.supabase({SupabaseClient? client}) =
      SupabaseTaskRepository;

  /// 현재 사용자의 전체 Task 목록을 최신순으로 반환.
  Future<List<TaskModel>> listTasks();

  /// 특정 Plan에 속한 Task 목록을 반환(sort_order → created_at 정렬).
  ///
  /// Plan 상세 화면에서 하위 작업을 표시할 때 사용한다.
  Future<List<TaskModel>> listTasksByPlanId(String planId);

  /// 특정 Plan의 특정 status Task만 반환.
  Future<List<TaskModel>> listTasksByPlanIdAndStatus(
    String planId,
    TaskStatus status,
  );

  /// 특정 status의 Task 목록을 반환(전체 Plan 포함).
  Future<List<TaskModel>> listTasksByStatus(TaskStatus status);

  Future<TaskModel?> fetchTask(String taskId);

  Future<TaskModel> createTask(TaskModel task);

  Future<TaskModel> updateTask(TaskModel task);

  /// Task 상태 전환: `pending → in_progress`.
  Future<TaskModel> startTask(String taskId);

  /// Task 상태 전환: `in_progress → completed`.
  /// `completed_at`을 서버 시각(now)으로 설정한다.
  Future<TaskModel> completeTask(String taskId);

  /// Task 상태를 `pending`으로 되돌린다(completed/in_progress → pending).
  /// `completed_at`은 NULL로 해제한다.
  Future<TaskModel> resetTaskToPending(String taskId);

  /// 정렬 순서 일괄 업데이트(드래그 앤 드롭 등).
  Future<void> reorderTasks(List<String> orderedTaskIds);

  Future<void> deleteTask(String taskId);
}

class SupabaseTaskRepository extends TaskRepository {
  SupabaseTaskRepository({
    SupabaseClient? client,
    String? Function()? currentUserIdProvider,
  })  : _client = client ?? Supabase.instance.client,
        _currentUserIdProvider = currentUserIdProvider;

  final SupabaseClient _client;

  /// 테스트에서 auth 상태를 주입할 수 있도록 별도 provider를 허용한다.
  final String? Function()? _currentUserIdProvider;

  static const _table = 'tasks';

  @override
  Future<List<TaskModel>> listTasks() async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .order('sort_order', ascending: true)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<List<TaskModel>> listTasksByPlanId(String planId) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        // ★ plan_id 필터: 부모 Plan 소속 작업만 조회.
        .eq('plan_id', planId)
        .order('sort_order', ascending: true)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<List<TaskModel>> listTasksByPlanIdAndStatus(
    String planId,
    TaskStatus status,
  ) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        // ★ plan_id 필터: 부모 Plan 소속 작업만 조회.
        .eq('plan_id', planId)
        .eq('status', status.value)
        .order('sort_order', ascending: true)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<List<TaskModel>> listTasksByStatus(TaskStatus status) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .eq('status', status.value)
        .order('sort_order', ascending: true)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<TaskModel?> fetchTask(String taskId) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .eq('id', taskId)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<TaskModel> createTask(TaskModel task) async {
    final userId = _requireCurrentUserId();
    // INSERT 시 user_id를 서버 측 auth.uid()가 아닌 클라이언트에서 명시적으로
    // 세팅한다. RLS 정책(user_id = auth.uid())과 일치해야 INSERT가 허용된다.
    final payload = task.copyWith(userId: userId).toJson(includeId: false);
    final response = await _client
        .from(_table)
        .insert(payload)
        .select()
        .single();
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<TaskModel> updateTask(TaskModel task) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(task.toUpdateJson())
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE 가능.
        .eq('user_id', userId)
        .eq('id', task.id)
        .select()
        .single();
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<TaskModel> startTask(String taskId) async {
    // 상태 전환 검증을 위해 현재 상태를 먼저 조회한다.
    final current = await _fetchOrThrow(taskId);
    final started = current.start();
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(<String, dynamic>{
          'status': started.status.value,
          'completed_at': _utcIso(started.completedAt),
        })
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
        .eq('user_id', userId)
        .eq('id', taskId)
        .select()
        .single();
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<TaskModel> completeTask(String taskId) async {
    // 상태 전환 검증을 위해 현재 상태를 먼저 조회한다.
    final current = await _fetchOrThrow(taskId);
    final completed = current.complete();
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(<String, dynamic>{
          'status': completed.status.value,
          'completed_at': _utcIso(completed.completedAt),
        })
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
        .eq('user_id', userId)
        .eq('id', taskId)
        .select()
        .single();
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<TaskModel> resetTaskToPending(String taskId) async {
    // 상태 전환 검증을 위해 현재 상태를 먼저 조회한다.
    final current = await _fetchOrThrow(taskId);
    final reset = current.resetToPending();
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(<String, dynamic>{
          'status': reset.status.value,
          'completed_at': null,
        })
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
        .eq('user_id', userId)
        .eq('id', taskId)
        .select()
        .single();
    return TaskModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<void> reorderTasks(List<String> orderedTaskIds) async {
    final userId = _requireCurrentUserId();
    // 각 Task의 sort_order를 인덱스로 일괄 업데이트한다.
    for (var i = 0; i < orderedTaskIds.length; i++) {
      final taskId = orderedTaskIds[i];
      await _client
          .from(_table)
          .update(<String, dynamic>{'sort_order': i})
          // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
          .eq('user_id', userId)
          .eq('id', taskId);
    }
  }

  @override
  Future<void> deleteTask(String taskId) async {
    final userId = _requireCurrentUserId();
    await _client
        .from(_table)
        .delete()
        // ★ auth.uid() 필터: 본인 소유 레코드만 DELETE.
        .eq('user_id', userId)
        .eq('id', taskId);
  }

  // ── 헬퍼 ──────────────────────────────────────────────

  /// 현재 로그인 사용자 ID를 반환. 미인증 시 예외.
  ///
  /// RLS(auth.uid()) 대응: 모든 쿼리는 이 값을 user_id 조건으로 사용한다.
  String _requireCurrentUserId() {
    final id =
        _currentUserIdProvider?.call() ?? _client.auth.currentUser?.id;
    if (id == null || id.trim().isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    return id;
  }

  Future<TaskModel> _fetchOrThrow(String taskId) async {
    final task = await fetchTask(taskId);
    if (task == null) {
      throw StateError('작업을 찾을 수 없어요(taskId: $taskId).');
    }
    return task;
  }

  List<TaskModel> _parseList(List<dynamic> response) {
    return response
        .map<TaskModel>((row) => TaskModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }

  static String? _utcIso(DateTime? value) {
    return value?.toUtc().toIso8601String();
  }
}
