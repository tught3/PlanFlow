import 'package:flutter/material.dart';

import '../core/theme.dart';

class RecurrenceSelection {
  const RecurrenceSelection({
    this.frequency = 'none',
    this.until,
    this.preservedParts = const <String>[],
  });

  final String frequency;
  final DateTime? until;
  final List<String> preservedParts;

  bool get isNone => frequency == 'none';

  String? toRRule() {
    if (isNone) {
      return null;
    }
    final freq = switch (frequency) {
      'daily' => 'DAILY',
      'weekly' => 'WEEKLY',
      'monthly' => 'MONTHLY',
      'yearly' => 'YEARLY',
      _ => null,
    };
    if (freq == null) {
      return null;
    }
    final parts = <String>[
      'FREQ=$freq',
      ...preservedParts.where(
        (part) {
          final normalized = part.toUpperCase();
          return !normalized.startsWith('FREQ=') &&
              !normalized.startsWith('UNTIL=');
        },
      ),
    ];
    final end = until;
    if (end != null) {
      final y = end.year.toString().padLeft(4, '0');
      final m = end.month.toString().padLeft(2, '0');
      final d = end.day.toString().padLeft(2, '0');
      parts.add('UNTIL=${[y, m, d].join()}T235959Z');
    }
    return parts.join(';');
  }

  RecurrenceSelection copyWith({
    String? frequency,
    DateTime? until,
    bool clearUntil = false,
    List<String>? preservedParts,
  }) {
    return RecurrenceSelection(
      frequency: frequency ?? this.frequency,
      until: clearUntil ? null : until ?? this.until,
      preservedParts: preservedParts ?? this.preservedParts,
    );
  }

  static RecurrenceSelection fromRRule(String? rule) {
    final normalized = rule?.toUpperCase().trim();
    if (normalized == null || normalized.isEmpty) {
      return const RecurrenceSelection();
    }
    final freq = RegExp(r'FREQ=([A-Z]+)').firstMatch(normalized)?.group(1);
    final frequency = switch (freq) {
      'DAILY' => 'daily',
      'WEEKLY' => 'weekly',
      'MONTHLY' => 'monthly',
      'YEARLY' => 'yearly',
      _ => 'none',
    };
    final untilRaw =
        RegExp(r'UNTIL=([0-9TzZ]+)').firstMatch(normalized)?.group(1);
    final preservedParts = normalized
        .split(';')
        .map((part) => part.trim())
        .where((part) =>
            part.isNotEmpty &&
            !part.startsWith('FREQ=') &&
            !part.startsWith('UNTIL='))
        .toList(growable: false);
    return RecurrenceSelection(
      frequency: frequency,
      until: _parseUntil(untilRaw),
      preservedParts: preservedParts,
    );
  }

  static DateTime? _parseUntil(String? value) {
    if (value == null || value.length < 8) {
      return null;
    }
    final digits = value.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length < 8) {
      return null;
    }
    final year = int.tryParse(digits.substring(0, 4));
    final month = int.tryParse(digits.substring(4, 6));
    final day = int.tryParse(digits.substring(6, 8));
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day);
  }
}

