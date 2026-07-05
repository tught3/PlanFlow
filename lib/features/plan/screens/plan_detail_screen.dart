import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/env.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/plan_model.dart';
import '../providers/plan_provider.dart';

/// Plan 상세 화면. group_event_detail_screen.dart 패턴을 따른다.
///
/// 단일 계획을 표시하고, 완료/보관/삭제/편집 액션을 제공한다.
class PlanDetailScreen extends StatefulWidget {
  const PlanDetailScreen({
    super.key,
    required this.planId,
    this.plan,
    PlanProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final String planId;
  final PlanModel? plan;

  final PlanProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<PlanDetailScreen> createState() => _PlanDetailScreenState();
}

class _PlanDetailScreenState extends State<PlanDetailScreen> {
  late final PlanProvider _provider;
  late final bool _ownsProvider;

  PlanModel? _plan;
  bool _isLoading = false;
  bool _isBusy = false;
  String? _errorMessage;

  String get _currentUserId =>
      widget._currentUserIdOverride ?? authProvider.userId ?? '';

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? PlanProvider();
    _plan = widget.plan;
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
    final userId = _currentUserId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _provider.load(userIdOverride: userId);
      if (!mounted) return;
      if (_plan == null) {
        if (widget.planId.trim().isEmpty) {
          setState(() {
            _errorMessage = '계획 정보를 찾지 못했어요.';
          });
        } else {
          final loaded = await _provider.fetchPlan(widget.planId);
          if (!mounted) return;
          if (loaded == null) {
            setState(() {
              _errorMessage = '계획 정보를 찾지 못했어요.';
            });
          } else {
            setState(() {
              _plan = loaded;
            });
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _completePlan() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() => _isBusy = true);
    try {
      final completed = await _provider.completePlan(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('계획을 완료했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) Navigator.of(context).pop('completed');
      _plan = completed;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _archivePlan() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() => _isBusy = true);
    try {
      final archived = await _provider.archivePlan(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('계획을 보관했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) Navigator.of(context).pop('archived');
      _plan = archived;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _deletePlan() async {
    final plan = _plan;
    if (plan == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('계획 삭제'),
        content: const Text('정말 삭제하시겠어요? 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBusy = true);
    try {
      await _provider.deletePlan(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('계획을 삭제했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) Navigator.of(context).pop('deleted');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('계획 상세'),
            actions: [
              if (_plan != null && !_isBusy)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'complete':
                        unawaited(_completePlan());
                      case 'archive':
                        unawaited(_archivePlan());
                      case 'delete':
                        unawaited(_deletePlan());
                    }
                  },
                  itemBuilder: (context) => [
                    if (_plan!.isActive)
                      const PopupMenuItem(
                        value: 'complete',
                        child: Text('완료 처리'),
                      ),
                    if (_plan!.isActive)
                      const PopupMenuItem(
                        value: 'archive',
                        child: Text('보관'),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('삭제'),
                    ),
                  ],
                ),
            ],
          ),
          body: _buildBody(context),
        ),
        if (_isBusy)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }
    final plan = _plan;
    if (plan == null) {
      return const Center(child: Text('계획 정보를 찾을 수 없어요.'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _buildHeaderCard(context, plan),
        const SizedBox(height: 16),
        if (plan.description != null && plan.description!.isNotEmpty) ...[
          _buildDescriptionCard(context, plan.description!),
          const SizedBox(height: 16),
        ],
        _buildMetaCard(context, plan),
      ],
    );
  }

  Widget _buildHeaderCard(BuildContext context, PlanModel plan) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PriorityChip(priority: plan.priority),
                const SizedBox(width: 8),
                _StatusChip(status: plan.status),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              plan.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionCard(BuildContext context, String description) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '설명',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaCard(BuildContext context, PlanModel plan) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MetaRow(
              icon: Icons.event_outlined,
              label: '목표일',
              value: plan.targetDate != null
                  ? _formatDate(plan.targetDate!)
                  : '없음',
              valueColor: plan.isOverdue ? Colors.red : null,
            ),
            if (plan.completedAt != null) ...[
              const SizedBox(height: 10),
              _MetaRow(
                icon: Icons.check_circle_outline,
                label: '완료일',
                value: _formatDate(plan.completedAt!),
              ),
            ],
            if (plan.createdAt != null) ...[
              const SizedBox(height: 10),
              _MetaRow(
                icon: Icons.schedule_outlined,
                label: '생성일',
                value: _formatDate(plan.createdAt!),
              ),
            ],
          ],
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

class _PriorityChip extends StatelessWidget {
  const _PriorityChip({required this.priority});

  final PlanPriority priority;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (priority) {
      PlanPriority.high => ('높음', const Color(0xFFE53935)),
      PlanPriority.medium => ('보통', PlanFlowColors.active),
      PlanPriority.low => ('낮음', PlanFlowColors.primaryLight),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

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

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: PlanFlowColors.textSecondary),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: PlanFlowColors.textSecondary,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: valueColor ?? PlanFlowColors.textPrimary,
          ),
        ),
      ],
    );
  }
}
