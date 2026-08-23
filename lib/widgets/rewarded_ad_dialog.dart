import 'package:flutter/material.dart';

import '../core/theme.dart';

class RewardedAdDialog extends StatelessWidget {
  const RewardedAdDialog({
    super.key,
    this.onWatchAd,
    this.onCancel,
  });

  final VoidCallback? onWatchAd;
  final VoidCallback? onCancel;

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => RewardedAdDialog(
        onWatchAd: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(
        Icons.auto_awesome_outlined,
        color: PlanFlowColors.primaryMid,
        size: 32,
      ),
      title: const Text('AI가 일정을 분석합니다'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '오늘 무료 AI 일정 정리 2회를 모두 사용했어요.\n'
            '광고를 시청하면 AI 자동 정리를 1회 더 사용할 수 있어요.',
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
              '광고를 안 봐도 직접 입력으로 일정을 추가할 수 있어요.',
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
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: PlanFlowColors.textSecondary,
                  side: const BorderSide(color: PlanFlowColors.primaryFaint),
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('직접 입력'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: onWatchAd,
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: const Text('광고 보고 분석'),
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

/// 광고 표시 중 로딩 오버레이.
class RewardedAdLoadingOverlay extends StatelessWidget {
  const RewardedAdLoadingOverlay({
    super.key,
    this.stage = 'loading',
  });

  /// 'loading' | 'shown' 등 진행 단계 라벨.
  final String stage;

  static OverlayEntry? _currentOverlay;

  static void show(BuildContext context, {String stage = 'loading'}) {
    hide();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => RewardedAdLoadingOverlay(stage: stage),
    );
    _currentOverlay = entry;
    overlay.insert(entry);
  }

  static void hide() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (stage) {
      'shown' => '광고 표시 중…',
      'loading' => '광고 준비 중…',
      _ => '잠시만 기다려 주세요…',
    };
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
