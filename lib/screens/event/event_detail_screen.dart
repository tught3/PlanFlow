import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';

class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({super.key});

  static const _sampleTitle = '주간 영업 미팅';
  static const _sampleTime = '2026-05-01 14:00 - 15:00';
  static const _sampleLocation = '서울역 인근 회의실 A';
  static const _sampleMemo = '이번 주 우선순위 고객과 진행 상황을 정리하고, 다음 액션을 확정합니다.';
  static const _sampleSupplies = <String>[
    '노트북',
    '충전기',
    '명함',
    '회의 자료',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('이벤트 상세'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go(AppRoutes.eventEdit),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('편집'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            _HeaderCard(
              title: _sampleTitle,
              time: _sampleTime,
              critical: true,
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _InfoCard(
              title: '기본 정보',
              children: [
                _InfoRow(label: '시간', value: _sampleTime),
                _InfoRow(label: '장소', value: _sampleLocation),
                _InfoRow(
                  label: '중요 상태',
                  value: '중요 일정',
                  valueColor: theme.colorScheme.error,
                ),
              ],
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _InfoCard(
              title: '준비물',
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _sampleSupplies
                      .map(
                        (item) => Chip(
                          backgroundColor: PlanFlowColors.tagNormalBg,
                          side: const BorderSide(
                            color: PlanFlowColors.primaryFaint,
                            width: 0.5,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          label: Text(item),
                          labelStyle: theme.textTheme.labelSmall?.copyWith(
                            color: PlanFlowColors.primaryMid,
                            fontSize: 9,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _InfoCard(
              title: '메모',
              children: [
                Text(
                  _sampleMemo,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.eventEdit),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('이벤트 편집'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.title,
    required this.time,
    required this.critical,
  });

  final String title;
  final String time;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (critical)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: PlanFlowColors.tagNormalBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '중요',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.error,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              time,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = <Widget>[];

    for (final child in children) {
      if (sections.isNotEmpty) {
        sections.add(const SizedBox(height: 12));
      }
      sections.add(child);
    }

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
            const SizedBox(height: 12),
            ...sections,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
