part of 'calendar_screen.dart';

class _CalendarSelectedDateHeader extends StatelessWidget {
  const _CalendarSelectedDateHeader({
    required this.selectedDateLabel,
    required this.eventCount,
    required this.onAdd,
    required this.onVoice,
    this.holidayName,
    this.isHoliday = false,
  });

  final String selectedDateLabel;
  final int eventCount;
  final VoidCallback onAdd;
  final VoidCallback onVoice;
  final String? holidayName;
  final bool isHoliday;

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

        // 공휴일 이름 칩(쉬는 날이면 빨강, 아니면 secondary 톤)
        final holidayChip = holidayName != null
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: isHoliday
                      ? calendarCriticalEventMarkerColor.withValues(alpha: 0.15)
                      : PlanFlowColors.textSecondary.withValues(alpha: 0.12),
                  border: Border.all(
                    color: isHoliday
                        ? calendarCriticalEventMarkerColor
                        : PlanFlowColors.textSecondary,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  holidayName!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isHoliday
                        ? calendarCriticalEventMarkerColor
                        : PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : null;

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
              if (holidayChip != null) holidayChip,
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
              child: Row(
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
                  if (holidayChip != null) ...[
                    const SizedBox(width: 8),
                    holidayChip,
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
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
    required this.personalEvents,
    required this.groupEvents,
    required this.onAdd,
    required this.onVoice,
    required this.onEventTap,
    required this.onGroupEventTap,
    this.scrollController,
  });

  final DateTime day;
  final List<EventModel> personalEvents;
  final List<CalendarOverlayItem> groupEvents;
  final VoidCallback onAdd;
  final VoidCallback onVoice;
  final ValueChanged<EventModel> onEventTap;
  final ValueChanged<CalendarOverlayItem> onGroupEventTap;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _koreanDateLabel(day);
    final totalCount = personalEvents.length + groupEvents.length;
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
                  child: Text('$totalCount개'),
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
              child: personalEvents.isEmpty && groupEvents.isEmpty
                  ? ListView(
                      key: const ValueKey('calendar-day-events-empty-scroll'),
                      controller: scrollController,
                      children: const [_SheetEmptyState()],
                    )
                  : ListView(
                      key: const ValueKey('calendar-day-events-list'),
                      controller: scrollController,
                      children: [
                        if (personalEvents.isNotEmpty) ...[
                          _AgendaSectionHeader(
                            title: '개인 일정',
                            count: personalEvents.length,
                          ),
                          const SizedBox(height: 10),
                          ...personalEvents.map(
                            (event) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _EventAgendaCard(
                                event: event,
                                onTap: () => onEventTap(event),
                              ),
                            ),
                          ),
                        ],
                        if (groupEvents.isNotEmpty) ...[
                          if (personalEvents.isNotEmpty)
                            const SizedBox(height: 4),
                          _AgendaSectionHeader(
                            title: '그룹 일정',
                            count: groupEvents.length,
                          ),
                          const SizedBox(height: 10),
                          ...groupEvents.map(
                            (event) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _GroupOverlayAgendaCard(
                                key: ValueKey(
                                  'calendar-group-overlay-event-${event.id}',
                                ),
                                event: event,
                                onTap: () => onGroupEventTap(event),
                              ),
                            ),
                          ),
                        ],
                      ],
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

