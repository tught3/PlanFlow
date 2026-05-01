import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../widgets/planflow_voice_fab.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final monthLabel = '${today.year}년 ${today.month}월';
    final dateLabel = _koreanDateLabel(today);
    const upcomingItems = <_CalendarAgendaItem>[
      _CalendarAgendaItem(
        timeRange: '09:00 - 09:30',
        title: '아침 일정 점검',
        description: '오늘 우선순위를 확인하고 필요한 준비를 정리합니다.',
        accentIcon: Icons.groups_outlined,
      ),
      _CalendarAgendaItem(
        timeRange: '11:00 - 11:45',
        title: '후속 연락',
        description: '다음 액션과 전달 일정을 확인합니다.',
        accentIcon: Icons.call_outlined,
      ),
      _CalendarAgendaItem(
        timeRange: '15:30 - 16:00',
        title: '계획 검토',
        description: '남은 일정을 확인하고 내일 준비를 시작합니다.',
        accentIcon: Icons.event_available_outlined,
      ),
    ];

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: const Text('일정')),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.go(AppRoutes.voice),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            _DateHeaderCard(
              monthLabel: monthLabel,
              dateLabel: dateLabel,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('다가오는 일정', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.surface,
                    border: Border.all(color: PlanFlowColors.primaryFaint),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${upcomingItems.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: PlanFlowColors.primaryMid,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => context.go(AppRoutes.voice),
                  icon: const Icon(Icons.mic_none),
                  label: const Text('음성 추가'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (upcomingItems.isEmpty)
              const _EmptyAgendaCard()
            else
              ...upcomingItems.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AgendaItemCard(item: item),
                ),
              ),
            const SizedBox(height: 8),
            Card(
              color: PlanFlowColors.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(
                  color: PlanFlowColors.primaryFaint,
                  width: 0.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.calendar_month_outlined,
                      color: PlanFlowColors.primaryMid,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '월간 보기',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: PlanFlowColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '실시간 캘린더 연동 전까지 오늘 기준 샘플 일정을 보여줍니다.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            monthLabel,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: PlanFlowColors.primaryMid,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }
}

class _DateHeaderCard extends StatelessWidget {
  const _DateHeaderCard({
    required this.monthLabel,
    required this.dateLabel,
  });

  final String monthLabel;
  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryMid,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '오늘',
            style: theme.textTheme.labelLarge?.copyWith(
              color: const Color(0xFFA8D4F0),
              fontSize: 9,
              letterSpacing: 0.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dateLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            monthLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgendaItemCard extends StatelessWidget {
  const _AgendaItemCard({required this.item});

  final _CalendarAgendaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: PlanFlowColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                item.accentIcon,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.timeRange,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: PlanFlowColors.primaryMid,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
          ],
        ),
      ),
    );
  }
}

class _EmptyAgendaCard extends StatelessWidget {
  const _EmptyAgendaCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surfaceFaint,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 40,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(height: 12),
            Text('아직 예정된 일정이 없어요', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '음성으로 회의, 할 일, 알림을 추가하면 이곳에 표시됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.voice),
              icon: const Icon(Icons.mic_none),
              label: const Text('음성 입력 시작'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarAgendaItem {
  const _CalendarAgendaItem({
    required this.timeRange,
    required this.title,
    required this.description,
    required this.accentIcon,
  });

  final String timeRange;
  final String title;
  final String description;
  final IconData accentIcon;
}
