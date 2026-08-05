import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 음성 대화 모드 진입 전 사용자에게 광고 시청 동의를 받는 다이얼로그.
///
/// - true  : 사용자가 "광고 보고 시작하기" 선택
/// - false : 사용자가 "취소" 선택 또는 바깥 탭으로 닫음
Future<bool> showVoiceConversationAdDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => const _VoiceConversationAdDialog(),
  );
  return result ?? false;
}

class _VoiceConversationAdDialog extends StatelessWidget {
  const _VoiceConversationAdDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(
        Icons.record_voice_over_outlined,
        color: PlanFlowColors.primaryMid,
        size: 32,
      ),
      title: const Text('대화 모드'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '짧은 광고를 시청하면 AI와 대화하며 일정을 관리할 수 있어요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: PlanFlowColors.primaryFaint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '마이크를 길게 눌러 음성으로 “5시에 미팅 추가해줘”처럼 말하면 됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PlanFlowColors.textSecondary,
                  side: const BorderSide(color: PlanFlowColors.primaryFaint),
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: const Text('광고 보고 시작하기'),
                style: FilledButton.styleFrom(
                  backgroundColor: PlanFlowColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
