import 'package:flutter/material.dart';

import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../models/group_event_model.dart';
import '../models/group_event_recurrence.dart';
import 'group_event_tile.dart';

/// 그룹 일정을 월별 캘린더 뷰로 표시하는 공개 위젯.
///
/// 상단에는 이전/다음 월 이동 헤더, 7열 요일 헤더, 6행 날짜 그리드가 있고,
/// 그리드 아래에는 선택된 날짜의 일정 목록이 [GroupEventTile]로 표시된다.
class GroupMonthCalendar extends StatefulWidget {
  const GroupMonthCalendar({
    super.key,
    required this.events,
    required this.focusedMonth,
    this.ownerNameOf,
    required this.onMonthChanged,
    this.onEventTap,
  });

  /// 표시할 그룹 일정 목록. 반복 일정은 내부에서 전개한다.
  final List<GroupEventModel> events;

  /// 현재 표시 중인 월 (day는 무시, year+month 기준).
  final DateTime focusedMonth;

  /// createdBy(userId) → 표시할 이름. null이면 소유자 행을 숨긴다.
  final String? Function(String createdBy)? ownerNameOf;

  /// 이전/다음 버튼 또는 '오늘' 버튼을 누르면 호출된다.
  final void Function(DateTime month) onMonthChanged;

  /// 일정 타일을 탭하면 호출된다.
  final void Function(GroupEventModel event)? onEventTap;

  @override
  State<GroupMonthCalendar> createState() => _GroupMonthCalendarState();
}

class _GroupMonthCalendarState extends State<GroupMonthCalendar> {
  late DateTime _focusedMonth; // year+month
  late DateTime _selectedDay;  // 선택된 날

  // 현재 focusedMonth 범위의 확장된 발생 목록 캐시
  List<GroupEventModel> _expandedOccurrences = const [];

  // 날짜별 발생 인덱스: 로컬 날짜 → 발생 목록
  final Map<DateTime, List<GroupEventModel>> _dayIndex = {};

  @override
  void initState() {
    super.initState();
    _focusedMonth = _monthOnly(widget.focusedMonth);
    _selectedDay = _defaultSelectedDay(_focusedMonth);
    _rebuildIndex();
  }

  @override
  void didUpdateWidget(GroupMonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newMonth = _monthOnly(widget.focusedMonth);
    final monthChanged = newMonth != _focusedMonth;
    final eventsChanged = !_listIdentical(oldWidget.events, widget.events);

    if (monthChanged) {
      _focusedMonth = newMonth;
      // 새 달에서 오늘이 있으면 오늘로, 없으면 1일로
      _selectedDay = _defaultSelectedDay(_focusedMonth);
    }
    if (monthChanged || eventsChanged) {
      _rebuildIndex();
    }
  }

  // ─── 인덱스 구축 ────────────────────────────────────────────────────────────

  void _rebuildIndex() {
    // 표시 그리드 전체 범위(앞뒤 달 포함) + 1일 여유
    final gridStart = _gridFirstDay(_focusedMonth).toUtc();
    final gridEnd = gridStart.add(const Duration(days: 42 + 1));

    final expanded = <GroupEventModel>[];
    for (final event in widget.events) {
      expanded.addAll(expandGroupEventOccurrences(event, gridStart, gridEnd));
    }
    _expandedOccurrences = expanded;

    _dayIndex.clear();
    for (final occ in _expandedOccurrences) {
      // 이 발생이 속하는 로컬 날짜들을 구한다 (다중일 일정 포함)
      final localStart = planflowLocal(occ.startAt);
      final localEnd = planflowLocal(occ.endAt);
      final startDay = DateTime(localStart.year, localStart.month, localStart.day);
      final endDay = DateTime(localEnd.year, localEnd.month, localEnd.day);

      for (var d = startDay;
          !d.isAfter(endDay);
          d = d.add(const Duration(days: 1))) {
        _dayIndex.putIfAbsent(d, () => <GroupEventModel>[]).add(occ);
      }
    }
    // 중복 제거 (같은 id가 여러 번 들어간 경우)
    for (final key in _dayIndex.keys) {
      final seen = <String>{};
      _dayIndex[key] = _dayIndex[key]!
          .where((e) => seen.add('${e.id}-${e.startAt.millisecondsSinceEpoch}'))
          .toList();
    }
  }

  // ─── 날짜 선택 ──────────────────────────────────────────────────────────────

  void _selectDay(DateTime day) {
    setState(() {
      _selectedDay = day;
    });
  }

  // ─── 월 이동 ────────────────────────────────────────────────────────────────

  void _moveToPrev() {
    final prev = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
    widget.onMonthChanged(prev);
  }

  void _moveToNext() {
    final next = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    widget.onMonthChanged(next);
  }

  void _moveToToday() {
    final today = planflowNow();
    final todayMonth = _monthOnly(today);
    widget.onMonthChanged(todayMonth);
    // 부모가 focusedMonth를 업데이트하면 didUpdateWidget에서 처리되지만,
    // 같은 달이면 selectedDay만 오늘로 바꾼다.
    final isSameMonth = todayMonth.year == _focusedMonth.year &&
        todayMonth.month == _focusedMonth.month;
    if (isSameMonth) {
      setState(() {
        _selectedDay = DateTime(today.year, today.month, today.day);
      });
    }
  }