            // Day cells — 홈 위젯과 톤을 맞춘 격자선(hairline) 스타일.
            // 바깥 Container가 위/왼쪽 테두리를 담당하고, 각 셀은 오른쪽/아래쪽
            // 테두리만 그려 전체적으로 하나의 이어진 격자를 완성한다.
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: PlanFlowColors.calendarGridLine,
                    width: 1,
                  ),
                  left: BorderSide(
                    color: PlanFlowColors.calendarGridLine,
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                children: List.generate(
                  rows,
                  (weekIndex) {
                    return Row(
                      children: List.generate(7, (dayIndex) {
                        final cellIndex = weekIndex * 7 + dayIndex;
                        final cellBorder = BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: PlanFlowColors.calendarGridLine,
                              width: 1,
                            ),
                            bottom: BorderSide(
                              color: PlanFlowColors.calendarGridLine,
                              width: 1,
                            ),
                          ),
                        );
                        if (cellIndex >= monthCells.length) {
                          return Expanded(
                            child: Container(
                              height: 74,
                              decoration: cellBorder,
                            ),
                          );
                        }
                        final cell = monthCells[cellIndex];
                        final dayDate = cell.date;
                        if (dayDate == null) {
                          return Expanded(
                            child: Container(
                              height: 74,
                              decoration: cellBorder,
                            ),
                          );
                        }
                        final dayNumber = cell.dayNumber ?? dayDate.day;

                        final isToday = today.year == dayDate.year &&
                            today.month == dayDate.month &&
                            today.day == dayDate.day;
                        final isSelected =
                            selectedDate.year == dayDate.year &&
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
                              padding: const EdgeInsets.symmetric(
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? PlanFlowColors.primaryMid
                                    : isToday
                                        ? PlanFlowColors.calendarTodayCellBg
                                        : PlanFlowColors.surface,
                                border: Border(
                                  right: BorderSide(
                                    color: PlanFlowColors.calendarGridLine,
                                    width: 1,
                                  ),
                                  bottom: BorderSide(
                                    color: PlanFlowColors.calendarGridLine,
                                    width: 1,
                                  ),
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 20,
                                        height: 20,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? PlanFlowColors.primaryMid
                                              : isToday
                                                  ? PlanFlowColors
                                                      .calendarTodayCircle
                                                  : Colors.transparent,
                                          shape: BoxShape.circle,
                                        ),
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
                                            color: isSelected || isToday
                                                ? Colors.white
                                                : cell.isHoliday
                                                    ? calendarCriticalEventMarkerColor
                                                    : PlanFlowColors
                                                        .textPrimary,
                                          ),
                                        ),
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
                                      overlayEvents: cell.overlayEvents,
                                      overflowCount: cell.overflowCount,
                                      isSelected: isSelected,
                                      day: dayDate,
                                      holidayName: cell.holidayName,
                                      isHoliday: cell.isHoliday,
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
              ),
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
    required this.overlayEvents,
    required this.overflowCount,
    required this.isSelected,
    required this.day,
    this.holidayName,
    this.isHoliday = false,
  });

  final List<EventModel> events;
  final List<CalendarOverlayItem> overlayEvents;
  final int overflowCount;
  final bool isSelected;
  final DateTime day;
  final String? holidayName;
  final bool isHoliday;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty && overlayEvents.isEmpty && overflowCount <= 0 && holidayName == null) {
      return const SizedBox.shrink();
    }
    // 개인 일정 + 그룹 일정을 합쳐 셀 높이(고정 행 수)를 넘지 않게 예산을
    // 나눈다. 개인 일정을 먼저 채우고, 남는 행에 그룹 일정을 채운 뒤,
    // 양쪽에서 못 들어간 만큼을 하나의 "+N건" 라벨로 합쳐 보여준다.
    //
    // 공휴일 이름이 있으면 첫 행(1행)을 차지하므로 나머지 행에만 이벤트를
    // 표시한다.
    //
    // 과거엔 넘치는 일정이 하나라도 있으면 무조건 행 하나를 미리 비워
    // (_calendarMiniMonthEventRows-1)까지만 채웠는데, 그 결과 4번째 행에
    // 채울 일정이 있었던 날짜도 마지막 줄이 빈 채로 남아 보였다(홈 위젯의
    // 동일 버그와 같은 원인, 사용자 지적으로 함께 발견). 예산 전체
    // (_calendarMiniMonthEventRows)를 그대로 쓰고, 그 예산을 넘는 만큼만
    // hiddenCount로 표시한다.

    // 공휴일 라벨이 차지할 행 수
    final holidayRowCount = holidayName != null ? 1 : 0;
    final maxEventRows = _calendarMiniMonthEventRows - holidayRowCount;

    final totalItems = events.length + overlayEvents.length;
    final displayEvents = events.length > maxEventRows
        ? events.take(maxEventRows).toList(growable: false)
        : events;
    final remainingRows = maxEventRows - displayEvents.length;
    final displayOverlayEvents = remainingRows > 0
        ? overlayEvents.take(remainingRows).toList(growable: false)
        : const <CalendarOverlayItem>[];
    final hiddenCount = (totalItems + overflowCount) -
        displayEvents.length -
        displayOverlayEvents.length;

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 공휴일 라벨(쉬는 날이면 빨강, 아니면 차분한 톤).
        // 셀 폭이 넓을수록(태블릿 등) 글씨도 비례해서 커지도록 LayoutBuilder로
        // 셀 폭을 재서 폰 기준(약 44px) 대비 배율을 곱한다. 행 높이는 다른
        // 이벤트 행들과 맞춰 9로 고정(넘치면 레이아웃 오버플로 위험).
        if (holidayName != null)
          LayoutBuilder(
            builder: (context, constraints) {
              final scale =
                  (constraints.maxWidth / 44).clamp(1.0, 1.4);
              final fontSize = 6.8 * scale;
              return SizedBox(
                height: 9,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    holidayName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: 1.0,
                      color: isSelected
                          ? Colors.white
                          : isHoliday
                              ? calendarCriticalEventMarkerColor
                              : PlanFlowColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
        for (final event in displayEvents)
          _CalendarMiniEventLabel(
            event: event,
            isSelected: isSelected,
            day: day,
          ),
        for (final event in displayOverlayEvents)
          _CalendarMiniOverlayLabel(
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
                  // 넘친 일정 개수만 표시한다(제목 미리보기 없이). 홈 위젯과
                  // 단위·표기를 "+N건"으로 통일 — 제목을 함께 넣으면 제목이
                  // 길 때 개수가 잘려 안 보이는 문제가 있었다(사용자 지적).
                  '+$hiddenCount건',
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
                ? calendarCriticalEventTextColor.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.18)
            : event.isCritical
                ? calendarCriticalEventTextColor.withValues(alpha: 0.20)
                : _categoryColor(event.category).withValues(alpha: 0.16);
    final fg = isMultiDay
        ? calendarMultiDayEventTextColor
        : isSelected
            ? event.isCritical
                ? calendarCriticalEventTextColor
                : Colors.white
            : event.isCritical
                ? calendarCriticalEventTextColor
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

class _CalendarMiniOverlayLabel extends StatelessWidget {
  const _CalendarMiniOverlayLabel({
    required this.event,
    required this.isSelected,
    required this.day,
  });

  final CalendarOverlayItem event;
  final bool isSelected;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final segment = _multiDaySegment(event, day);
    final isMultiDay = event.isMultiDay;
    final bg = isMultiDay
        ? calendarGroupEventColor.withValues(alpha: 0.14)
        : isSelected
            ? Colors.white.withValues(alpha: 0.2)
            : calendarGroupEventColor.withValues(alpha: 0.14);
    final fg = isSelected ? Colors.white : calendarGroupEventColor;
    final showTitle = !isMultiDay || segment.$1;
    final hPadding = (isMultiDay && !segment.$1 && !segment.$2) ? 0.0 : 2.0;
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
                border: Border.all(
                  color: calendarGroupEventColor.withValues(alpha: 0.18),
                  width: 0.4,
                ),
              ),
              alignment: Alignment.centerLeft,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: hPadding,
                  ),
                  child: Text(
                    showTitle
                        ? (event.groupName != null && event.groupName!.isNotEmpty
                            ? '팀 ${event.title}'
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
            ),
          ),
        ],
      ),
    );
  }

  (bool, bool) _multiDaySegment(CalendarOverlayItem event, DateTime day) {
    if (!event.isMultiDay || event.startAt == null || event.endAt == null) {
      return (true, true);
    }
    final current = DateTime(day.year, day.month, day.day);
    final first = event.localStart;
    final last = event.localEnd;
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            event.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: accentColor,
                              fontSize: 13,
                              fontWeight: event.isCritical
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 팀에도 동시에 공유된 개인 일정임을 알리는 작은
                        // 뱃지. 팀 오버레이 항목과 중복 표시하지 않는 대신
                        // 이걸로 "공유됨"을 알려준다.
                        if (event.groupEventId != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: calendarGroupEventColor
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '팀 공유',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: calendarGroupEventColor,
                              ),
                            ),
                          ),
                        ],
                      ],
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
    final startStr = planflowFormatTime(localStart.hour, localStart.minute);
    if (end == null) {
      return startStr;
    }
    final localEnd = planflowLocal(end);
    final endStr = planflowFormatTime(localEnd.hour, localEnd.minute);
    return '$startStr - $endStr';
  }
}

