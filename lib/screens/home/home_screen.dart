import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import 'widgets/briefing_banner.dart';
import 'widgets/today_event_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
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
              message: 'Check the schedule and keep the next task visible.',
            ),
            SizedBox(height: AppConstants.sectionSpacing),
            TodayEventCard(
              title: 'Morning meeting',
              timeRange: '09:30 - 10:00',
              location: 'Room A',
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
