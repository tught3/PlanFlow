import 'package:flutter/material.dart';

import '../core/theme.dart';

const Key voiceConversationExamplesPanelKey =
    ValueKey('voiceConversationExamplesPanel');
const Key voiceConversationIntroTextKey =
    ValueKey('voiceConversationIntroText');

/// 음성 대화 모드 진입 전 사용자에게 광고 시청 동의를 받는 다이얼로그.
///
/// - true  : 사용자가 "광고 보고 시작하기" 선택
/// - false : 사용자가 "취소" 선택 또는 바깥 탭으로 닫음
Future<bool> showVoiceConversationAdDialog(
  BuildContext context, {
  int? freeTrialCount,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => _VoiceConversationAdDialog(
      freeTrialCount: freeTrialCount,
    ),
  );
  return result ?? false;
}

class _VoiceConversationAdDialog extends StatelessWidget {
  const _VoiceConversationAdDialog({this.freeTrialCount});

  final int? freeTrialCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const examples = <String>[
      '내일 오후 2시에 팀 회의 추가해줘',
      '다음 주 금요일 일정 보여줘',
      '내일 일정 오후 5시 반으로 미뤄줘',
      '첫 번째 일정 장소를 본관 3층으로 바꿔줘',
      '첫 번째 일정 삭제해줘',
      '매주 월요일 오전 9시에 운동 일정 추가해줘',
    ];

    return AlertDialog(
      icon: Icon(
        Icons.record_voice_over_outlined,
        color: PlanFlowColors.primaryMid,
        size: 32,
      ),
      title: const Text('대화 모드'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (freeTrialCount != null) ...[
            Text(
              '무료 횟수($freeTrialCount회)를 모두 소진하였습니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            '짧은 광고를 시청하면 AI와 대화하며 일정을 관리할 수 있어요.',
            key: voiceConversationIntroTextKey,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
              fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) + 2,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            key: voiceConversationExamplesPanelKey,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: PlanFlowColors.primaryFaint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '이렇게 말해보세요',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.primaryMid,
                    fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) + 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                for (final example in examples) ...[
                  Text(
                    '• $example',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.primaryMid,
                      fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) + 2,
                    ),
                  ),
                  if (example != examples.last) const SizedBox(height: 4),
                ],
              ],
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
