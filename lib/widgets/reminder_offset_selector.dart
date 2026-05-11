import 'package:flutter/material.dart';

import '../core/theme.dart';

const String _noReminderSheetValue = 'no_reminder';

class ReminderOffsetSelector extends StatelessWidget {
  const ReminderOffsetSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.title = '일정 알림',
    this.subtitle = '이 일정에서만 사용할 알림 시간을 선택하세요.',
  });

  final Duration? value;
  final ValueChanged<Duration?> onChanged;
  final String title;
  final String subtitle;

  static const Duration defaultValue = Duration(minutes: 60);

  static const List<ReminderOffsetChoice> standardChoices =
      <ReminderOffsetChoice>[
    ReminderOffsetChoice(label: '알림 없음'),
    ReminderOffsetChoice(label: '정시', offset: Duration.zero),
    ReminderOffsetChoice(label: '10분 전', offset: Duration(minutes: 10)),
    ReminderOffsetChoice(label: '30분 전', offset: Duration(minutes: 30)),
    ReminderOffsetChoice(label: '1시간 전', offset: Duration(minutes: 60)),
    ReminderOffsetChoice(label: '2시간 전', offset: Duration(minutes: 120)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedLabel = _labelForValue(value);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openChoiceSheet(context),
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: Text(selectedLabel),
            ),
          ),
        ],
      ),
    );
  }

  String _labelForValue(Duration? selected) {
    for (final choice in standardChoices) {
      if (choice.offset == selected) {
        return choice.label;
      }
    }
    if (selected == null) {
      return '알림 없음';
    }
    return '${selected.inMinutes}분 전';
  }

  Future<void> _openChoiceSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '일정 알림 선택',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              for (final choice in standardChoices)
                ListTile(
                  leading: Icon(
                    (choice.offset ?? _noReminderSheetValue) ==
                            (value ?? _noReminderSheetValue)
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    color: PlanFlowColors.primary,
                  ),
                  title: Text(choice.label),
                  onTap: () => Navigator.of(context).pop(
                    choice.offset ?? _noReminderSheetValue,
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('직접 선택'),
                subtitle: value == null ? null : Text('${value!.inMinutes}분 전'),
                onTap: () async {
                  Navigator.of(context).pop(await _pickCustomMinutes(context));
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) {
      return;
    }
    if (picked == _noReminderSheetValue) {
      onChanged(null);
      return;
    }
    if (picked is Duration) {
      onChanged(picked);
    }
  }

  Future<Duration?> _pickCustomMinutes(BuildContext context) async {
    final controller = TextEditingController(
      text: value == null ? '60' : value!.inMinutes.toString(),
    );
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('알림 시간 직접 선택'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '몇 분 전에 알릴까요?',
            suffixText: '분 전',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              final minutes = int.tryParse(controller.text.trim());
              Navigator.of(context).pop(minutes);
            },
            child: const Text('적용'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (picked == null) {
      return null;
    }
    final normalized = picked.clamp(0, 24 * 60);
    return Duration(minutes: normalized);
  }
}

class ReminderOffsetChoice {
  const ReminderOffsetChoice({required this.label, this.offset});

  final String label;
  final Duration? offset;
}
