import 'package:flutter/material.dart';

import '../core/theme.dart';

class LocationResolutionStatus extends StatelessWidget {
  const LocationResolutionStatus({
    super.key,
    required this.hasLocationText,
    required this.isResolved,
    this.onResolve,
  });

  final bool hasLocationText;
  final bool isResolved;
  final VoidCallback? onResolve;

  @override
  Widget build(BuildContext context) {
    if (!hasLocationText) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final statusColor =
        isResolved ? const Color(0xFF2E7D32) : const Color(0xFFB54708);
    final backgroundColor =
        isResolved ? const Color(0xFFEAF7EF) : const Color(0xFFFFF4E5);
    final borderColor =
        isResolved ? const Color(0xFF9BD5AA) : const Color(0xFFF6C27A);
    final icon = isResolved
        ? Icons.check_circle_outline
        : Icons.location_searching_outlined;
    final title = isResolved ? '지도 위치 연결됨' : '지도 위치 미지정';
    final body = isResolved
        ? '스마트준비알람이 이 좌표로 이동시간을 계산합니다.'
        : '장소명만 저장된 상태예요. 스마트준비알람이 부정확할 수 있으니 지도에서 위치를 지정해 주세요.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!isResolved && onResolve != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onResolve,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('지도 지정'),
            ),
          ],
        ],
      ),
    );
  }
}
