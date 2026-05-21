import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../widgets/planflow_logo.dart';

class VoiceLauncherScreen extends StatelessWidget {
  const VoiceLauncherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const PlanFlowLogo(fontSize: 24),
        backgroundColor: PlanFlowColors.background,
        foregroundColor: PlanFlowColors.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            Text(
              '어떤 방식으로 말할까요?',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '홈 위젯에서 바로 들어온 경우, 선택한 화면에서 음성 인식이 자동으로 시작됩니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            _VoiceLauncherCard(
              icon: Icons.mic_rounded,
              title: '일정 추가',
              description: '새 일정이나 일정 수정을 한 번에 말합니다.',
              onTap: () => context.go('${AppRoutes.voice}?autoStart=1'),
            ),
            const SizedBox(height: 12),
            _VoiceLauncherCard(
              icon: Icons.forum_rounded,
              title: 'AI 자동대화',
              description: '조회, 수정, 삭제를 이어서 자연스럽게 말합니다.',
              onTap: () =>
                  context.go('${AppRoutes.voiceConversation}?autoStart=1'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceLauncherCard extends StatelessWidget {
  const _VoiceLauncherCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: PlanFlowColors.primaryFaint),
            boxShadow: [
              BoxShadow(
                color: PlanFlowColors.primary.withValues(alpha: 0.07),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: PlanFlowColors.active.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: PlanFlowColors.active, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: PlanFlowColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
