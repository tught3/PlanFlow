import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'planflow_action_buttons.dart';

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
            '반복',
            style: theme.textTheme.titleSmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _recurrenceSubtitle(value),
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openRecurrenceSheet(context),
              icon: const Icon(Icons.event_repeat_outlined),
              label: Text(_frequencyLabel(value.frequency)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openRecurrenceSheet(BuildContext context) {
    var draft = value;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void update(RecurrenceSelection next) {
            setModalState(() => draft = next);
            onChanged(next);
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '반복 선택',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: PlanFlowColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 8),
                    for (final item in _frequencyChoices)
                      ListTile(
                        leading: Icon(
                          draft.frequency == item.$1
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: PlanFlowColors.primary,
                        ),
                        title: Text(item.$2),
                        onTap: () {
                          update(
                            draft.copyWith(
                              frequency: item.$1,
                              clearUntil: item.$1 == 'none',
                            ),
                          );
                        },
                      ),
                    if (!draft.isNone) ...[
                      const SizedBox(height: 8),
                      if (draft.frequency == 'weekly') ...[
                        _WeeklyByDaySelector(
                          value: draft,
                          onChanged: update,
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (draft.frequency == 'monthly') ...[
                        _MonthlyRecurrenceSelector(
                          value: draft,
                          onChanged: update,
                        ),
                        const SizedBox(height: 10),
                        _RecurrenceSummary(text: _monthlySummary(draft)),
                        const SizedBox(height: 10),
                      ],
                      if (draft.preservedParts.isNotEmpty &&
                          draft.frequency != 'weekly' &&
                          draft.frequency != 'monthly') ...[
                        _RecurrenceSummary(
                            text: draft.preservedParts.join(' · ')),
                        const SizedBox(height: 10),
                      ],
                      OutlinedButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: draft.until ??
                                now.add(const Duration(days: 30)),
                            firstDate: now.subtract(const Duration(days: 1)),
                            lastDate: now.add(const Duration(days: 365 * 5)),
                          );
                          if (picked != null) {
                            update(draft.copyWith(until: picked));
                          }
                        },
                        icon: const Icon(Icons.event_repeat_outlined),
                        label: Text(
                          draft.until == null
                              ? '종료일 선택'
                              : '종료일 ${MaterialLocalizations.of(context).formatShortDate(draft.until!)}',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    PlanFlowActionButtons(
                      buttons: [
                        PlanFlowActionButton(
                          label: '완료',
                          onPressed: () => Navigator.of(context).pop(),
                          type: ActionButtonType.primary,
                          flex: 1,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

const _frequencyChoices = <(String, String)>[
  ('none', '반복 안 함'),
  ('daily', '매일'),
  ('weekly', '매주'),
  ('monthly', '매월'),
  ('yearly', '매년'),
];

String _frequencyLabel(String frequency) {
  for (final item in _frequencyChoices) {
    if (item.$1 == frequency) {
      return item.$2;
    }
  }
  return '반복 안 함';
}

String _recurrenceSubtitle(RecurrenceSelection value) {
  if (value.isNone) {
    return '반복이 필요한 일정만 선택하세요.';
  }
  final until = value.until;
  if (until == null) {
    return '${_frequencyLabel(value.frequency)} 반복';
  }
  return '${_frequencyLabel(value.frequency)} 반복 · ${until.year}.${until.month}.${until.day}까지';
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

enum _MonthlyRecurrenceMode {
  dayOfMonth,
  weekdayOrdinal,
}

class _MonthlyRecurrenceSelector extends StatelessWidget {
  const _MonthlyRecurrenceSelector({
    required this.value,
    required this.onChanged,
  });

  final RecurrenceSelection value;
  final ValueChanged<RecurrenceSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final mode = _monthlyMode(value);
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryFaint.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '매월 반복 방식',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('날짜'),
                selected: mode == _MonthlyRecurrenceMode.dayOfMonth,
                onSelected: (_) => onChanged(
                  _setMonthlyMode(
                    value,
                    _MonthlyRecurrenceMode.dayOfMonth,
                  ),
                ),
              ),
              ChoiceChip(
                label: const Text('요일'),
                selected: mode == _MonthlyRecurrenceMode.weekdayOrdinal,
                onSelected: (_) => onChanged(
                  _setMonthlyMode(
                    value,
                    _MonthlyRecurrenceMode.weekdayOrdinal,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (mode == _MonthlyRecurrenceMode.dayOfMonth) ...[
            _MonthlyDaySelector(
              value: value,
              onChanged: onChanged,
            ),
          ] else ...[
            _MonthlyOrdinalWeekdaySelector(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthlyDaySelector extends StatelessWidget {
  const _MonthlyDaySelector({
    required this.value,
    required this.onChanged,
  });

  final RecurrenceSelection value;
  final ValueChanged<RecurrenceSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedDay = _selectedMonthlyDay(value);
    return Row(
      children: [
        Text(
          '매월',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: selectedDay,
          underline: const SizedBox.shrink(),
          items: List.generate(
            31,
            (index) => index + 1,
          ).map((day) {
            return DropdownMenuItem<int>(
              value: day,
              child: Text('$day일'),
            );
          }).toList(growable: false),
          onChanged: (day) {
            if (day == null) {
              return;
            }
            onChanged(_setMonthlyDay(value, day));
          },
        ),
      ],
    );
  }
}

class _MonthlyOrdinalWeekdaySelector extends StatelessWidget {
  const _MonthlyOrdinalWeekdaySelector({
    required this.value,
    required this.onChanged,
  });

  final RecurrenceSelection value;
  final ValueChanged<RecurrenceSelection> onChanged;

  static const _orders = <(int, String)>[
    (1, '첫째'),
    (2, '둘째'),
    (3, '셋째'),
    (4, '넷째'),
    (-1, '마지막'),
  ];

  static const _weekdays = <(String, String)>[
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
    final selected = _selectedMonthlyOrdinal(value);
    final selectedOrder = selected.order;
    final selectedWeekday = selected.weekday;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final order in _orders)
              ChoiceChip(
                label: Text(order.$2),
                selected: selectedOrder == order.$1,
                onSelected: (_) {
                  onChanged(
                    _setMonthlyOrdinal(
                      value,
                      order: order.$1,
                      weekday: selectedWeekday,
                    ),
                  );
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final weekday in _weekdays)
              FilterChip(
                label: Text(weekday.$2),
                selected: selectedWeekday == weekday.$1,
                onSelected: (_) {
                  onChanged(
                    _setMonthlyOrdinal(
                      value,
                      order: selectedOrder,
                      weekday: weekday.$1,
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );
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
    return '매월 ${byMonthDay.replaceFirst('BYMONTHDAY=', '')}일 반복';
  }
  final byDay = parts.firstWhere(
    (part) => part.startsWith('BYDAY='),
    orElse: () => '',
  );
  if (byDay.isNotEmpty) {
    final tokens = byDay.replaceFirst('BYDAY=', '').split(',');
    if (tokens.isNotEmpty) {
      final first = _formatMonthlyByDay(tokens.first);
      return first ?? '매월 ${byDay.replaceFirst('BYDAY=', '')} 반복';
    }
  }
  return '매월 15일 또는 매월 첫 번째 월요일처럼 말하면 더 구체적으로 저장됩니다.';
}

_MonthlyRecurrenceMode _monthlyMode(RecurrenceSelection value) {
  final parts = value.preservedParts.map((part) => part.toUpperCase()).toList();
  final byMonthDay = parts.any((part) => part.startsWith('BYMONTHDAY='));
  if (byMonthDay) {
    return _MonthlyRecurrenceMode.dayOfMonth;
  }
  final byDay = parts.any((part) => part.startsWith('BYDAY='));
  if (byDay) {
    return _MonthlyRecurrenceMode.weekdayOrdinal;
  }
  return _MonthlyRecurrenceMode.dayOfMonth;
}

int _selectedMonthlyDay(RecurrenceSelection value) {
  final parts = value.preservedParts.map((part) => part.toUpperCase()).toList();
  final byMonthDay = parts.firstWhere(
    (part) => part.startsWith('BYMONTHDAY='),
    orElse: () => '',
  );
  final parsed = int.tryParse(byMonthDay.replaceFirst('BYMONTHDAY=', ''));
  return parsed != null && parsed >= 1 && parsed <= 31 ? parsed : 1;
}

({int order, String weekday}) _selectedMonthlyOrdinal(
  RecurrenceSelection value,
) {
  final parts = value.preservedParts.map((part) => part.toUpperCase()).toList();
  final byDay = parts.firstWhere(
    (part) => part.startsWith('BYDAY='),
    orElse: () => '',
  );
  final token = byDay.replaceFirst('BYDAY=', '');
  final first = token.split(',').firstWhere(
        (item) => item.isNotEmpty,
        orElse: () => '',
      );
  final match = RegExp(r'^(-?\d+)?([A-Z]{2})$').firstMatch(first);
  final weekday = match?.group(2) ?? 'MO';
  final order = int.tryParse(match?.group(1) ?? '') ?? 1;
  return (order: order, weekday: weekday);
}

RecurrenceSelection _setMonthlyMode(
  RecurrenceSelection value,
  _MonthlyRecurrenceMode mode,
) {
  if (mode == _MonthlyRecurrenceMode.dayOfMonth) {
    return _setMonthlyDay(value, _selectedMonthlyDay(value));
  }
  final selected = _selectedMonthlyOrdinal(value);
  return _setMonthlyOrdinal(
    value,
    order: selected.order,
    weekday: selected.weekday,
  );
}

RecurrenceSelection _setMonthlyDay(
  RecurrenceSelection value,
  int day,
) {
  final next = _replaceMonthlyParts(
    value.preservedParts,
    <String>[
      'BYMONTHDAY=$day',
    ],
  );
  return value.copyWith(preservedParts: next);
}

RecurrenceSelection _setMonthlyOrdinal(
  RecurrenceSelection value, {
  required int order,
  required String weekday,
}) {
  final next = _replaceMonthlyParts(
    value.preservedParts,
    <String>[
      'BYDAY=${order == -1 ? '-1' : order}$weekday',
    ],
  );
  return value.copyWith(preservedParts: next);
}

List<String> _replaceMonthlyParts(
  List<String> parts,
  List<String> monthParts,
) {
  final next = parts
      .where(
        (part) =>
            !part.toUpperCase().startsWith('BYMONTHDAY=') &&
            !part.toUpperCase().startsWith('BYDAY='),
      )
      .toList();
  next.addAll(monthParts);
  return next;
}

String? _formatMonthlyByDay(String token) {
  final match = RegExp(r'^(-?\d+)?([A-Z]{2})$').firstMatch(token);
  if (match == null) {
    return null;
  }
  final order = int.tryParse(match.group(1) ?? '') ?? 1;
  final weekday = switch (match.group(2)) {
    'MO' => '월요일',
    'TU' => '화요일',
    'WE' => '수요일',
    'TH' => '목요일',
    'FR' => '금요일',
    'SA' => '토요일',
    'SU' => '일요일',
    _ => null,
  };
  if (weekday == null) {
    return null;
  }
  final orderLabel = switch (order) {
    1 => '첫 번째',
    2 => '두 번째',
    3 => '세 번째',
    4 => '네 번째',
    -1 => '마지막',
    _ => '$order번째',
  };
  return '매월 $orderLabel $weekday 반복';
}
