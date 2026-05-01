import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import 'widgets/briefing_banner.dart';
import 'widgets/early_bird_signup_card.dart';
import 'widgets/today_event_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
          children: const [
            BriefingBanner(
              title: 'Today briefing',
              message: 'Keep the next appointment visible and prepare early.',
            ),
            SizedBox(height: AppConstants.sectionSpacing),
            EarlyBirdSignupCard(),
            SizedBox(height: AppConstants.sectionSpacing),
            TodayEventCard(
              title: 'Morning meeting',
              timeRange: '09:30 - 10:00',
              location: 'Room A',
              supplies: ['deck', 'notes'],
              hasPreActions: true,
              isCritical: true,
            ),
            SizedBox(height: AppConstants.sectionSpacing),
            TodayEventCard(
              title: 'Lunch appointment',
              timeRange: '12:30 - 13:30',
              location: 'Central Cafe',
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
}
