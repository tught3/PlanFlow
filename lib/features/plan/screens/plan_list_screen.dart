import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/plan_model.dart';
import '../providers/plan_provider.dart';

/// Plan 목록 화면. group_list_screen.dart 패턴을 따른다.
///
/// 로그인 사용자의 계획을 카드 목록으로 보여주고, 생성/상세 이동을 지원한다.
class PlanListScreen extends StatefulWidget {
  const PlanListScreen({
    super.key,
    PlanProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final PlanProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<PlanListScreen> createState() => _PlanListScreenState();
}

class _PlanListScreenState extends State<PlanListScreen> {
  late final PlanProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? PlanProvider();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final userId = widget._currentUserIdOverride ?? authProvider.userId ?? '';
    await _provider.load(userIdOverride: userId);
  }

  Future<void> _openCreatePlan() async {
    final result = await context.push<String>(AppRoutes.planCreate);
    if (!mounted) {
      return;
    }
    if (result != null) {
      await _load();
    }
  }

  Future<void> _openPlanDetail(PlanModel plan) async {
    final result = await context.push<String>(
      AppRoutes.planDetailForId(plan.id),
    );
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final state = _provider.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('내 계획'),
            actions: [
              IconButton(
                tooltip: '새로고침',
                onPressed: state.isLoading ? null : _load,
                icon: const Icon(Icons.refresh_outlined),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (state.isLoading && !state.hasPlans) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (state.error != null && !state.hasPlans) ...[
                  _buildErrorCard(context, state.error!),
                ] else if (!state.hasPlans) ...[
                  _buildEmptyState(context),
                ] else ...[
                  _buildSummaryRow(context, state),
                  const SizedBox(height: 16),
                  ...state.plans.map(
                    (plan) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PlanListTile(
                        key: ValueKey<String>('plan-list-item-${plan.id}'),
                        plan: plan,
                        onTap: () => _openPlanDetail(plan),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('plan-list-create-button'),
                  onPressed: state.isSubmitting ? null : _openCreatePlan,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('새 계획 만들기'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSummaryRow(BuildContext context, PlanState state) {
    return Row(
      children: [
        Expanded(
          child: _SummaryChip(
            label: '진행 중',
            count: state.activeCount,
            color: PlanFlowColors.active,
            bgColor: PlanFlowColors.activeLight,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SummaryChip(
            label: '완료',
            count: state.completedCount,
            color: PlanFlowColors.primary,
            bgColor: PlanFlowColors.primaryFaint,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const Icon(
            Icons.flag_outlined,
            size: 48,
            color: PlanFlowColors.primaryLight,
          ),
          const SizedBox(height: 12),
          Text(
            '아직 계획이 없어요.\n새로운 목표를 세워보세요!',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, String error) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red),
                const SizedBox(width: 8),
                Text(
                  '불러오기 실패',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.count,
    required this.color,
    required this.bgColor,
  });

  final String label;
  final int count;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanListTile extends StatelessWidget {
  const _PlanListTile({
    super.key,
    required this.plan,
    required this.onTap,
  });

  final PlanModel plan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PriorityDot(priority: plan.priority),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            decoration: plan.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                            color: plan.isCompleted
                                ? PlanFlowColors.textSecondary
                                : PlanFlowColors.textPrimary,
                          ),
                    ),
                    if (plan.description != null &&
                        plan.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        plan.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _StatusBadge(status: plan.status),
                        if (plan.targetDate != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.event_outlined,
                            size: 14,
                            color: plan.isOverdue
                                ? Colors.red
                                : PlanFlowColors.textSecondary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatDate(plan.targetDate!),
                            style: TextStyle(
                              fontSize: 11,
                              color: plan.isOverdue
                                  ? Colors.red
                                  : PlanFlowColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: PlanFlowColors.primaryLight,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year}.${local.month.toString().padLeft(2, '0')}.'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

class _PriorityDot extends StatelessWidget {
  const _PriorityDot({required this.priority});

  final PlanPriority priority;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      PlanPriority.high => const Color(0xFFE53935),
      PlanPriority.medium => PlanFlowColors.active,
      PlanPriority.low => PlanFlowColors.primaryLight,
    };
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final PlanStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, bgColor, textColor) = switch (status) {
      PlanStatus.active => (
          '진행 중',
          PlanFlowColors.activeLight,
          PlanFlowColors.active,
        ),
      PlanStatus.completed => (
          '완료',
          PlanFlowColors.primaryFaint,
          PlanFlowColors.primary,
        ),
      PlanStatus.archived => (
          '보관',
          PlanFlowColors.tagDoneBg,
          PlanFlowColors.tagDoneText,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
