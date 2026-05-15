import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/event_metadata.dart';
import '../core/theme.dart';
import 'recurrence_selector.dart';
import 'reminder_offset_selector.dart';

enum CalendarDateTarget { start, end }

class CalendarStyleEventEditor extends StatefulWidget {
  const CalendarStyleEventEditor({
    super.key,
    required this.titleController,
    required this.locationController,
    required this.memoController,
    required this.startAt,
    required this.endAt,
    required this.isAllDay,
    required this.category,
    required this.recurrence,
    required this.reminderOffset,
    required this.isCritical,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onAllDayChanged,
    required this.onCategoryChanged,
    required this.onRecurrenceChanged,
    required this.onReminderChanged,
    required this.onCriticalChanged,
    required this.onLocationPick,
    this.titleValidator,
    this.isLookingUpLocation = false,
    this.extraAfterLocation,
    this.extraAfterMemo,
    this.titleHelperText,
    this.locationHelperText,
    this.memoMinLines = 3,
    this.memoMaxLines = 3,
  });

  final TextEditingController titleController;
  final TextEditingController locationController;
  final TextEditingController memoController;
  final DateTime startAt;
  final DateTime? endAt;
  final bool isAllDay;
  final String category;
  final RecurrenceSelection recurrence;
  final Duration? reminderOffset;
  final bool isCritical;
  final ValueChanged<DateTime> onStartChanged;
  final ValueChanged<DateTime?> onEndChanged;
  final ValueChanged<bool> onAllDayChanged;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<RecurrenceSelection> onRecurrenceChanged;
  final ValueChanged<Duration?> onReminderChanged;
  final ValueChanged<bool> onCriticalChanged;
  final VoidCallback onLocationPick;
  final FormFieldValidator<String>? titleValidator;
  final bool isLookingUpLocation;
  final Widget? extraAfterLocation;
  final Widget? extraAfterMemo;
  final String? titleHelperText;
  final String? locationHelperText;
  final int memoMinLines;
  final int memoMaxLines;

  @override
  State<CalendarStyleEventEditor> createState() =>
      _CalendarStyleEventEditorState();
}

class _CalendarStyleEventEditorState extends State<CalendarStyleEventEditor> {
  CalendarDateTarget? _activeTarget;
  bool _classificationExpanded = false;
  bool _detailsExpanded = false;
  bool _alarmExpanded = false;

  DateTime get _activeValue {
    if (_activeTarget == CalendarDateTarget.end) {
      return widget.endAt ?? widget.startAt.add(const Duration(hours: 1));
    }
    return widget.startAt;
  }

  void _toggleTarget(CalendarDateTarget target) {
    setState(() {
      _activeTarget = _activeTarget == target ? null : target;
    });
  }

  void _applyDateTime(DateTime value) {
    if (_activeTarget == CalendarDateTarget.end) {
      widget.onEndChanged(value);
    } else {
      widget.onStartChanged(value);
    }
  }

