import 'package:flutter/material.dart';

import '../core/local_time.dart';
import '../core/theme.dart';
import '../data/models/event_model.dart';

Future<bool> showOverlapWarningDialog({
  required BuildContext context,
  required List<EventModel> overlappingEvents,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('일정이 겹쳐요'),
      content: _OverlapWarningContent(overlappingEvents: overlappingEvents),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('중단'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('계속 저장'),
              ),
            ),
          ],
        ),
      ],
    ),
  ).then((value) => value ?? false);
}

class _OverlapWarningContent extends StatelessWidget {
  const _OverlapWarningContent({required this.overlappingEvents});

  final List<EventModel> overlappingEvents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = overlappingEvents.length;

    return SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1
                ? '아래 기존 일정과 시간이 겹칩니다. 같은 일정인지 확인해 주세요.'
                : '아래 기존 일정 $count개와 시간이 겹칩니다. 같은 일정인지 확인해 주세요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Column(
                children: overlappingEvents
                    .map((event) => _OverlapEventTile(event: event))
                    .toList(growable: false),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '그래도 새 일정으로 저장하려면 계속 저장을 눌러 주세요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlapEventTile extends StatelessWidget {
  const _OverlapEventTile({required this.event});

  final EventModel event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = event.location?.trim();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            event.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatEventRange(event),
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          if (location != null && location.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              location,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatEventRange(EventModel event) {
  final startAt = event.startAt;
  if (startAt == null) {
    return '시간 미정';
  }

  final localStart = planflowLocal(startAt);
  final startLabel =
      '${localStart.month}/${localStart.day} ${_twoDigits(localStart.hour)}:${_twoDigits(localStart.minute)}';
  final endAt = event.endAt;
  if (endAt == null) {
    return startLabel;
  }

  final localEnd = planflowLocal(endAt);
  if (DateUtils.isSameDay(localStart, localEnd)) {
    return '$startLabel-${_twoDigits(localEnd.hour)}:${_twoDigits(localEnd.minute)}';
  }
  return '$startLabel-${localEnd.month}/${localEnd.day} ${_twoDigits(localEnd.hour)}:${_twoDigits(localEnd.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
