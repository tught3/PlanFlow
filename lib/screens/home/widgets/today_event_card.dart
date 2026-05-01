import 'package:flutter/material.dart';

import '../../../core/constants.dart';

class TodayEventCard extends StatelessWidget {
  const TodayEventCard({
    super.key,
    required this.title,
    required this.timeRange,
    this.location,
    this.isCritical = false,
  });

  final String title;
  final String timeRange;
  final String? location;
  final bool isCritical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
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
                    label: Text('중요'),
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
          ],
        ),
      ),
    );
  }
}
