part of 'calendar_screen.dart';

class _CalendarSelectedDateHeader extends StatelessWidget {
  const _CalendarSelectedDateHeader({
    required this.selectedDateLabel,
    required this.eventCount,
    required this.onAdd,
    required this.onVoice,
  });

  final String selectedDateLabel;
  final int eventCount;
  final VoidCallback onAdd;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 420;
        final countBadge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: PlanFlowColors.surface,
            border: Border.all(color: PlanFlowColors.primaryFaint),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$eventCount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: PlanFlowColors.primaryMid,
            ),
          ),
        );

        if (isNarrow) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth,
                child: Text(
                  selectedDateLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              countBadge,
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('직접 추가'),
              ),
              TextButton.icon(
                onPressed: onVoice,
                icon: const Icon(Icons.mic_none, size: 18),
                label: const Text('음성 추가'),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(
              child: Text(
                selectedDateLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            countBadge,
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('직접 추가'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onVoice,
              icon: const Icon(Icons.mic_none, size: 18),
              label: const Text('음성 추가'),
            ),
          ],
        );
      },
    );
  }
}

class DayEventsSheet extends StatelessWidget {
  const DayEventsSheet({
    super.key,
    required this.day,
    required this.events,
    required this.onAdd,
    required this.onVoice,
    required this.onEventTap,
    this.scrollController,
  });

  final DateTime day;
  final List<EventModel> events;
  final VoidCallback onAdd;
  final VoidCallback onVoice;
  final ValueChanged<EventModel> onEventTap;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _koreanDateLabel(day);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: PlanFlowColors.primaryFaint),
                  ),
                  child: Text('${events.length}개'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '위로 끌어올려 더 많은 일정을 볼 수 있어요.',
              style: TextStyle(
                color: PlanFlowColors.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('직접 추가'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onVoice,
                    icon: const Icon(Icons.mic_none, size: 18),
                    label: const Text('음성 추가'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: events.isEmpty
                  ? ListView(
                      key: const ValueKey('calendar-day-events-empty-scroll'),
                      controller: scrollController,
                      children: const [_SheetEmptyState()],
                    )
                  : ListView.separated(
                      key: const ValueKey('calendar-day-events-list'),
                      controller: scrollController,
                      itemCount: events.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final event = events[index];
                        return _EventAgendaCard(
                          event: event,
                          onTap: () => onEventTap(event),
                        );
                      },
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

class _SheetEmptyState extends StatelessWidget {
  const _SheetEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: const Text(
        '이 날은 아직 일정이 없어요. 직접 추가하거나 음성으로 빠르게 등록할 수 있습니다.',
        style: TextStyle(color: PlanFlowColors.textSecondary, height: 1.35),
      ),
    );
  }
}

class _CalendarStatusCard extends StatelessWidget {
  const _CalendarStatusCard({
    required this.state,
    required this.onRefresh,
    this.message,
  });

  final _CalendarLoadState state;
  final VoidCallback onRefresh;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (state) {
      _CalendarLoadState.supabaseMissing => (
          Icons.cloud_off_outlined,
          'Supabase 설정이 필요해요',
          '빌드 설정값이 없어서 캘린더 데이터를 가져올 수 없어요.',
        ),
      _CalendarLoadState.signedOut => (
          Icons.lock_outline,
          '로그인이 필요해요',
          '로그인한 뒤 내 일정 목록을 다시 불러올 수 있어요.',
        ),
      _CalendarLoadState.error => (
          Icons.error_outline,
          '캘린더 불러오기 실패',
          message ?? '캘린더 일정 목록을 불러오지 못했습니다.',
        ),
      _CalendarLoadState.loading => (
          Icons.hourglass_top_outlined,
          '캘린더 확인 중',
          '잠시만 기다려 주세요.',
        ),
      _CalendarLoadState.ready => (
          Icons.check_circle_outline,
          '정상',
          '캘린더 데이터를 불러왔어요.',
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: PlanFlowColors.primaryMid),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('새로고침'),
          ),
        ],
      ),
    );
  }
}

// --- Month Header ---
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.monthLabel,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final String monthLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

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
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            onPressed: onPrevious,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          Expanded(
            child: Text(
              monthLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onToday,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.7),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              minimumSize: const Size(0, 38),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: (theme.textTheme.labelLarge?.fontSize ?? 14) * 1.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            icon: const Icon(Icons.today, size: 16),
            label: const Text('오늘'),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white),
            onPressed: onNext,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

