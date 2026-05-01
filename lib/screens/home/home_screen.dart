import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
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
    final todayLabel = DateFormat('EEEE, MMM d').format(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Text(todayLabel),
        actions: [
          IconButton(
            tooltip: 'Voice input',
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
              title: 'Today briefing',
              message: 'Keep the next appointment visible and prepare early.',
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            const EarlyBirdSignupCard(),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.voice),
        icon: const Icon(Icons.mic),
        label: const Text('Voice Input'),
      ),
    );
  }

  Future<List<EventModel>> _loadTodayEvents() async {
    if (!AppEnv.isConfigured ||
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
