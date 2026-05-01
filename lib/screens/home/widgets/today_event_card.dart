import 'package:flutter/material.dart';

import '../../../core/constants.dart';

class TodayEventCard extends StatelessWidget {
  const TodayEventCard({
    super.key,
    required this.title,
    required this.timeRange,
    this.location,
    this.supplies = const <String>[],
    this.hasPreActions = false,
    this.isCritical = false,
  });

  final String title;
  final String timeRange;
  final String? location;
  final List<String> supplies;
  final bool hasPreActions;
  final bool isCritical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (isCritical)
                  const Chip(
                    avatar: Icon(Icons.priority_high, size: 16),
                    label: Text('Critical'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(timeRange),
            if (location != null) ...[
              const SizedBox(height: 4),
              Text(
                location!,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (supplies.isNotEmpty || hasPreActions) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (supplies.isNotEmpty)
                    Chip(
                      avatar: const Icon(Icons.work_outline, size: 16),
                      label: Text('${supplies.length} supplies'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (hasPreActions)
                    const Chip(
                      avatar: Icon(Icons.checklist, size: 16),
                      label: Text('Pre-actions'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
