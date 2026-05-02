import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../widgets/planflow_voice_fab.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _selectedDate = DateTime.now();
  DateTime _focusedMonth = DateTime.now();
  List<EventModel> _allEvents = const <EventModel>[];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    if (!AppEnv.isSupabaseReady) {
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final repository = EventRepository.supabase();
      final events = await repository.listEvents(userId: user.id);
      if (mounted) {
        setState(() {
          _allEvents = events;
        });
      }
    } catch (_) {
      // Fail silently; show empty state
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<EventModel> get _eventsForSelectedDate {
    return _allEvents.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return startAt.year == _selectedDate.year &&
          startAt.month == _selectedDate.month &&
          startAt.day == _selectedDate.day;
    }).toList(growable: false);
  }

  Set<int> get _daysWithEvents {
    final days = <int>{};
    for (final event in _allEvents) {
      final startAt = event.startAt;
      if (startAt != null &&
          startAt.year == _focusedMonth.year &&
          startAt.month == _focusedMonth.month) {
        days.add(startAt.day);
      }
    }
    return days;
  }

  void _changeMonth(int delta) {
    setState(() {
      _focusedMonth = DateTime(
        _focusedMonth.year,
        _focusedMonth.month + delta,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monthLabel = '${_focusedMonth.year}년 ${_focusedMonth.month}월';
    final selectedDateLabel = _koreanDateLabel(_selectedDate);
    final dayEvents = _eventsForSelectedDate;

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: const Text('일정')),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(AppConstants.defaultPadding),
                children: [
                  // Month header with navigation
                  _MonthHeader(
                    monthLabel: monthLabel,
                    onPrevious: () => _changeMonth(-1),
                    onNext: () => _changeMonth(1),
                    onToday: () {
                      setState(() {
                        _focusedMonth = DateTime.now();
                        _selectedDate = DateTime.now();
                      });
                    },
                  ),
                  const SizedBox(height: 12),

                  // Mini calendar grid
                  _MiniCalendarGrid(
                    focusedMonth: _focusedMonth,
                    selectedDate: _selectedDate,
                    daysWithEvents: _daysWithEvents,
                    onDaySelected: (day) {
                      setState(() {
                        _selectedDate = day;
                      });
                    },
                  ),
                  const SizedBox(height: 16),

                  // Selected date events
                  Row(
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: PlanFlowColors.surface,
                          border:
                              Border.all(color: PlanFlowColors.primaryFaint),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${dayEvents.length}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: PlanFlowColors.primaryMid,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => context.push(AppRoutes.voice),
                        icon: const Icon(Icons.mic_none, size: 18),
                        label: const Text('음성 추가'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (dayEvents.isEmpty)
                    _EmptyAgendaCard(
                      onVoice: () => context.push(AppRoutes.voice),
                    )
                  else
                    ...dayEvents.map(
                      (event) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _EventAgendaCard(
                          event: event,
                          onTap: () => context.push(
                            AppRoutes.eventDetail,
                            extra: event,
                          ),
                        ),
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
          TextButton(
            onPressed: onToday,
            child: Text(
              '오늘',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
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
    required this.daysWithEvents,
    required this.onDaySelected,
  });

  final DateTime focusedMonth;
  final DateTime selectedDate;
  final Set<int> daysWithEvents;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstDayOfMonth = DateTime(focusedMonth.year, focusedMonth.month, 1);
    final lastDay =
        DateTime(focusedMonth.year, focusedMonth.month + 1, 0).day;
    final startWeekday = firstDayOfMonth.weekday % 7; // 0=Sun
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
              ((startWeekday + lastDay + 6) ~/ 7),
              (weekIndex) {
                return Row(
                  children: List.generate(7, (dayIndex) {
                    final dayNumber =
                        weekIndex * 7 + dayIndex - startWeekday + 1;
                    if (dayNumber < 1 || dayNumber > lastDay) {
                      return const Expanded(child: SizedBox(height: 40));
                    }

                    final dayDate = DateTime(
                      focusedMonth.year,
                      focusedMonth.month,
                      dayNumber,
                    );
                    final isToday = today.year == dayDate.year &&
                        today.month == dayDate.month &&
                        today.day == dayDate.day;
                    final isSelected = selectedDate.year == dayDate.year &&
                        selectedDate.month == dayDate.month &&
                        selectedDate.day == dayDate.day;
                    final hasEvent = daysWithEvents.contains(dayNumber);

                    return Expanded(
                      child: GestureDetector(
                        onTap: () => onDaySelected(dayDate),
                        child: Container(
                          height: 40,
                          margin: const EdgeInsets.all(1),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? PlanFlowColors.primaryMid
                                : isToday
                                    ? PlanFlowColors.primaryFaint
                                    : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$dayNumber',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isToday || isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: isSelected
                                      ? Colors.white
                                      : isToday
                                          ? PlanFlowColors.primaryMid
                                          : PlanFlowColors.textPrimary,
                                ),
                              ),
                              if (hasEvent)
                                Container(
                                  width: 4,
                                  height: 4,
                                  margin: const EdgeInsets.only(top: 2),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.white
                                        : PlanFlowColors.active,
                                    shape: BoxShape.circle,
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

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: event.isCritical
              ? const Color(0xFFB42318).withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: event.isCritical ? 1.5 : 0.5,
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: event.isCritical
                      ? const Color(0xFFFFE3DD)
                      : PlanFlowColors.background,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  event.isCritical
                      ? Icons.priority_high
                      : Icons.event_outlined,
                  color: event.isCritical
                      ? const Color(0xFFB42318)
                      : PlanFlowColors.primaryMid,
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
    final startStr =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return startStr;
    }
    final endStr =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
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