  // ─── 빌드 ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const SizedBox(height: 4),
        _buildWeekdayRow(context),
        const SizedBox(height: 2),
        _buildGrid(context),
        const Divider(
          height: 24,
          color: PlanFlowColors.primaryFaint,
        ),
        _buildDayEventList(context),
      ],
    );
  }

  // ─── 헤더 (이전/다음 + 오늘) ────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final label =
        '${_focusedMonth.year}년 ${_focusedMonth.month}월';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: PlanFlowColors.primary,
            onPressed: _moveToPrev,
            tooltip: '이전 달',
          ),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            color: PlanFlowColors.primary,
            onPressed: _moveToNext,
            tooltip: '다음 달',
          ),
          TextButton(
            onPressed: _moveToToday,
            style: TextButton.styleFrom(
              foregroundColor: PlanFlowColors.primaryMid,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('오늘'),
          ),
        ],
      ),
    );
  }

  // ─── 요일 행 (일~토) ────────────────────────────────────────────────────────

  Widget _buildWeekdayRow(BuildContext context) {
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    return Row(
      children: List.generate(7, (i) {
        final isSunday = i == 0;
        final isSaturday = i == 6;
        return Expanded(
          child: Center(
            child: Text(
              weekdays[i],
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isSunday
                        ? const Color(0xFFB42318)
                        : isSaturday
                            ? PlanFlowColors.primaryMid
                            : PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        );
      }),
    );
  }

  // ─── 날짜 그리드 (6행 × 7열) ────────────────────────────────────────────────

  Widget _buildGrid(BuildContext context) {
    final today = planflowNow();
    final todayDay = DateTime(today.year, today.month, today.day);
    final gridFirst = _gridFirstDay(_focusedMonth);

    return Column(
      children: List.generate(6, (row) {
        return Row(
          children: List.generate(7, (col) {
            final day = gridFirst.add(Duration(days: row * 7 + col));
            return _buildDayCell(context, day, todayDay);
          }),
        );
      }),
    );
  }

  Widget _buildDayCell(
    BuildContext context,
    DateTime day,
    DateTime todayDay,
  ) {
    final isCurrentMonth = day.month == _focusedMonth.month;
    final isToday = day == todayDay;
    final isSelected = day == _selectedDay;
    final eventCount = _dayIndex[day]?.length ?? 0;

    Color bgColor = Colors.transparent;
    Color textColor;
    FontWeight fontWeight = FontWeight.w500;

    if (isSelected) {
      bgColor = PlanFlowColors.primary;
      textColor = Colors.white;
      fontWeight = FontWeight.w700;
    } else if (isToday) {
      bgColor = PlanFlowColors.primaryFaint;
      textColor = PlanFlowColors.primary;
      fontWeight = FontWeight.w700;
    } else if (isCurrentMonth) {
      textColor = day.weekday == DateTime.sunday
          ? const Color(0xFFB42318)
          : PlanFlowColors.textPrimary;
    } else {
      // 인접 달 날짜는 흐리게
      textColor = PlanFlowColors.textDisabled;
    }

    return Expanded(
      child: GestureDetector(
        onTap: () => _selectDay(day),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: fontWeight,
                    color: textColor,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              // 일정 개수 배지 (있을 때만, 선택일 포함)
              if (eventCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isCurrentMonth
                        ? PlanFlowColors.primaryFaint
                        : PlanFlowColors.tagNormalBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$eventCount',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: isCurrentMonth
                          ? PlanFlowColors.primary
                          : PlanFlowColors.textDisabled,
                    ),
                  ),
                )
              else
                const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  // ─── 선택된 날짜의 일정 목록 ────────────────────────────────────────────────

  Widget _buildDayEventList(BuildContext context) {
    final dayLabel =
        '${_selectedDay.month}월 ${_selectedDay.day}일';
    final dayEvents = _dayIndex[_selectedDay] ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            '$dayLabel 일정',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        if (dayEvents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 4),
            child: Center(
              child: Text(
                '이 날에 등록된 일정이 없어요.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textDisabled,
                    ),
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: dayEvents.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final event = dayEvents[i];
              return GroupEventTile(
                event: event,
                ownerName: widget.ownerNameOf?.call(event.createdBy),
                onTap: () => widget.onEventTap?.call(event),
              );
            },
          ),
      ],
    );
  }

  // ─── 날짜 유틸 ──────────────────────────────────────────────────────────────

  /// 해당 달의 첫 날이 포함된 주의 일요일 (그리드 시작일).
  static DateTime _gridFirstDay(DateTime month) {
    final firstOfMonth = DateTime(month.year, month.month, 1);
    // 일요일=7(DateTime.sunday), 내부표현 1~7, 일요일만 특수처리
    final weekday = firstOfMonth.weekday; // 1=월 ... 7=일
    final offsetToSunday = weekday % 7; // 월=1..토=6, 일=0
    return firstOfMonth.subtract(Duration(days: offsetToSunday));
  }

  /// year+month만 유지한 DateTime.
  static DateTime _monthOnly(DateTime dt) =>
      DateTime(dt.year, dt.month);

  /// 해당 달에서 기본 선택 날짜:
  /// 오늘이 그 달에 있으면 오늘, 없으면 1일.
  static DateTime _defaultSelectedDay(DateTime month) {
    final now = planflowNow();
    final today = DateTime(now.year, now.month, now.day);
    if (today.year == month.year && today.month == month.month) {
      return today;
    }
    return DateTime(month.year, month.month, 1);
  }

  /// 얕은 동일성 비교 (참조 동일 또는 길이+첫/끝 요소 id 일치).
  static bool _listIdentical(
    List<GroupEventModel> a,
    List<GroupEventModel> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    return a.first.id == b.first.id && a.last.id == b.last.id;
  }
}
