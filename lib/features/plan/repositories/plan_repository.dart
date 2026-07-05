import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/plan_model.dart';

/// Plan CRUD 리포지토리.
///
/// 모든 쿼리는 **반드시** 현재 로그인 사용자(auth.uid())의 레코드만 반환하도록
/// `.eq('user_id', currentUserId)` 필터를 명시적으로 포함한다.
/// 이는 DB RLS 정책(auth.uid() = user_id)과 병행하는 defence-in-depth이며,
/// RLS가 미설정되거나 우회되는 환경(예: service_role 키 사용)에서도
/// 데이터 누출을 방지한다.
abstract class PlanRepository {
  const PlanRepository();

  factory PlanRepository.supabase({SupabaseClient? client}) =
      SupabasePlanRepository;

  /// 현재 사용자의 활성(active) Plan 목록을 최신순으로 반환.
  Future<List<PlanModel>> listPlans();

  /// 특정 status의 Plan 목록을 반환.
  Future<List<PlanModel>> listPlansByStatus(PlanStatus status);

  Future<PlanModel?> fetchPlan(String planId);

  Future<PlanModel> createPlan(PlanModel plan);

  Future<PlanModel> updatePlan(PlanModel plan);

  /// Plan을 완료 처리(status=completed, completed_at=now).
  Future<PlanModel> completePlan(String planId);

  /// Plan을 보관 처리(status=archived).
  Future<PlanModel> archivePlan(String planId);

  Future<void> deletePlan(String planId);
}

class SupabasePlanRepository extends PlanRepository {
  SupabasePlanRepository({
    SupabaseClient? client,
    String? Function()? currentUserIdProvider,
  })  : _client = client ?? Supabase.instance.client,
        _currentUserIdProvider = currentUserIdProvider;

  final SupabaseClient _client;

  /// 테스트에서 auth 상태를 주입할 수 있도록 별도 provider를 허용한다.
  final String? Function()? _currentUserIdProvider;

  static const _table = 'plans';

  @override
  Future<List<PlanModel>> listPlans() async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .eq('status', PlanStatus.active.value)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<List<PlanModel>> listPlansByStatus(PlanStatus status) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .eq('status', status.value)
        .order('created_at', ascending: false);
    return _parseList(response);
  }

  @override
  Future<PlanModel?> fetchPlan(String planId) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .select()
        // ★ auth.uid() 필터: 본인 소유 레코드만 조회.
        .eq('user_id', userId)
        .eq('id', planId)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return PlanModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<PlanModel> createPlan(PlanModel plan) async {
    final userId = _requireCurrentUserId();
    // INSERT 시 user_id를 서버 측 auth.uid()가 아닌 클라이언트에서 명시적으로
    // 세팅한다. RLS 정책(user_id = auth.uid())과 일치해야 INSERT가 허용된다.
    final payload = plan.copyWith(userId: userId).toJson(includeId: false);
    final response = await _client
        .from(_table)
        .insert(payload)
        .select()
        .single();
    return PlanModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<PlanModel> updatePlan(PlanModel plan) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(plan.toUpdateJson())
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE 가능.
        .eq('user_id', userId)
        .eq('id', plan.id)
        .select()
        .single();
    return PlanModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<PlanModel> completePlan(String planId) async {
    final userId = _requireCurrentUserId();
    final now = DateTime.now().toUtc().toIso8601String();
    final response = await _client
        .from(_table)
        .update(<String, dynamic>{
          'status': PlanStatus.completed.value,
          'completed_at': now,
        })
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
        .eq('user_id', userId)
        .eq('id', planId)
        .select()
        .single();
    return PlanModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<PlanModel> archivePlan(String planId) async {
    final userId = _requireCurrentUserId();
    final response = await _client
        .from(_table)
        .update(<String, dynamic>{
          'status': PlanStatus.archived.value,
        })
        // ★ auth.uid() 필터: 본인 소유 레코드만 UPDATE.
        .eq('user_id', userId)
        .eq('id', planId)
        .select()
        .single();
    return PlanModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<void> deletePlan(String planId) async {
    final userId = _requireCurrentUserId();
    await _client
        .from(_table)
        .delete()
        // ★ auth.uid() 필터: 본인 소유 레코드만 DELETE.
        .eq('user_id', userId)
        .eq('id', planId);
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

  List<PlanModel> _parseList(List<dynamic> response) {
    return response
        .map<PlanModel>((row) => PlanModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
