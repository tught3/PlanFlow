import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../widgets/planflow_voice_fab.dart';
import 'widgets/early_bird_signup_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppConstants.defaultPadding,
            AppConstants.defaultPadding,
            AppConstants.defaultPadding,
            120,
          ),
          children: [
            _HomeHeader(onVoice: () => context.push(AppRoutes.voice)),
            const SizedBox(height: 18),
            _HomeBriefingCard(todayLabel: todayLabel),
            const SizedBox(height: AppConstants.sectionSpacing),
            _QuickActionCard(
              onVoice: () => context.push(AppRoutes.voice),
              onCalendar: () => context.go(AppRoutes.calendar),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _TodaySectionHeader(onRefresh: _reloadTodayEvents),
            const SizedBox(height: AppConstants.sectionSpacing),
            _HomeMessageCard(
              icon: Icons.calendar_month_outlined,
              title: '오늘 등록된 일정이 없습니다',
              message: '새 일정을 말로 추가하면 이곳에 오늘 일정과 준비물이 정리됩니다.',
              primaryActionLabel: '말로 일정 추가',
              primaryIcon: Icons.mic_none,
              onPrimaryAction: () => context.push(AppRoutes.voice),
              secondaryActionLabel: '일정 탭 보기',
              onSecondaryAction: () => context.go(AppRoutes.calendar),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            const EarlyBirdSignupCard(),
          ],
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
    );
  }

  void _reloadTodayEvents() {}

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

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onVoice});

  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'PlanFlow',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              color: PlanFlowColors.primaryMid,
              letterSpacing: -1.0,
            ),
          ),
        ),
        IconButton(
          tooltip: '음성 입력',
          onPressed: onVoice,
          icon: const Icon(
            Icons.mic_none,
            size: 34,
            color: PlanFlowColors.primary,
          ),
        ),
      ],
    );
  }
}

class _HomeBriefingCard extends StatelessWidget {
  const _HomeBriefingCard({required this.todayLabel});

  final String todayLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryMid,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            todayLabel,
            style: theme.textTheme.labelLarge?.copyWith(
              color: PlanFlowColors.briefingLabel,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '오늘 일정과 준비를\n한눈에 확인하세요.',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _BriefingPill(icon: Icons.mic_none, label: '음성 입력'),
              _BriefingPill(
                icon: Icons.event_note_outlined,
                label: '일정 정리',
              ),
              _BriefingPill(
                icon: Icons.notifications_none,
                label: '알림 준비',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.onVoice,
    required this.onCalendar,
  });

  final VoidCallback onVoice;
  final VoidCallback onCalendar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _HomeFrame(
      child: Row(
        children: [
          Expanded(
            child: _QuickActionButton(
              icon: Icons.mic_none,
              title: '말로 추가',
              subtitle: '일정 음성 입력',
              onTap: onVoice,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _QuickActionButton(
              icon: Icons.event_note_outlined,
              title: '일정 보기',
              subtitle: '캘린더 탭 이동',
              onTap: onCalendar,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: [
                const Icon(
                  Icons.cloud_done_outlined,
                  color: PlanFlowColors.primaryMid,
                ),
                const SizedBox(height: 6),
                Text(
                  '백업 준비',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: PlanFlowColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '계정별 저장',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Icon(icon, color: PlanFlowColors.primaryMid),
            const SizedBox(height: 6),
            Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: PlanFlowColors.primary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _BriefingPill extends StatelessWidget {
  const _BriefingPill({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _TodaySectionHeader extends StatelessWidget {
  const _TodaySectionHeader({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Text(
          '오늘 일정',
          style: theme.textTheme.titleMedium?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('새로고침'),
        ),
      ],
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
