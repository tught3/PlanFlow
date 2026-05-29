import 'package:flutter/material.dart';

import '../core/theme.dart';

class LocationResolutionStatus extends StatelessWidget {
  const LocationResolutionStatus({
    super.key,
    required this.hasLocationText,
    required this.isResolved,
    required this.isSearching,
    this.onResolve,
  });

  final bool hasLocationText;
  final bool isResolved;
  final bool isSearching;
  final VoidCallback? onResolve;

  @override
  Widget build(BuildContext context) {
    if (!hasLocationText) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final resolvedState = isResolved && !isSearching;
    final searchingState = isSearching && !resolvedState;
    final statusColor = searchingState
        ? const Color(0xFF1565C0)
        : resolvedState
            ? const Color(0xFF2E7D32)
            : const Color(0xFFB54708);
    final backgroundColor = searchingState
        ? const Color(0xFFE3F2FD)
        : resolvedState
            ? const Color(0xFFEAF7EF)
            : const Color(0xFFFFF4E5);
    final borderColor = searchingState
        ? const Color(0xFF90CAF9)
        : resolvedState
            ? const Color(0xFF9BD5AA)
            : const Color(0xFFF6C27A);
    final icon = searchingState
        ? Icons.sync_outlined
        : resolvedState
            ? Icons.check_circle_outline
            : Icons.location_searching_outlined;
    final title = searchingState
        ? '위치 찾는 중'
        : resolvedState
            ? '지도 위치 연결됨'
            : '지도 위치 미지정';
    final body = searchingState
        ? '지도 위치를 검색하고 있어요.'
        : resolvedState
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
          if (searchingState)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              ),
            )
          else
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
          if (!resolvedState && !searchingState && onResolve != null) ...[
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
