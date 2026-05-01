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

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    EventRepository? eventRepository,
  }) : eventRepository = eventRepository ?? const _UnavailableEventRepository();

  final EventRepository eventRepository;

  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PlanFlow'),
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
              message: '오늘의 핵심 일정을 한 번에 확인하고, 필요한 준비를 미리 끝내세요.',
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
                const _LegendDot(
                  color: PlanFlowColors.active,
                  label: '진행중',
                ),
                const SizedBox(width: 10),
                const _LegendDot(
                  color: PlanFlowColors.primary,
                  label: '예정',
                ),
                const SizedBox(width: 10),
                const _LegendDot(
                  color: PlanFlowColors.primaryFaint,
                  label: '완료',
                ),
              ],
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            FutureBuilder<List<EventModel>>(
              future: _loadTodayEvents(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return _HomeMessageCard(
                    icon: Icons.cloud_off,
                    title: '일정을 불러오지 못했어요',
                    message: 'Supabase 로그인과 환경값을 확인해 주세요.',
                  );
                }

                final events = snapshot.data ?? const <EventModel>[];
                if (events.isEmpty) {
                  return const _HomeMessageCard(
                    icon: Icons.self_improvement,
                    title: '오늘은 여유로운 하루예요',
                    message: '새 일정을 음성으로 빠르게 추가해 보세요.',
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
          ],
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.go(AppRoutes.voice),
      ),
    );
  }

  Future<List<EventModel>> _loadTodayEvents() async {
    if (!AppEnv.isSupabaseReady ||
        Supabase.instance.client.auth.currentUser == null) {
      return const <EventModel>[];
    }

    final repository = eventRepository is _UnavailableEventRepository
        ? EventRepository.supabase()
        : eventRepository;
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

class _HomeMessageCard extends StatelessWidget {
  const _HomeMessageCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Column(
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
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
