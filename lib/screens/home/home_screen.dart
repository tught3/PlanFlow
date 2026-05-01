import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../widgets/planflow_voice_fab.dart';
import 'widgets/briefing_banner.dart';
import 'widgets/early_bird_signup_card.dart';
import 'widgets/today_event_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    EventRepository? eventRepository,
  }) : eventRepository = eventRepository ?? const _UnavailableEventRepository();

  final EventRepository eventRepository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<EventModel>> _todayEventsFuture;

  @override
  void initState() {
    super.initState();
    _todayEventsFuture = _loadTodayEvents();
  }

  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PlanFlow',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            Text(
              todayLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '음성 입력',
            icon: const Icon(Icons.mic_none),
            onPressed: () => context.go(AppRoutes.voice),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            const BriefingBanner(
              title: '오늘의 브리핑',
              message: '오늘 일정과 필요한 준비를 한 번에 확인하고, 음성으로 빠르게 추가해 보세요.',
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            const EarlyBirdSignupCard(),
            const SizedBox(height: AppConstants.sectionSpacing),
            Row(
              children: [
                Text(
                  '오늘 일정',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const Spacer(),
                const _LegendDot(color: PlanFlowColors.active, label: '진행'),
                const SizedBox(width: 10),
                const _LegendDot(color: PlanFlowColors.primary, label: '예정'),
                const SizedBox(width: 10),
                const _LegendDot(
                  color: PlanFlowColors.primaryFaint,
                  label: '완료',
                ),
              ],
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            FutureBuilder<List<EventModel>>(
              future: _todayEventsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const _HomeLoadingCard();
                }

                if (snapshot.hasError) {
                  return _HomeMessageCard(
                    icon: Icons.cloud_off,
                    title: '일정을 불러오지 못했어요',
                    message: '로그인은 되어 있지만 일정 데이터를 가져오지 못했습니다. 잠시 후 다시 확인해 주세요.',
                    primaryActionLabel: '다시 확인',
                    primaryIcon: Icons.refresh,
                    onPrimaryAction: _reloadTodayEvents,
                  );
                }

                final events = snapshot.data ?? const <EventModel>[];
                if (events.isEmpty) {
                  return _HomeMessageCard(
                    icon: Icons.calendar_month_outlined,
                    title: '오늘 등록된 일정이 없습니다',
                    message:
                        '새 일정을 말로 추가하면 이곳에 오늘 일정과 준비물이 정리됩니다. 지금 바로 하나 만들어 볼까요?',
                    primaryActionLabel: '말로 일정 추가',
                    primaryIcon: Icons.mic_none,
                    onPrimaryAction: () => context.go(AppRoutes.voice),
                    secondaryActionLabel: '일정 탭 보기',
                    onSecondaryAction: () => context.go(AppRoutes.calendar),
                  );
                }

                return Column(
                  children: [
                    for (final event in events) ...[
                      TodayEventCard(
                        title: event.title,
                        timeRange: _timeRange(event),
                        location: event.location,
                        supplies: event.supplies,
                        isCritical: event.isCritical,
                        status: _eventStatus(event),
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 88),
          ],
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.go(AppRoutes.voice),
      ),
    );
  }

  void _reloadTodayEvents() {
    setState(() {
      _todayEventsFuture = _loadTodayEvents();
    });
  }

  Future<List<EventModel>> _loadTodayEvents() async {
    if (!AppEnv.isSupabaseReady ||
        Supabase.instance.client.auth.currentUser == null) {
      return const <EventModel>[];
    }

    final repository = widget.eventRepository is _UnavailableEventRepository
        ? EventRepository.supabase()
        : widget.eventRepository;
    final events = await repository.listEvents();
    final now = DateTime.now();
    return events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return startAt.year == now.year &&
          startAt.month == now.month &&
          startAt.day == now.day;
    }).toList(growable: false);
  }

  String _timeRange(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return '시간 미정';
    }

    final formatter = DateFormat('HH:mm');
    final start = formatter.format(startAt);
    final endAt = event.endAt;
    if (endAt == null) {
      return start;
    }
    return '$start - ${formatter.format(endAt)}';
  }

  TodayEventStatus _eventStatus(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return TodayEventStatus.normal;
    }

    final now = DateTime.now();
    final endAt = event.endAt ?? startAt.add(const Duration(hours: 1));
    if (now.isAfter(endAt)) {
      return TodayEventStatus.done;
    }
    if (!now.isBefore(startAt) && now.isBefore(endAt)) {
      return TodayEventStatus.active;
    }
    return TodayEventStatus.normal;
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

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
  });

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _HomeLoadingCard extends StatelessWidget {
  const _HomeLoadingCard();

  @override
  Widget build(BuildContext context) {
    return const _HomeFrame(
      child: SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _HomeMessageCard extends StatelessWidget {
  const _HomeMessageCard({
    required this.icon,
    required this.title,
    required this.message,
    this.primaryActionLabel,
    this.primaryIcon = Icons.arrow_forward,
    this.onPrimaryAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? primaryActionLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimaryAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _HomeFrame(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 260),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: PlanFlowColors.primaryFaint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 28, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (primaryActionLabel != null && onPrimaryAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onPrimaryAction,
                icon: Icon(primaryIcon, size: 18),
                label: Text(primaryActionLabel!),
              ),
            ],
            if (secondaryActionLabel != null && onSecondaryAction != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: onSecondaryAction,
                child: Text(secondaryActionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HomeFrame extends StatelessWidget {
  const _HomeFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: child,
    );
  }
}

class _UnavailableEventRepository extends EventRepository {
  const _UnavailableEventRepository();

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError();
  }
}