  void _pickToday() {
    final now = DateTime.now();
    final current = _activeValue;
    _applyDateTime(
      DateTime(
        now.year,
        now.month,
        now.day,
        current.hour,
        current.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoryColor = PlanFlowEventCategories.colorOf(widget.category);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EditorSection(
            icon: Icons.event_note_outlined,
            title: '기본 정보',
            subtitle: '제목과 캘린더만 먼저 확인하세요.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CalendarHeader(color: categoryColor),
                const SizedBox(height: 10),
                TextFormField(
                  controller: widget.titleController,
                  validator: widget.titleValidator,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) =>
                      FocusScope.of(context).unfocus(),
                  decoration: InputDecoration(
                    labelText: '제목',
                    helperText: widget.titleHelperText,
                    prefixIcon:
                        Icon(Icons.circle, color: categoryColor, size: 16),
                    suffixIcon: const Icon(Icons.mood_outlined),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _EditorSection(
            icon: Icons.schedule_outlined,
            title: '날짜 · 시간',
            subtitle: '시작/종료를 누르면 바로 아래에서 조정해요.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile.adaptive(
                  value: widget.isAllDay,
                  onChanged: widget.onAllDayChanged,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('종일'),
                  secondary: const Icon(Icons.schedule_outlined),
                ),
                _DateRangeSummary(
                  startAt: widget.startAt,
                  endAt: widget.endAt,
                  isAllDay: widget.isAllDay,
                  activeTarget: _activeTarget,
                  onStartTap: () => _toggleTarget(CalendarDateTarget.start),
                  onEndTap: () => _toggleTarget(CalendarDateTarget.end),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _activeTarget == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _InlineDateTimeWheel(
                            key: ValueKey(_activeTarget),
                            value: _activeValue,
                            isAllDay: widget.isAllDay,
                            target: _activeTarget!,
                            onChanged: _applyDateTime,
                            onToday: _pickToday,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _EditorSection(
            icon: Icons.place_outlined,
            title: '장소',
            subtitle: '비어 있어도 지도 버튼으로 직접 위치를 고를 수 있어요.',
            child: TextFormField(
              controller: widget.locationController,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
              decoration: InputDecoration(
                labelText: '장소',
                helperText: widget.locationHelperText,
                prefixIcon: const Icon(Icons.place_outlined),
                suffixIcon: IconButton(
                  tooltip: '지도에서 위치 선택',
                  onPressed:
                      widget.isLookingUpLocation ? null : widget.onLocationPick,
                  icon: widget.isLookingUpLocation
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.map_outlined),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _EditorSection(
            icon: Icons.tune_outlined,
            title: '분류 · 반복',
            subtitle: '${widget.category} · ${_recurrenceSummary(widget.recurrence)}',
            collapsible: true,
            expanded: _classificationExpanded,
            onExpansionChanged: (value) =>
                setState(() => _classificationExpanded = value),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: PlanFlowEventCategories.values.map((category) {
                    return ChoiceChip(
                      label: Text(category),
                      selected: widget.category == category,
                      onSelected: (_) => widget.onCategoryChanged(category),
                    );
                  }).toList(growable: false),
                ),
                const SizedBox(height: 12),
                RecurrenceSelector(
                  value: widget.recurrence,
                  onChanged: widget.onRecurrenceChanged,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _EditorSection(
            icon: Icons.notes_outlined,
            title: '설명 · 준비',
            subtitle: '메모, 준비물, 스마트 준비 알림은 필요할 때만 열어 수정하세요.',
            collapsible: true,
            expanded: _detailsExpanded,
            onExpansionChanged: (value) =>
                setState(() => _detailsExpanded = value),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: widget.memoController,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) =>
                      FocusScope.of(context).unfocus(),
                  decoration: const InputDecoration(
                    labelText: '설명',
                    prefixIcon: Icon(Icons.notes_outlined),
                    alignLabelWithHint: true,
                  ),
                  minLines: widget.memoMinLines,
                  maxLines: widget.memoMaxLines,
                ),
                if (widget.extraAfterMemo != null) ...[
                  const SizedBox(height: 12),
                  widget.extraAfterMemo!,
                ],
                if (widget.extraAfterLocation != null) ...[
                  const SizedBox(height: 12),
                  widget.extraAfterLocation!,
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          _EditorSection(
            icon: Icons.notifications_active_outlined,
            title: '알림 옵션',
            subtitle: _alarmSummary(
              widget.reminderOffset,
              isCritical: widget.isCritical,
            ),
            collapsible: true,
            expanded: _alarmExpanded,
            onExpansionChanged: (value) =>
                setState(() => _alarmExpanded = value),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ReminderOffsetSelector(
                  value: widget.reminderOffset,
                  onChanged: widget.onReminderChanged,
                  subtitle: '기본은 1시간 전입니다. 이 일정만 다르게 바꿀 수 있어요.',
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  tileColor: widget.isCritical
                      ? const Color(0xFFFFE3DD)
                      : PlanFlowColors.surfaceFaint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: widget.isCritical
                          ? const Color(0xFFB42318)
                          : PlanFlowColors.primaryFaint,
                      width: widget.isCritical ? 1.2 : 0.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  title: const Text('강한 알림으로 예약'),
                  subtitle: const Text(
                    '정확한 알람, 강한 진동, 전체 화면 알림을 시도합니다. 무음·방해금지 우회는 Android 정책상 보장되지 않아요.',
                  ),
                  secondary: Icon(
                    widget.isCritical
                        ? Icons.priority_high_rounded
                        : Icons.notifications_active_outlined,
                    color: widget.isCritical
                        ? const Color(0xFFB42318)
                        : PlanFlowColors.textSecondary,
                  ),
                  activeThumbColor: const Color(0xFFB42318),
                  activeTrackColor: const Color(0xFFFFC9BE),
                  value: widget.isCritical,
                  onChanged: widget.onCriticalChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorSection extends StatelessWidget {
  const _EditorSection({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.collapsible = false,
    this.expanded = true,
    this.onExpansionChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final bool collapsible;
  final bool expanded;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      child: expanded
          ? Padding(
              key: const ValueKey('expanded'),
              padding: const EdgeInsets.only(top: 12),
              child: child,
            )
          : const SizedBox.shrink(key: ValueKey('collapsed')),
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: collapsible && !expanded
            ? PlanFlowColors.surface
            : PlanFlowColors.surfaceFaint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: collapsible && !expanded
              ? PlanFlowColors.primaryFaint
              : PlanFlowColors.primaryLight.withValues(alpha: 0.45),
          width: collapsible && !expanded ? 0.5 : 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: collapsible
                ? () => onExpansionChanged?.call(!expanded)
                : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: PlanFlowColors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (collapsible)
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: PlanFlowColors.textSecondary,
                  ),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

String _recurrenceSummary(RecurrenceSelection value) {
  if (value.isNone) {
    return '반복 안 함';
  }
  return switch (value.frequency) {
    'daily' => '매일 반복',
    'weekly' => '매주 반복',
    'monthly' => '매월 반복',
    'yearly' => '매년 반복',
    _ => '반복 안 함',
  };
}

String _alarmSummary(Duration? offset, {required bool isCritical}) {
  final minutes = offset?.inMinutes;
  final reminder = switch (minutes) {
    null => '알림 없음',
    0 => '정시 알림',
    10 => '10분 전',
    30 => '30분 전',
    60 => '1시간 전',
    120 => '2시간 전',
    _ when minutes % 60 == 0 => '${minutes ~/ 60}시간 전',
    _ => '$minutes분 전',
  };
  return isCritical ? '$reminder · 강한 알림' : reminder;
}

class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '[기본] 내 캘린더',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        const Icon(Icons.expand_more, color: PlanFlowColors.textSecondary),
      ],
    );
  }
}

class _DateRangeSummary extends StatelessWidget {
  const _DateRangeSummary({
    required this.startAt,
    required this.endAt,
    required this.isAllDay,
    required this.activeTarget,
    required this.onStartTap,
    required this.onEndTap,
  });

  final DateTime startAt;
  final DateTime? endAt;
  final bool isAllDay;
  final CalendarDateTarget? activeTarget;
  final VoidCallback onStartTap;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context) {
    final effectiveEnd = endAt ?? startAt.add(const Duration(hours: 1));
    return Row(
      children: [
        Expanded(
          child: _DateSummaryButton(
            label: '시작',
            value: startAt,
            isAllDay: isAllDay,
            selected: activeTarget == CalendarDateTarget.start,
            onTap: onStartTap,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.chevron_right, color: PlanFlowColors.textSecondary),
        ),
        Expanded(
          child: _DateSummaryButton(
            label: '종료',
            value: effectiveEnd,
            isAllDay: isAllDay,
            selected: activeTarget == CalendarDateTarget.end,
            onTap: onEndTap,
          ),
        ),
      ],
    );
  }
}

class _DateSummaryButton extends StatelessWidget {
  const _DateSummaryButton({
    required this.label,
    required this.value,
    required this.isAllDay,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final bool isAllDay;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = _shortDate(value);
    final time = isAllDay ? '종일' : _timeLabel(value);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? PlanFlowColors.primaryFaint
              : PlanFlowColors.surfaceFaint,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? PlanFlowColors.primaryMid
                : PlanFlowColors.primaryFaint,
            width: selected ? 1.2 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 3),
            Text(
              date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: selected
                        ? PlanFlowColors.primary
                        : PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            Text(
              time,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: selected
                        ? PlanFlowColors.primaryMid
                        : PlanFlowColors.textPrimary,
                    fontWeight: FontWeight.w900,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineDateTimeWheel extends StatefulWidget {
  const _InlineDateTimeWheel({
    super.key,
    required this.value,
    required this.isAllDay,
    required this.target,
    required this.onChanged,
    required this.onToday,
  });

  final DateTime value;
  final bool isAllDay;
  final CalendarDateTarget target;
  final ValueChanged<DateTime> onChanged;
  final VoidCallback onToday;

  @override
  State<_InlineDateTimeWheel> createState() => _InlineDateTimeWheelState();
}

class _InlineDateTimeWheelState extends State<_InlineDateTimeWheel> {
  static const _itemExtent = 36.0;

  late int _year;
  late int _month;
  late int _day;
  late int _hour24;
  late int _minute;

  List<int> get _years {
    final now = DateTime.now();
    return List<int>.generate(11, (index) => now.year - 5 + index);
  }

  List<int> get _minutes => List<int>.generate(12, (index) => index * 5);
  List<int> get _hours12 => List<int>.generate(12, (index) => index + 1);

  @override
  void initState() {
    super.initState();
    _readValue(widget.value);
  }

  @override
  void didUpdateWidget(covariant _InlineDateTimeWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.target != widget.target ||
        oldWidget.isAllDay != widget.isAllDay) {
      _readValue(widget.value);
    }
  }

  void _readValue(DateTime value) {
    _year = value.year;
    _month = value.month;
    _day = value.day;
    _hour24 = value.hour;
    _minute = _nearestFive(value.minute);
  }

  void _emit() {
    final maxDay = DateUtils.getDaysInMonth(_year, _month);
    if (_day > maxDay) {
      _day = maxDay;
    }
    final hour = widget.isAllDay ? 0 : _hour24;
    final minute = widget.isAllDay ? 0 : _minute;
    widget.onChanged(DateTime(_year, _month, _day, hour, minute));
  }

  void _set(void Function() update) {
    setState(update);
    _emit();
  }

  int _circularDelta(int oldIndex, int newIndex, int length) {
    final rawDelta = newIndex - oldIndex;
    final threshold = length ~/ 2;
    if (rawDelta.abs() <= threshold) {
      return rawDelta;
    }

    return rawDelta > 0 ? rawDelta - length : rawDelta + length;
  }

  void _onYearChanged(int value) => _set(() => _year = value);

  void _onMonthChanged(int value) => _set(() => _month = value);

  void _onDayChanged(int value) => _set(() => _day = value);

  void _onPeriodChanged(int value) {
    if (value == _period) {
      return;
    }
    final localHour12 = _hour24 % 12;
    _set(() {
      _hour24 = value == 0 ? localHour12 : localHour12 + 12;
    });
  }

  void _onHourChanged(int value) {
    if (value == _hour12) {
      return;
    }
    final oldIndex = _hour12 - 1;
    final newIndex = value - 1;
    final delta = _circularDelta(oldIndex, newIndex, _hours12.length);
    _set(() {
      _hour24 = (_hour24 + delta) % 24;
      if (_hour24 < 0) {
        _hour24 += 24;
      }
    });
  }

  void _onMinuteChanged(int value) {
    if (value == _minute) {
      return;
    }
    final oldIndex = _minutes.indexOf(_minute);
    final newIndex = _minutes.indexOf(value);
    final delta = _circularDelta(oldIndex, newIndex, _minutes.length);
    final deltaMinute = delta * 5;
    final rawMinute = _minute + deltaMinute;
    final adjustedMinute = rawMinute % 60;
    final hourDelta = (rawMinute - adjustedMinute) ~/ 60;

    _set(() {
      _minute = adjustedMinute;
      _hour24 = (_hour24 + hourDelta) % 24;
      if (_hour24 < 0) {
        _hour24 += 24;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.target == CalendarDateTarget.start ? '시작' : '종료';
    final maxDay = DateUtils.getDaysInMonth(_year, _month);
    final days = List<int>.generate(maxDay, (index) => index + 1);
    final selectedDate = DateTime(_year, _month, _day.clamp(1, maxDay));

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surfaceFaint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$title 시간 조정',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              TextButton(
                onPressed: widget.onToday,
                child: const Text('오늘'),
              ),
            ],
          ),
          SizedBox(
            height: 176,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  height: _itemExtent,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _Wheel<int>(
                        key: ValueKey('${widget.target.name}-year-wheel'),
                        values: _years,
                        selected: _year,
                        labelBuilder: (value) => '$value',
                        itemExtent: _itemExtent,
                        onChanged: _onYearChanged,
                      ),
                    ),
                    Expanded(
                      child: _Wheel<int>(
                        key: ValueKey('${widget.target.name}-month-wheel'),
                        values: List<int>.generate(12, (index) => index + 1),
                        selected: _month,
                        labelBuilder: (value) => '$value월',
                        itemExtent: _itemExtent,
                        onChanged: _onMonthChanged,
                      ),
                    ),
                    Expanded(
                      child: _Wheel<int>(
                        key: ValueKey('${widget.target.name}-day-wheel'),
                        values: days,
                        selected: _day.clamp(1, maxDay),
                        labelBuilder: (value) =>
                            '$value일 ${_weekday(DateTime(_year, _month, value))}',
                        itemExtent: _itemExtent,
                        onChanged: _onDayChanged,
                      ),
                    ),
                    if (!widget.isAllDay) ...[
                      Expanded(
                        child: _Wheel<int>(
                          key: ValueKey('${widget.target.name}-period-wheel'),
                          values: const [0, 1],
                          selected: _period,
                          labelBuilder: (value) => value == 0 ? '오전' : '오후',
                          itemExtent: _itemExtent,
                          looping: true,
                          onChanged: _onPeriodChanged,
                        ),
                      ),
                      Expanded(
                        child: _Wheel<int>(
                          key: ValueKey('${widget.target.name}-hour-wheel'),
                          values: List<int>.generate(12, (index) => index + 1),
                          selected: _hour12,
                          labelBuilder: (value) => '$value',
                          itemExtent: _itemExtent,
                          looping: true,
                          onChanged: _onHourChanged,
                        ),
                      ),
                      Expanded(
                        child: _Wheel<int>(
                          key: ValueKey('${widget.target.name}-minute-wheel'),
                          values: _minutes,
                          selected: _minute,
                          labelBuilder: (value) =>
                              value.toString().padLeft(2, '0'),
                          itemExtent: _itemExtent,
                          looping: true,
                          onChanged: _onMinuteChanged,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.isAllDay
                  ? _shortDate(selectedDate)
                  : '${_shortDate(selectedDate)} ${_timeLabel(DateTime(_year, _month, _day.clamp(1, maxDay), _hour24, _minute))}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  int get _period {
    return _hour24 < 12 ? 0 : 1;
  }

  int get _hour12 {
    final normalized = _hour24 % 12;
    return normalized == 0 ? 12 : normalized;
  }
}

class _Wheel<T> extends StatelessWidget {
  const _Wheel({
    required this.values,
    required this.selected,
    required this.labelBuilder,
    required this.itemExtent,
    required this.onChanged,
    this.looping = false,
    super.key,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelBuilder;
  final double itemExtent;
  final ValueChanged<T> onChanged;
  final bool looping;

  @override
  Widget build(BuildContext context) {
    final initialItem = values.indexOf(selected).clamp(0, values.length - 1);
    return CupertinoPicker(
      scrollController: FixedExtentScrollController(initialItem: initialItem),
      itemExtent: itemExtent,
      magnification: 1.05,
      squeeze: 1.08,
      useMagnifier: true,
      selectionOverlay: const SizedBox.shrink(),
      looping: looping,
      onSelectedItemChanged: (index) => onChanged(values[index]),
      children: values
          .map(
            (value) => Center(
              child: Text(
                labelBuilder(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight:
                          value == selected ? FontWeight.w900 : FontWeight.w600,
                      color: value == selected
                          ? PlanFlowColors.primary
                          : PlanFlowColors.textSecondary,
                    ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

String _shortDate(DateTime value) {
  return '${value.year % 100}. ${value.month}. ${value.day}.(${_weekday(value)})';
}

String _weekday(DateTime value) {
  const labels = <int, String>{
    DateTime.monday: '월',
    DateTime.tuesday: '화',
    DateTime.wednesday: '수',
    DateTime.thursday: '목',
    DateTime.friday: '금',
    DateTime.saturday: '토',
    DateTime.sunday: '일',
  };
  return labels[value.weekday] ?? '';
}

String _timeLabel(DateTime value) {
  final period = value.hour < 12 ? '오전' : '오후';
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$period $hour:$minute';
}

int _nearestFive(int minute) {
  final rounded = ((minute / 5).round() * 5).clamp(0, 55);
  return rounded.toInt();
}
