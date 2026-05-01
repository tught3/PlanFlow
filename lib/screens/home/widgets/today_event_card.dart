import 'package:flutter/material.dart';

import '../../../core/theme.dart';

enum TodayEventStatus {
  active,
  normal,
  done,
}

class TodayEventCard extends StatelessWidget {
  const TodayEventCard({
    super.key,
    required this.title,
    required this.timeRange,
    this.location,
    this.supplies = const <String>[],
    this.hasPreActions = false,
    this.isCritical = false,
    this.status = TodayEventStatus.normal,
  });

  final String title;
  final String timeRange;
  final String? location;
  final List<String> supplies;
  final bool hasPreActions;
  final bool isCritical;
  final TodayEventStatus status;

  bool get _isActive => status == TodayEventStatus.active;
  bool get _isDone => status == TodayEventStatus.done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = switch (status) {
      TodayEventStatus.active => PlanFlowColors.active,
      TodayEventStatus.normal => PlanFlowColors.surface,
      TodayEventStatus.done => PlanFlowColors.surfaceFaint,
    };
    final titleColor = switch (status) {
      TodayEventStatus.active => Colors.white,
      TodayEventStatus.normal => PlanFlowColors.textPrimary,
      TodayEventStatus.done => PlanFlowColors.textDisabled,
    };
    final timeColor = switch (status) {
      TodayEventStatus.active => PlanFlowColors.activeLight,
      TodayEventStatus.normal => PlanFlowColors.primaryMid,
      TodayEventStatus.done => PlanFlowColors.textDisabled,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: _isActive
            ? null
            : Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  timeRange,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: timeColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (_isActive) const _StatusBadge.active(),
                    if (_isDone) const _StatusBadge.done(),
                    if (isCritical && !_isDone)
                      _Tag(label: '중요', active: _isActive),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (location != null && location!.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Row(
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 14,
                  color: _isActive ? Colors.white70 : PlanFlowColors.primaryMid,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    location!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _isActive
                          ? Colors.white70
                          : PlanFlowColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (supplies.isNotEmpty || hasPreActions) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (supplies.isNotEmpty)
                  _Tag(label: '준비물 ${supplies.length}', active: _isActive),
                if (hasPreActions) _Tag(label: '사전 액션', active: _isActive),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge.active()
      : label = 'NOW',
        foreground = PlanFlowColors.active,
        background = Colors.white;

  const _StatusBadge.done()
      : label = '완료',
        foreground = PlanFlowColors.textDisabled,
        background = PlanFlowColors.tagDoneBg;

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? PlanFlowColors.tagActiveBg : PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: active
                  ? PlanFlowColors.tagActiveText
                  : PlanFlowColors.tagNormalText,
            ),
      ),
    );
  }
}
