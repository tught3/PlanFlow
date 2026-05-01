import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final monthLabel = DateFormat('MMMM yyyy').format(today);
    final dateLabel = DateFormat('EEEE, MMM d').format(today);
    const upcomingItems = <_CalendarAgendaItem>[
      _CalendarAgendaItem(
        timeRange: '09:00 - 09:30',
        title: 'Sprint sync',
        description: 'Review priorities and unblock the morning agenda.',
        accentIcon: Icons.groups_outlined,
      ),
      _CalendarAgendaItem(
        timeRange: '11:00 - 11:45',
        title: 'Client follow-up',
        description: 'Confirm action items and next delivery milestones.',
        accentIcon: Icons.call_outlined,
      ),
      _CalendarAgendaItem(
        timeRange: '15:30 - 16:00',
        title: 'Plan review',
        description: 'Check the schedule and prepare for tomorrow.',
        accentIcon: Icons.event_available_outlined,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.voice),
        icon: const Icon(Icons.mic_none),
        label: const Text('Voice input'),
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
                Text('Upcoming', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${upcomingItems.length}',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => context.go(AppRoutes.voice),
                  icon: const Icon(Icons.mic_none),
                  label: const Text('Capture'),
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
              child: Padding(
                padding: const EdgeInsets.all(AppConstants.defaultPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.calendar_month_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Month overview',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'This placeholder keeps the screen useful until live calendar loading is connected.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            monthLabel,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
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
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.secondaryContainer,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Today',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dateLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            monthLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer.withValues(
                alpha: 0.85,
              ),
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
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                item.accentIcon,
                color: theme.colorScheme.onPrimaryContainer,
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
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(item.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    item.description,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
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
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text('No upcoming items yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Use voice input to add a meeting, task, or reminder and it will appear here.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.voice),
              icon: const Icon(Icons.mic_none),
              label: const Text('Start voice input'),
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