class RecurrenceSelector extends StatelessWidget {
  const RecurrenceSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final RecurrenceSelection value;
  final ValueChanged<RecurrenceSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '반복',
          style: theme.textTheme.titleSmall?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const <(String, String)>[
            ('none', '반복 안 함'),
            ('daily', '매일'),
            ('weekly', '매주'),
            ('monthly', '매월'),
            ('yearly', '매년'),
          ].map((item) {
            final selected = value.frequency == item.$1;
            return ChoiceChip(
              label: Text(item.$2),
              selected: selected,
              onSelected: (_) {
                onChanged(
                  value.copyWith(
                    frequency: item.$1,
                    clearUntil: item.$1 == 'none',
                  ),
                );
              },
            );
          }).toList(growable: false),
        ),
        if (!value.isNone) ...[
          const SizedBox(height: 10),
          if (value.frequency == 'weekly') ...[
            _WeeklyByDaySelector(
              value: value,
              onChanged: onChanged,
            ),
            const SizedBox(height: 10),
          ],
          if (value.frequency == 'monthly') ...[
            _RecurrenceSummary(
              text: _monthlySummary(value),
            ),
            const SizedBox(height: 10),
          ],
          if (value.preservedParts.isNotEmpty &&
              value.frequency != 'weekly' &&
              value.frequency != 'monthly') ...[
            _RecurrenceSummary(text: value.preservedParts.join(' · ')),
            const SizedBox(height: 10),
          ],
          OutlinedButton.icon(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: value.until ?? now.add(const Duration(days: 30)),
                firstDate: now.subtract(const Duration(days: 1)),
                lastDate: now.add(const Duration(days: 365 * 5)),
              );
              if (picked != null) {
                onChanged(value.copyWith(until: picked));
              }
            },
            icon: const Icon(Icons.event_repeat_outlined),
            label: Text(
              value.until == null
                  ? '종료일 선택'
                  : '종료일 ${MaterialLocalizations.of(context).formatShortDate(value.until!)}',
            ),
          ),
        ],
      ],
    );
  }
}

class _WeeklyByDaySelector extends StatelessWidget {
  const _WeeklyByDaySelector({
    required this.value,
    required this.onChanged,
  });

  final RecurrenceSelection value;
  final ValueChanged<RecurrenceSelection> onChanged;

  static const _days = <(String, String)>[
    ('MO', '월'),
    ('TU', '화'),
    ('WE', '수'),
    ('TH', '목'),
    ('FR', '금'),
    ('SA', '토'),
    ('SU', '일'),
  ];

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDays(value);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: _days.map((day) {
        final isSelected = selected.contains(day.$1);
        return FilterChip(
          label: Text(day.$2),
          selected: isSelected,
          onSelected: (_) {
            final next = Set<String>.from(selected);
            if (isSelected) {
              next.remove(day.$1);
            } else {
              next.add(day.$1);
            }
            onChanged(
              value.copyWith(
                preservedParts: _replaceByDay(value.preservedParts, next),
              ),
            );
          },
        );
      }).toList(growable: false),
    );
  }

  static Set<String> _selectedDays(RecurrenceSelection value) {
    final byDay =
        value.preservedParts.map((part) => part.toUpperCase()).firstWhere(
              (part) => part.startsWith('BYDAY='),
              orElse: () => '',
            );
    if (byDay.isEmpty) {
      return <String>{};
    }
    return byDay
        .replaceFirst('BYDAY=', '')
        .split(',')
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  static List<String> _replaceByDay(
    List<String> parts,
    Set<String> days,
  ) {
    final next = parts
        .where((part) => !part.toUpperCase().startsWith('BYDAY='))
        .toList();
    if (days.isNotEmpty) {
      const order = <String>['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
      final sorted = order.where(days.contains).join(',');
      next.add('BYDAY=$sorted');
    }
    return next;
  }
}

class _RecurrenceSummary extends StatelessWidget {
  const _RecurrenceSummary({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryFaint.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: PlanFlowColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _monthlySummary(RecurrenceSelection value) {
  final parts = value.preservedParts.map((part) => part.toUpperCase()).toList();
  final byMonthDay = parts.firstWhere(
    (part) => part.startsWith('BYMONTHDAY='),
    orElse: () => '',
  );
  if (byMonthDay.isNotEmpty) {
    return '날짜 기준: 매월 ${byMonthDay.replaceFirst('BYMONTHDAY=', '')}일';
  }
  final byDay = parts.firstWhere(
    (part) => part.startsWith('BYDAY='),
    orElse: () => '',
  );
  if (byDay.isNotEmpty) {
    return '요일 기준: ${byDay.replaceFirst('BYDAY=', '')}';
  }
  return '매월 반복합니다. 음성으로 “매월 15일” 또는 “매월 첫 번째 월요일”처럼 말하면 더 구체적으로 저장됩니다.';
}
