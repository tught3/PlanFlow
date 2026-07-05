import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/plan_model.dart';
import '../repositories/plan_repository.dart';
import 'plan_state.dart';

/// Plan 도메인 프로바이더.
///
/// 프로젝트의 모든 피처 프로바이더(group_event_provider 등)가 ChangeNotifier를
/// 사용하므로 동일하게 ChangeNotifier로 구현한다.
/// (flutter_riverpod 의존성이 있지만 실제 코드베이스는 ChangeNotifier 패턴을
/// 일관되게 사용 중이다.)
///
/// 모든 데이터 액세스는 [PlanRepository]를 거치며, repository 내부에서
/// auth.uid() 기반 user_id 필터를 보장한다.
class PlanProvider extends ChangeNotifier {
  PlanProvider({
    PlanRepository? repository,
    String? Function()? currentUserIdProvider,
    SupabaseClient? client,
  })  : _repository = repository ?? PlanRepository.supabase(client: client),
        _currentUserIdProvider = currentUserIdProvider;

  final PlanRepository _repository;
  final String? Function()? _currentUserIdProvider;

  PlanState _state = const PlanState.initial();
  String? _currentUserId;
  bool _isDisposed = false;

  PlanState get state => _state;
  List<PlanModel> get plans => _state.plans;
  bool get isLoading => _state.isLoading;
  bool get isSubmitting => _state.isSubmitting;
  String? get error => _state.error;
  String? get message => _state.message;

  /// 활성 Plan만 화면 기본 표시용으로 필터링.
  List<PlanModel> get activePlans =>
      _state.plans.where((plan) => plan.isActive).toList(growable: false);

  /// 미인증 시 빈 상태로 초기화. 그 외에는 repository를 통해 로드.
  Future<void> load({String? userIdOverride}) async {
    final userId = userIdOverride ?? _resolveUserId();
    if (userId == null || userId.isEmpty) {
      _currentUserId = null;
      _setState(const PlanState.initial());
      return;
    }

    _currentUserId = userId;
    _setState(_state.copyWith(
      isLoading: true,
      clearError: true,
      clearMessage: true,
    ));

    try {
      final plans = await _repository.listPlans();
      _setState(PlanState(
        plans: plans,
        isLoading: false,
        isSubmitting: false,
      ));
    } catch (error) {
      _setState(PlanState(
        plans: const <PlanModel>[],
        isLoading: false,
        isSubmitting: false,
        error: error.toString(),
      ));
    }
  }

  /// 동일 userId로 새로고침.
  Future<void> refresh() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      await load();
      return;
    }
    await load(userIdOverride: userId);
  }

  Future<PlanModel?> fetchPlan(String planId) async {
    try {
      return await _repository.fetchPlan(planId);
    } catch (error) {
      _setState(_state.copyWith(error: error.toString()));
      return null;
    }
  }

  Future<PlanModel> createPlan({
    required String title,
    String? description,
    PlanPriority priority = PlanPriority.medium,
    DateTime? targetDate,
  }) async {
    final userId = _requireCurrentUserId();

    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final created = await _repository.createPlan(PlanModel(
        id: '',
        userId: userId,
        title: title.trim(),
        description: _emptyToNull(description),
        status: PlanStatus.active,
        priority: priority,
        targetDate: targetDate,
      ));
      await refresh();
      _setState(_state.copyWith(
        isSubmitting: false,
        message: '계획을 만들었어요.',
      ));
      return created;
    } catch (error) {
      _setState(_state.copyWith(
        isSubmitting: false,
        error: error.toString(),
      ));
      rethrow;
    }
  }

  Future<PlanModel> updatePlan(PlanModel plan) async {
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final updated = await _repository.updatePlan(plan);
      await refresh();
      _setState(_state.copyWith(
        isSubmitting: false,
        message: '계획을 수정했어요.',
      ));
      return updated;
    } catch (error) {
      _setState(_state.copyWith(
        isSubmitting: false,
        error: error.toString(),
      ));
      rethrow;
    }
  }

  Future<PlanModel> completePlan(String planId) async {
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final completed = await _repository.completePlan(planId);
      await refresh();
      _setState(_state.copyWith(
        isSubmitting: false,
        message: '계획을 완료했어요.',
      ));
      return completed;
    } catch (error) {
      _setState(_state.copyWith(
        isSubmitting: false,
        error: error.toString(),
      ));
      rethrow;
    }
  }

  Future<PlanModel> archivePlan(String planId) async {
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      final archived = await _repository.archivePlan(planId);
      await refresh();
      _setState(_state.copyWith(
        isSubmitting: false,
        message: '계획을 보관했어요.',
      ));
      return archived;
    } catch (error) {
      _setState(_state.copyWith(
        isSubmitting: false,
        error: error.toString(),
      ));
      rethrow;
    }
  }

  Future<void> deletePlan(String planId) async {
    _requireCurrentUserId();
    _setState(_state.copyWith(isSubmitting: true, clearError: true));
    try {
      await _repository.deletePlan(planId);
      await refresh();
      _setState(_state.copyWith(
        isSubmitting: false,
        message: '계획을 삭제했어요.',
      ));
    } catch (error) {
      _setState(_state.copyWith(
        isSubmitting: false,
        error: error.toString(),
      ));
      rethrow;
    }
  }

  // ── 헬퍼 ──────────────────────────────────────────────

  String? _resolveUserId() {
    return _currentUserIdProvider?.call() ??
        Supabase.instance.client.auth.currentUser?.id;
  }

  String _requireCurrentUserId() {
    final id = _resolveUserId();
    if (id == null || id.isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    return id;
  }

  String? _emptyToNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  void _setState(PlanState newState) {
    if (_isDisposed) {
      return;
    }
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
