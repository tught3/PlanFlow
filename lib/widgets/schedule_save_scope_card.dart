import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 일정 저장 범위 선택지.
///
/// event_edit_screen.dart와 confirm_screen.dart가 공유하는 단일 enum이다.
/// 과거에는 각 화면이 `_ScheduleSaveTarget`/`_ConfirmSaveTarget`이라는
/// private enum을 각자 들고 있었으나, 로직이 완전히 동일해 이 파일로 통합했다.
enum ScheduleSaveTarget {
  personalOnly,
  personalAndGroup,
  groupOnly,
}

/// "저장 범위" 선택 카드.
///
/// 기존에는 [SegmentedButton]으로 3개 세그먼트를 가로로 나열했으나,
/// 그룹명이 길어지면 라벨이 아이콘과 어긋나거나 어색하게 줄바꿈되는
/// 문제가 있었다. 이 위젯은 대신 세로로 쌓인 전체 너비 선택 행을
/// 사용해 긴 그룹명도 자연스럽게 2줄까지 줄바꿈되도록 한다.
class ScheduleSaveScopeCard extends StatelessWidget {
  const ScheduleSaveScopeCard({
    super.key,
    required this.groupName,
    required this.selected,
    required this.onChanged,
  });

  final String groupName;
  final ScheduleSaveTarget selected;
  final ValueChanged<ScheduleSaveTarget> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_2_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '저장 범위',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '이 일정을 나만 볼지, 선택된 그룹에도 공유할지 정해 주세요.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            _buildOptionRow(
              context,
              target: ScheduleSaveTarget.personalOnly,
              icon: Icons.person_outline,
              label: '개인 일정만',
            ),
            const SizedBox(height: 8),
            _buildOptionRow(
              context,
              target: ScheduleSaveTarget.personalAndGroup,
              icon: Icons.compare_arrows_outlined,
              label: '개인 + $groupName',
            ),
            const SizedBox(height: 8),
            _buildOptionRow(
              context,
              target: ScheduleSaveTarget.groupOnly,
              icon: Icons.groups_outlined,
              label: '$groupName만',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionRow(
    BuildContext context, {
    required ScheduleSaveTarget target,
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    final isSelected = selected == target;
    return Material(
      color: isSelected ? PlanFlowColors.primaryFaint : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(target),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? PlanFlowColors.primaryLight
                  : PlanFlowColors.primaryFaint,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: isSelected
                    ? PlanFlowColors.primary
                    : PlanFlowColors.textSecondary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? PlanFlowColors.primary
                    : PlanFlowColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isSelected
                        ? PlanFlowColors.primary
                        : PlanFlowColors.textPrimary,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
