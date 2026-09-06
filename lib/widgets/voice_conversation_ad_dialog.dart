import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/remote_config_service.dart';

const Key voiceConversationExamplesPanelKey =
    ValueKey('voiceConversationExamplesPanel');
const Key voiceConversationIntroTextKey =
    ValueKey('voiceConversationIntroText');

/// 음성 대화 모드 진입 전 사용자에게 광고 시청 동의를 받는 다이얼로그.
///
/// - true  : 사용자가 "광고 보고 시작하기" 선택
/// - false : 사용자가 "취소" 선택 또는 바깥 탭으로 닫음
///
/// [initialRemaining]/[dailyRemaining]은 호출측(게이트)이 이미 조회해 둔
/// [VoiceConversationEntitlementPeek]의 잔여값을 그대로 전달한다. 이 다이얼로그는
/// 무료 잔여가 모두 소진된 경우에만 호출되므로 두 값 모두 0으로 들어오는
/// 것이 정상이지만, 값이 전달되지 않은 기존 호출부(테스트 등)와의 하위
/// 호환을 위해 optional로 둔다. 값이 있고 둘 다 소진 상태일 때만 "무료
/// 소진" 안내 문구를 노출한다.
Future<bool> showVoiceConversationAdDialog(
  BuildContext context, {
  int? initialRemaining,
  int? dailyRemaining,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => _VoiceConversationAdDialog(
      initialRemaining: initialRemaining,
      dailyRemaining: dailyRemaining,
    ),
  );
  return result ?? false;
}

class _VoiceConversationAdDialog extends StatelessWidget {
  const _VoiceConversationAdDialog({
    this.initialRemaining,
    this.dailyRemaining,
  });

  /// 게이트가 peek()으로 조회한 최초 누적 무료 잔여 횟수(정보 표시용).
  final int? initialRemaining;

  /// 게이트가 peek()으로 조회한 일일 무료 잔여 횟수(정보 표시용).
  final int? dailyRemaining;

  /// 두 값이 모두 전달됐고(null이 아니고) 모두 소진(<=0)됐을 때만 true.
  bool get _quotaExhausted {
    final initial = initialRemaining;
    final daily = dailyRemaining;
    return initial != null && daily != null && initial <= 0 && daily <= 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final introText = _quotaExhausted
        ? '오늘 무료 AI일정대화 '
            '${RemoteConfigService.voiceConversationDailyFreeCount}회를 '
            '모두 사용했어요.\n'
            '짧은 광고를 시청하면 AI와 대화하며 일정을 관리할 수 있어요.'
        : '짧은 광고를 시청하면 AI와 대화하며 일정을 관리할 수 있어요.';
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
          Text(
            introText,
            key: voiceConversationIntroTextKey,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
              fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) + 2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '무료 사용 횟수를 모두 사용한 뒤에도 광고 시청 후 계속 이용할 수 있어요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
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
