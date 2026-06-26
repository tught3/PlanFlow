import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_event_model.dart';
import '../models/group_event_recurrence.dart';
import '../providers/group_event_provider.dart';
import '../providers/group_event_state.dart';

class GroupEventListScreen extends StatefulWidget {
  const GroupEventListScreen({
    super.key,
    GroupEventProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final GroupEventProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<GroupEventListScreen> createState() => _GroupEventListScreenState();
}

class _GroupEventListScreenState extends State<GroupEventListScreen> {
  late final GroupEventProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupEventProvider();
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
    await _provider.load(userId);
  }

  Future<void> _openCreateEvent() async {
    final result = await context.push<String>(AppRoutes.groupEventCreate);
    if (!mounted) {
      return;
    }
    if (result != null) {
      await _load();
    }
  }

  Future<void> _openDetail(GroupEventModel event) async {
    final result = await context.push<String>(
      '${AppRoutes.groupEvents}/${event.id}',
      extra: event,
    );
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
        final today = _provider.nowLocal();
        final todayEvents = _eventsForDay(state.events, today);
        final weekEvents = _eventsForWeek(state.events, today)
            .where((event) => !todayEvents.any((item) => item.id == event.id))
            .toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: const Text('그룹 일정'),
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
                _buildSelectedGroupCard(context, state),
                const SizedBox(height: 16),
                _buildPrimaryActionRow(context, state),
                if (state.error != null) ...[
                  const SizedBox(height: 16),
                  _buildErrorCard(context, state.error!),
                ],
                const SizedBox(height: 16),
                _buildEventSection(
                  context,
                  title: '오늘 일정',
                  subtitle: _dateLabel(today),
                  events: todayEvents,
                  emptyMessage: state.hasSelectedGroup
                      ? '오늘은 아직 그룹 일정이 없어요.'
                      : '그룹을 먼저 선택해 주세요.',
                ),
                const SizedBox(height: 16),
                _buildEventSection(
                  context,
                  title: '이번 주 일정',
                  subtitle: '오늘을 제외한 다음 일정들이 보여요.',
                  events: weekEvents,
                  emptyMessage: state.hasSelectedGroup
                      ? '이번 주에는 추가된 그룹 일정이 없어요.'
                      : '그룹을 먼저 선택해 주세요.',
                ),
                if (!state.hasSelectedGroup) ...[
                  const SizedBox(height: 16),
                  _buildEmptyGroupCard(context),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedGroupCard(BuildContext context, GroupEventState state) {
    final selectedGroup = state.selectedGroup;
    final title = selectedGroup?.name ?? '선택된 그룹이 없어요';
    final subtitle = selectedGroup == null
        ? '그룹을 선택한 뒤에 일정 목록이 보여요.'
        : state.isLeaderOfSelectedGroup
            ? '현재 선택 그룹의 리더 권한이 있어요.'
            : '현재 선택 그룹의 멤버 권한으로 일정을 보고 있어요.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.event_note_outlined),
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
                  _InfoChip(label: _groupStatusLabel(selectedGroup.status)),
                if (state.canCreateEvent)
                  _InfoChip(
                    label: '일정 생성 가능',
                    backgroundColor: PlanFlowColors.tagDoneBg,
                    textColor: PlanFlowColors.tagDoneText,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryActionRow(BuildContext context, GroupEventState state) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('group-event-list-create-button'),
            onPressed: state.canCreateEvent ? _openCreateEvent : null,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('새 그룹 일정'),
          ),
        ),
      ],
    );
  }

  Widget _buildEventSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<GroupEventModel> events,
    required String emptyMessage,
  }) {
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
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (events.isEmpty)
              _buildEmptySection(context, emptyMessage)
            else
              Column(
                children: [
                  for (final event in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _GroupEventListTile(
                        key: ValueKey<String>('group-event-item-${event.id}'),
                        event: event,
                        onTap: () => _openDetail(event),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySection(BuildContext context, String message) {
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
            message,
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
        child: Text(
          error,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7A271A),
              ),
        ),
      ),
    );
  }

  Widget _buildEmptyGroupCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.groups_2_outlined,
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
              '그룹을 먼저 선택하면 일정 목록이 보여요.',
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

  List<GroupEventModel> _eventsForDay(
      List<GroupEventModel> events, DateTime day) {
    return events
        .where((event) => groupEventOccursOnLocalDay(event, day))
        .toList(growable: false);
  }

  List<GroupEventModel> _eventsForWeek(
      List<GroupEventModel> events, DateTime day) {
    final weekStart = DateTime(day.year, day.month, day.day)
        .subtract(Duration(days: day.weekday - DateTime.monday));
    return events.where((event) {
      for (var offset = 0; offset < 7; offset++) {
        final weekDay = weekStart.add(Duration(days: offset));
        if (groupEventOccursOnLocalDay(event, weekDay)) {
          return true;
        }
      }
      return false;
    }).toList(growable: false);
  }

  String _dateLabel(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')} (${_weekdayLabel(date.weekday)})';
  }

  String _weekdayLabel(int weekday) {
    return switch (weekday) {
      DateTime.monday => '월',
      DateTime.tuesday => '화',
      DateTime.wednesday => '수',
      DateTime.thursday => '목',
      DateTime.friday => '금',
      DateTime.saturday => '토',
      _ => '일',
    };
  }

  String _groupStatusLabel(String status) {
    return switch (status) {
      'active' => '활성',
      'archived' => '보관됨',
      'deleted_pending' => '삭제 대기',
      _ => status,
    };
  }
}

class _GroupEventListTile extends StatelessWidget {
  const _GroupEventListTile({
    super.key,
    required this.event,
    required this.onTap,
  });

  final GroupEventModel event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final localStart = planflowLocal(event.startAt);
    final localEnd = planflowLocal(event.endAt);
    final timeLabel = event.allDay
        ? '종일'
        : localStart.year == localEnd.year &&
                localStart.month == localEnd.month &&
                localStart.day == localEnd.day
            ? '${_timeLabel(context, localStart)} - ${_timeLabel(context, localEnd)}'
            : '${_dateLabel(localStart)} ${_timeLabel(context, localStart)} - ${_dateLabel(localEnd)} ${_timeLabel(context, localEnd)}';

    return Card(
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                timeLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              if ((event.location ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  event.location!.trim(),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (event.allDay)
                    _InfoChip(
                      label: '종일',
                      backgroundColor: PlanFlowColors.tagDoneBg,
                      textColor: PlanFlowColors.tagDoneText,
                    ),
                  _InfoChip(label: _recurrenceLabel(event.recurrenceType)),
                ],
              ),
            ],
          ),
        ),
      ),
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

  String _recurrenceLabel(String recurrenceType) {
    return switch (recurrenceType) {
      'none' => '반복 없음',
      'daily' => '매일 반복',
      'weekly' => '매주 반복',
      'monthly' => '매월 반복',
      _ => recurrenceType,
    };
  }

  String _timeLabel(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: false,
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
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