// --- Group Overlay Agenda Card ---
class _GroupOverlayAgendaCard extends StatelessWidget {
  const _GroupOverlayAgendaCard({
    super.key,
    required this.event,
    this.onTap,
  });

  final CalendarOverlayItem event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final endAt = event.endAt;
    final timeLabel = _formatOverlayTimeRange(startAt, endAt);
    const accentColor = calendarGroupEventColor;

    return Card(
      color: accentColor.withValues(alpha: 0.08),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accentColor.withValues(alpha: 0.28),
          width: event.isMultiDay ? 1.0 : 0.8,
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
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '그룹',
                            style: TextStyle(
                              fontSize: 9,
                              color: calendarGroupEventColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if ((event.groupName ?? '').trim().isNotEmpty)
                          Text(
                            event.groupName!,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: calendarGroupEventColor,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                    if (timeLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        timeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: calendarGroupEventColor,
                          fontSize: 10,
                        ),
                      ),
                    ],
                    if (timeLabel != null) const SizedBox(height: 4),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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

  String? _formatOverlayTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final localStart = planflowLocal(start);
    final startStr = planflowFormatTime(localStart.hour, localStart.minute);
    if (end == null) {
      return startStr;
    }
    final localEnd = planflowLocal(end);
    final endStr = planflowFormatTime(localEnd.hour, localEnd.minute);
    return '$startStr - $endStr';
  }
}

