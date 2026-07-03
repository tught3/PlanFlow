import 'package:flutter/material.dart';

import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../models/group_event_model.dart';
import '../providers/group_dashboard_provider.dart';
import '../repositories/group_dashboard_repository.dart' show MemberShareStat;

/// 멤버별 공유 현황 카드에서 멤버 행을 탭했을 때 뜨는 바텀시트.
///
/// 기본은 최근 7일간 그 멤버가 공유한 그룹 일정을 보여주고,
/// "기간 변경" 버튼으로 임의 날짜 범위를 선택할 수 있다.
class MemberSharedEventsSheet extends StatefulWidget {
  const MemberSharedEventsSheet({
    super.key,
    required this.provider,
    required this.stat,
    DateTime Function()? nowProvider,
  }) : _nowProvider = nowProvider ?? planflowNow;

  final GroupDashboardProvider provider;
  final MemberShareStat stat;
  final DateTime Function() _nowProvider;

  @override
  State<MemberSharedEventsSheet> createState() =>
      _MemberSharedEventsSheetState();
}

class _MemberSharedEventsSheetState extends State<MemberSharedEventsSheet> {
  late DateTime _rangeStart;
  late DateTime _rangeEnd;
  bool _isLoading = true;
  String? _error;
  List<GroupEventModel> _events = const <GroupEventModel>[];

  @override
  void initState() {
    super.initState();
    final today = planflowLocalDay(widget._nowProvider());
    _rangeEnd = today;
    _rangeStart = today.subtract(const Duration(days: 6));
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final events = await widget.provider.fetchMemberEvents(
        memberUserId: widget.stat.userId,
        from: _rangeStart,
        to: _rangeEnd.add(const Duration(days: 1)),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _events = events;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _pickCustomRange() async {
    final now = planflowLocalDay(widget._nowProvider());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: DateTimeRange(start: _rangeStart, end: _rangeEnd),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _rangeStart = DateTime(picked.start.year, picked.start.month, picked.start.day);
      _rangeEnd = DateTime(picked.end.year, picked.end.month, picked.end.day);
    });
    await _load();
  }

  bool get _isDefaultRange {
    final today = planflowLocalDay(widget._nowProvider());
    final defaultStart = today.subtract(const Duration(days: 6));
    return _rangeStart == defaultStart && _rangeEnd == today;
  }

  String get _rangeLabel {
    if (_isDefaultRange) {
      return '최근 7일';
    }
    return '${_shortDateLabel(_rangeStart)} - ${_shortDateLabel(_rangeEnd)}';
  }

  String _shortDateLabel(DateTime value) {
    return '${value.month}월 ${value.day}일';
  }

  @override
  Widget build(BuildContext context) {
    final stat = widget.stat;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    stat.displayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                _RoleBadge(isLeader: stat.isLeader),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _rangeLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PlanFlowColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('member-shared-events-range-button'),
                  onPressed: _pickCustomRange,
                  icon: const Icon(Icons.date_range_outlined, size: 18),
                  label: const Text('기간 변경'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: _buildBody(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          '일정을 불러오지 못했어요.\n$_error',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
        ),
      );
    }
    if (_events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 36,
              color: PlanFlowColors.primaryLight,
            ),
            const SizedBox(height: 8),
            Text(
              '이 기간에 공유한 일정이 없어요.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _events.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final event = _events[index];
        return _MemberEventRow(
          key: ValueKey<String>('member-shared-event-${event.id}'),
          event: event,
        );
      },
    );
  }
}

class _MemberEventRow extends StatelessWidget {
  const _MemberEventRow({super.key, required this.event});

  final GroupEventModel event;

  @override
  Widget build(BuildContext context) {
    final localStart = planflowLocal(event.startAt);
    return Container(
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            event.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            _dateTimeLabel(context, localStart, event.allDay),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }

  String _dateTimeLabel(BuildContext context, DateTime value, bool allDay) {
    const weekdayLabels = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdayLabels[value.weekday - 1];
    final datePart = '${value.month}월 ${value.day}일 ($weekday)';
    if (allDay) {
      return datePart;
    }
    final timeLabel = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: false,
    );
    return '$datePart $timeLabel';
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.isLeader});

  final bool isLeader;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:
            isLeader ? PlanFlowColors.primaryFaint : PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isLeader ? '리더' : '멤버',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color:
                  isLeader ? PlanFlowColors.primary : PlanFlowColors.tagNormalText,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
