import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../services/calendar_sync_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    CalendarSyncService? calendarSyncService,
    bool? envConfigured,
  })  : _calendarSyncService = calendarSyncService,
        _envConfigured = envConfigured;

  final CalendarSyncService? _calendarSyncService;
  final bool? _envConfigured;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> _reminderOptions = <int>[15, 30, 60, 120];

  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;

  late final CalendarSyncService _calendarSyncService;

  CalendarSyncSummary? _calendarSyncSummary;
  bool _isLoadingCalendarStatus = true;

  @override
  void initState() {
    super.initState();
    _calendarSyncService = widget._calendarSyncService ??
        CalendarSyncService(
          googleClientId: AppEnv.googleAndroidClientId,
        );
    _loadCalendarStatus();
  }

  Future<void> _loadCalendarStatus() async {
    setState(() {
      _isLoadingCalendarStatus = true;
    });

    final summary = await _calendarSyncService.fetchStatus();
    if (!mounted) {
      return;
    }

    setState(() {
      _calendarSyncSummary = summary;
      _isLoadingCalendarStatus = false;
    });
  }

  Future<void> _pickTime({
    required BuildContext context,
    required bool isMorning,
  }) async {
    final initialTime = isMorning ? _morningBriefingAt : _eveningBriefingAt;
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (!mounted || picked == null) {
      return;
    }

    setState(() {
      if (isMorning) {
        _morningBriefingAt = picked;
      } else {
        _eveningBriefingAt = picked;
      }
    });
  }

  void _resetToDefaults() {
    setState(() {
      _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
      _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
      _defaultReminderMinutes = 60;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Settings reset to local defaults.'),
      ),
    );
  }

  void _saveLocalChanges() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Saved locally for this session. Backend persistence is not connected yet.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final morningLabel = _formatTime(context, _morningBriefingAt);
    final eveningLabel = _formatTime(context, _eveningBriefingAt);
    final envConfigured = widget._envConfigured ?? AppEnv.isConfigured;

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Reset local defaults',
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            _HeaderCard(
              morningLabel: morningLabel,
              eveningLabel: eveningLabel,
              reminderMinutes: _defaultReminderMinutes,
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Briefing times',
              subtitle:
                  'Choose when the morning and evening briefings should run on this device.',
              child: Column(
                children: [
                  _TimeSettingTile(
                    title: 'Morning briefing',
                    subtitle: 'Daily planning kickoff',
                    value: morningLabel,
                    icon: Icons.wb_sunny_outlined,
                    onTap: () => _pickTime(context: context, isMorning: true),
                  ),
                  const Divider(height: 1),
                  _TimeSettingTile(
                    title: 'Evening briefing',
                    subtitle: 'Wrap-up and next-day prep',
                    value: eveningLabel,
                    icon: Icons.nightlight_outlined,
                    onTap: () => _pickTime(context: context, isMorning: false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Default reminder minutes',
              subtitle:
                  'This becomes the pre-action reminder used for new items until you change it.',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _reminderOptions
                    .map(
                      (minutes) => FilterChip(
                        label: Text('$minutes min'),
                        selected: _defaultReminderMinutes == minutes,
                        onSelected: (_) {
                          setState(() {
                            _defaultReminderMinutes = minutes;
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Calendar sync status',
              subtitle:
                  'Secret values are hidden. Only configured or not configured is shown here.',
              child: Column(
                children: [
                  _StatusRow(
                    label: 'Google Calendar',
                    value: _calendarStatusLabel(_calendarSyncSummary?.google),
                    icon: Icons.cloud_sync_outlined,
                    isConfigured:
                        _isCalendarConfigured(_calendarSyncSummary?.google),
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: 'Naver Calendar',
                    value: _calendarStatusLabel(_calendarSyncSummary?.naver),
                    icon: Icons.sync_alt_outlined,
                    isConfigured:
                        _isCalendarConfigured(_calendarSyncSummary?.naver),
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: 'Local sync mode',
                    value: 'Local only',
                    icon: Icons.device_hub_outlined,
                    isConfigured: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Env / config status',
              subtitle:
                  'These checks confirm whether required environment values are present without exposing them.',
              child: Column(
                children: [
                  _StatusRow(
                    label: 'Supabase + OpenAI env',
                    value: envConfigured ? 'Configured' : 'Not configured',
                    icon: Icons.code_outlined,
                    isConfigured: envConfigured,
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: 'Backend persistence',
                    value: 'Not configured',
                    icon: Icons.storage_outlined,
                    isConfigured: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Local changes only',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This screen is fully usable now, but changes stay in memory until repository-backed settings persistence is connected.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _resetToDefaults,
                            child: const Text('Reset'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _saveLocalChanges,
                            child: const Text('Save locally'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(BuildContext context, TimeOfDay timeOfDay) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      timeOfDay,
      alwaysUse24HourFormat: true,
    );
  }

  String _calendarStatusLabel(CalendarIntegrationResult? result) {
    if (_isLoadingCalendarStatus || result == null) {
      return 'Checking...';
    }

    return switch (result.status) {
      CalendarIntegrationStatus.notConfigured => 'Not configured',
      CalendarIntegrationStatus.signedOut => 'Configured, signed out',
      CalendarIntegrationStatus.ready => 'Ready',
      CalendarIntegrationStatus.syncing => 'Syncing',
      CalendarIntegrationStatus.synced => 'Synced',
      CalendarIntegrationStatus.unsupported => 'Unsupported',
      CalendarIntegrationStatus.failed => 'Status check failed',
    };
  }

  bool _isCalendarConfigured(CalendarIntegrationResult? result) {
    if (result == null) {
      return false;
    }

    return switch (result.status) {
      CalendarIntegrationStatus.signedOut ||
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.syncing ||
      CalendarIntegrationStatus.synced =>
        true,
      CalendarIntegrationStatus.notConfigured ||
      CalendarIntegrationStatus.unsupported ||
      CalendarIntegrationStatus.failed =>
        false,
    };
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.morningLabel,
    required this.eveningLabel,
    required this.reminderMinutes,
  });

  final String morningLabel;
  final String eveningLabel;
  final int reminderMinutes;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preferences',
            style: theme.textTheme.labelLarge?.copyWith(
              color: const Color(0xFFA8D4F0),
              fontSize: 9,
              letterSpacing: 0.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Briefings and reminders',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeaderPill(
                icon: Icons.wb_sunny_outlined,
                label: 'Morning $morningLabel',
              ),
              _HeaderPill(
                icon: Icons.nightlight_outlined,
                label: 'Evening $eveningLabel',
              ),
              _HeaderPill(
                icon: Icons.notifications_none,
                label: '$reminderMinutes min reminders',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _TimeSettingTile extends StatelessWidget {
  const _TimeSettingTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: PlanFlowColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.isConfigured,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isConfigured;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        isConfigured ? PlanFlowColors.primaryMid : PlanFlowColors.textSecondary;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primary,
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          isConfigured
              ? Icons.check_circle_outline
              : Icons.remove_circle_outline,
          color: color,
        ),
      ],
    );
  }
}