// --- Mini Calendar Grid ---
class _MiniCalendarGrid extends StatelessWidget {
  const _MiniCalendarGrid({
    required this.focusedMonth,
    required this.selectedDate,
    required this.monthCells,
    required this.onDaySelected,
  });

  final DateTime focusedMonth;
  final DateTime selectedDate;
  final List<CalendarMiniMonthCellData> monthCells;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = (monthCells.length / 7).ceil();
    final today = DateTime.now();

    const weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];

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
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Weekday header
            Row(
              children: weekdayLabels.map((label) {
                final isSunday = label == '일';
                final isSaturday = label == '토';
                return Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isSunday
                            ? const Color(0xFFB42318)
                            : isSaturday
                                ? PlanFlowColors.primaryMid
                                : PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),

            // Day cells
            ...List.generate(
              rows,
              (weekIndex) {
                return Row(
                  children: List.generate(7, (dayIndex) {
                    final cellIndex = weekIndex * 7 + dayIndex;
                    if (cellIndex >= monthCells.length) {
                      return const Expanded(child: SizedBox(height: 74));
                    }
                    final cell = monthCells[cellIndex];
                    final dayDate = cell.date;
                    if (dayDate == null) {
                      return const Expanded(child: SizedBox(height: 74));
                    }
                    final dayNumber = cell.dayNumber ?? dayDate.day;

                    final isToday = today.year == dayDate.year &&
                        today.month == dayDate.month &&
                        today.day == dayDate.day;
                    final isSelected = selectedDate.year == dayDate.year &&
                        selectedDate.month == dayDate.month &&
                        selectedDate.day == dayDate.day;

                    return Expanded(
                      child: GestureDetector(
                        onTap: () => onDaySelected(dayDate),
                        child: Container(
                          key: ValueKey(
                            'calendar-mini-cell-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                          ),
                          height: 74,
                          margin: const EdgeInsets.all(1.5),
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? PlanFlowColors.primaryMid
                                : isToday
                                    ? PlanFlowColors.primaryFaint
                                    : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                child: Text(
                                  '$dayNumber',
                                  key: ValueKey(
                                    'calendar-mini-day-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isToday || isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: isSelected
                                        ? Colors.white
                                        : isToday
                                            ? PlanFlowColors.primaryMid
                                            : cell.isHoliday
                                                ? calendarCriticalEventMarkerColor
                                                : PlanFlowColors.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Expanded(
                                child: _CalendarMiniEventList(
                                  key: ValueKey(
                                    'calendar-mini-events-${focusedMonth.year}-${focusedMonth.month}-$dayNumber',
                                  ),
                                  events: cell.events,
                                  overflowCount: cell.overflowCount,
                                  isSelected: isSelected,
                                  day: dayDate,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarMiniEventList extends StatelessWidget {
  const _CalendarMiniEventList({
    super.key,
    required this.events,
    required this.overflowCount,
    required this.isSelected,
    required this.day,
  });

  final List<EventModel> events;
  final int overflowCount;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty && overflowCount <= 0) {
      return const SizedBox.shrink();
    }
    final requiresOverflowLabel =
        overflowCount > 0 || events.length > _calendarMiniMonthEventRows;
    final maxVisibleEvents = requiresOverflowLabel
        ? (_calendarMiniMonthEventRows - 1)
            .clamp(1, _calendarMiniMonthEventRows)
        : _calendarMiniMonthEventRows;
    final displayEvents = events.length > maxVisibleEvents
        ? events.take(maxVisibleEvents).toList(growable: false)
        : events;
    final hiddenCount = requiresOverflowLabel
        ? (events.length + overflowCount) - displayEvents.length
        : 0;
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final event in displayEvents)
          _CalendarMiniEventLabel(
            event: event,
            isSelected: isSelected,
            day: day,
          ),
        if (hiddenCount > 0)
          SizedBox(
            height: 9,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 1),
                child: Text(
                  '+$hiddenCount개',
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 7,
                    height: 1,
                    color: isSelected
                        ? Colors.white
                        : PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CalendarMiniEventLabel extends StatelessWidget {
  const _CalendarMiniEventLabel({
    required this.event,
    required this.isSelected,
    required this.day,
  });

  final EventModel event;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final segment = _multiDaySegment(event, day);
    final isMultiDay =
        event.isMultiDay || calendarEventSpansMultipleLocalDays(event);
    final isCriticalMultiDay = isMultiDay && event.isCritical;
    final bg = isMultiDay
        ? calendarMultiDayEventBackgroundColor
        : isSelected
            ? event.isCritical
                ? const Color(0xFFE53935).withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.18)
            : event.isCritical
                ? const Color(0xFFE53935).withValues(alpha: 0.20)
                : _categoryColor(event.category).withValues(alpha: 0.16);
    final fg = isMultiDay
        ? calendarMultiDayEventTextColor
        : isSelected
            ? event.isCritical
                ? const Color(0xFFFF6B6B)
                : Colors.white
            : event.isCritical
                ? const Color(0xFFE53935)
                : _categoryColor(event.category);
    final showTitle = !isMultiDay || segment.$1;
    final hPadding = (isMultiDay && !segment.$1 && !segment.$2) ? 0.0 : 2.0;
    // Neighboring day cells have 1.5px margins on each side, so extending
    // halfway into that gap lets range bars touch without alpha overlap.
    final extendLeft = isMultiDay && !segment.$1 ? 1.5 : 0.0;
    final extendRight = isMultiDay && !segment.$2 ? 1.5 : 0.0;
    return SizedBox(
      height: 9,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -extendLeft,
            right: -extendRight,
            top: 1,
            bottom: 0,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(segment.$1 ? 3 : 0),
                  right: Radius.circular(segment.$2 ? 3 : 0),
                ),
              ),
              alignment: Alignment.centerLeft,
              child: Stack(
                children: [
                  if (isCriticalMultiDay)
                    const Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      height: 1.4,
                      child: ColoredBox(
                        color: calendarCriticalMultiDayAccentColor,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: hPadding,
                      ).copyWith(
                        top: isCriticalMultiDay && showTitle ? 1.0 : 0.0,
                      ),
                      child: Text(
                        showTitle
                            ? (event.isAllDay && !isMultiDay
                                ? '종일 ${event.title}'
                                : event.title)
                            : '',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 6.8,
                          height: 1.0,
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  (bool, bool) _multiDaySegment(EventModel event, DateTime day) {
    if ((!event.isMultiDay && !calendarEventSpansMultipleLocalDays(event)) ||
        event.startAt == null ||
        event.endAt == null) {
      return (true, true);
    }
    final current = DateTime(day.year, day.month, day.day);
    final first = planflowLocalDay(event.startAt!);
    final last = _calendarDisplayEndDay(event.startAt!, event.endAt!);
    return (
      current == first || current.weekday == DateTime.sunday,
      current == last || current.weekday == DateTime.saturday
    );
  }
}

// --- Event Agenda Card ---
class _EventAgendaCard extends StatelessWidget {
  const _EventAgendaCard({
    required this.event,
    this.onTap,
  });

  final EventModel event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final endAt = event.endAt;
    final timeLabel = _formatTimeRange(startAt, endAt);
    final accentColor = event.isCritical
        ? const Color(0xFFE53935)
        : _categoryColor(event.category);

    return Card(
      color: accentColor.withValues(alpha: 0.08),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accentColor.withValues(alpha: 0.26),
          width: event.isCritical ? 1.2 : 0.8,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (timeLabel != null)
                      Text(
                        timeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: PlanFlowColors.primaryMid,
                          fontSize: 10,
                        ),
                      ),
                    if (timeLabel != null) const SizedBox(height: 4),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: accentColor,
                        fontSize: 13,
                        fontWeight: event.isCritical
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (event.location != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: PlanFlowColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              event.location!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (event.supplies.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: event.supplies
                            .take(3)
                            .map(
                              (supply) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: PlanFlowColors.tagNormalBg,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.backpack_outlined,
                                      size: 10,
                                      color: PlanFlowColors.tagNormalText,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      supply,
                                      style: const TextStyle(
                                        fontSize: 9,
                                        color: PlanFlowColors.tagNormalText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final localStart = planflowLocal(start);
    final startStr =
        '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return startStr;
    }
    final localEnd = planflowLocal(end);
    final endStr =
        '${localEnd.hour.toString().padLeft(2, '0')}:${localEnd.minute.toString().padLeft(2, '0')}';
    return '$startStr - $endStr';
  }
}

// --- Empty State ---
class _EmptyAgendaCard extends StatelessWidget {
  const _EmptyAgendaCard({required this.onVoice});

  final VoidCallback onVoice;

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.event_busy_outlined,
              size: 40,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(height: 12),
            Text(
              '이 날은 예정된 일정이 없어요',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '음성으로 회의, 할 일, 알림을 추가하면 이곳에 표시됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onVoice,
              icon: const Icon(Icons.mic_none),
              label: const Text('음성 입력 시작'),
            ),
          ],
        ),
      ),
    );
  }
}
