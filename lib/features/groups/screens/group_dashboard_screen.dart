import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_event_model.dart';
import '../providers/group_dashboard_provider.dart';
import '../providers/group_dashboard_state.dart';

class GroupDashboardScreen extends StatefulWidget {
  const GroupDashboardScreen({
    super.key,
    GroupDashboardProvider? provider,
    String? currentUserIdOverride,
    String? initialGroupId,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride,
        _initialGroupId = initialGroupId;

  final GroupDashboardProvider? _provider;
  final String? _currentUserIdOverride;
  final String? _initialGroupId;

  @override
  State<GroupDashboardScreen> createState() => _GroupDashboardScreenState();
}

class _GroupDashboardScreenState extends State<GroupDashboardScreen> {
  late final GroupDashboardProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupDashboardProvider();
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
    await _provider.load(userId, preferredGroupId: widget._initialGroupId);
  }

  Future<void> _openGroupList() async {
    final result = await context.push<String>(AppRoutes.groups);
    if (!mounted) {
      return;
    }
    if (result != null) {
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
            title: const Text('그룹 대시보드'),
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
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _buildCurrentGroupCard(context, state),
                const SizedBox(height: 16),
                if (state.error != null) ...[
                  _buildErrorCard(context, state.error!),
                  const SizedBox(height: 16),
                ],
                if (state.isLoading && !state.hasSelectedGroup) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (!state.hasSelectedGroup) ...[
                  _buildEmptyState(context),
                ] else ...[
                  _buildMetricsGrid(context, state),
                  const SizedBox(height: 16),
                  _buildUpcomingEventsCard(context, state),
                ],
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('group-dashboard-group-list-button'),
                  onPressed: _openGroupList,
                  icon: const Icon(Icons.groups_2_outlined),
                  label: const Text('그룹 선택'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCurrentGroupCard(
    BuildContext context,
    GroupDashboardState state,
  ) {
    final selectedGroup = state.selectedGroup;
    final title = selectedGroup?.name ?? '선택된 그룹이 없어요';
    final subtitle = selectedGroup == null
        ? '현재는 개인 모드예요.'
        : state.isLeaderOfSelectedGroup
            ? '이 그룹의 리더 권한으로 대시보드를 보고 있어요.'
            : '현재 선택된 그룹의 대시보드예요.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dashboard_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '현재 그룹',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (state.isLoading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(
                  label: state.isPersonalMode ? '개인 모드' : '팀 모드',
                  backgroundColor: state.isPersonalMode
                      ? PlanFlowColors.tagDoneBg
                      : PlanFlowColors.primaryFaint,
                  textColor: state.isPersonalMode
                      ? PlanFlowColors.tagDoneText
                      : PlanFlowColors.primary,
                ),
                if (selectedGroup != null)
                  _InfoChip(
                    label: state.selectedGroupRole == 'leader' ? '리더' : '멤버',
                  ),
                if (selectedGroup != null)
                  _InfoChip(label: _statusLabel(selectedGroup.status)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsGrid(
    BuildContext context,
    GroupDashboardState state,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                title: '오늘 일정',
                value: state.todayEventCount.toString(),
                icon: Icons.today_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                title: '이번 주 일정',
                value: state.weekEventCount.toString(),
                icon: Icons.date_range_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                title: '멤버 수',
                value: state.memberCount.toString(),
                icon: Icons.groups_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                title: '다가오는 일정',
                value: state.upcomingEvents.length.toString(),
                icon: Icons.event_available_outlined,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUpcomingEventsCard(
    BuildContext context,
    GroupDashboardState state,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '다가오는 일정',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text(
                  '최대 최근 일정 중심',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.upcomingEvents.isEmpty)
              _buildEmptyUpcomingState(context)
            else
              Column(
                children: [
                  for (final event in state.upcomingEvents.take(5))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _UpcomingEventTile(
                        key: ValueKey<String>(
                            'group-dashboard-event-${event.id}'),
                        event: event,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 40,
              color: PlanFlowColors.primaryLight,
            ),
            const SizedBox(height: 12),
            Text(
              '선택된 그룹이 없어요',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '그룹을 선택하면 오늘 일정, 멤버 수, 다가오는 일정을 한눈에 볼 수 있어요.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyUpcomingState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: 36,
            color: PlanFlowColors.primaryLight,
          ),
          const SizedBox(height: 8),
          Text(
            '다가오는 일정이 아직 없어요.',
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
      color: const Color(0xFFFFF3F0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFB42318)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '대시보드를 불러오지 못했어요',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF7A271A),
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF7A271A),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(String status) {
    return switch (status) {
      'active' => '활성',
      'archived' => '보관됨',
      'deleted_pending' => '삭제 대기',
      _ => status,
    };
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: PlanFlowColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PlanFlowColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpcomingEventTile extends StatelessWidget {
  const _UpcomingEventTile({
    super.key,
    required this.event,
  });

  final GroupEventModel event;

  @override
  Widget build(BuildContext context) {
    final localStart = planflowLocal(event.startAt);
    final localEnd = planflowLocal(event.endAt);
    return Container(
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  event.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              _InfoChip(label: _statusLabel(event.status)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.allDay
                ? _dateLabel(localStart)
                : '${_dateLabel(localStart)} ${_timeLabel(context, localStart)} - ${_dateLabel(localEnd)} ${_timeLabel(context, localEnd)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
          if ((event.location ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              event.location!.trim(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
  }

  String _timeLabel(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: false,
    );
  }

  String _statusLabel(String status) {
    return switch (status) {
      'active' => '활성',
      'cancelled' => '취소됨',
      'archived' => '보관됨',
      _ => status,
    };
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    this.backgroundColor = PlanFlowColors.tagNormalBg,
    this.textColor = PlanFlowColors.tagNormalText,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