/// 현재 캘린더가 개인 모드인지 특정 그룹 모드인지 보여주는 작은 컨텍스트 칩.
class _CalendarGroupContextChip extends StatelessWidget {
  const _CalendarGroupContextChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: PlanFlowColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: PlanFlowColors.primaryFaint),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              label == '개인 모드'
                  ? Icons.person_outline
                  : Icons.groups_outlined,
              size: 14,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: PlanFlowColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 개인/그룹 일정 목록 섹션 제목 (개수 배지 포함).
class _AgendaSectionHeader extends StatelessWidget {
  const _AgendaSectionHeader({
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: PlanFlowColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: PlanFlowColors.primaryFaint),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
          ),
      ],
    );
  }
}

/// 그룹 일정만 불러오지 못했을 때 표시하는 경고 배너.
class _CalendarOverlayErrorBanner extends StatelessWidget {
  const _CalendarOverlayErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF8C8C0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: Color(0xFFB42318),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF7A271A),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 미확인 리더 지시가 있는 이벤트 카드에 작은 badge dot 을 오버레이하는 래퍼.
///
/// [hasInstruction] 이 false 이면 child 를 그대로 반환한다.
class _InstructionBadgeWrapper extends StatelessWidget {
  const _InstructionBadgeWrapper({
    required this.hasInstruction,
    required this.child,
  });

  final bool hasInstruction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasInstruction) {
      return child;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -3,
          right: -3,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: calendarCriticalEventMarkerColor,
              shape: BoxShape.circle,
              border: Border.all(color: PlanFlowColors.surface, width: 1.5),
            ),
          ),
        ),
      ],
    );
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
