import 'package:flutter/material.dart';

import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../models/group_event_model.dart';

/// 그룹 일정 하나를 보여주는 공개 타일 위젯.
///
/// [GroupEventListScreen]의 내부 `_GroupEventListTile`에서 추출했으며
/// 시각적 스타일을 동일하게 유지한다.
class GroupEventTile extends StatelessWidget {
  const GroupEventTile({
    super.key,
    required this.event,
    this.ownerName,
    this.onTap,
  });

  final GroupEventModel event;

  /// 비어 있거나 null이면 소유자 행을 표시하지 않는다.
  final String? ownerName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final localStart = planflowLocal(event.startAt);
    final localEnd = planflowLocal(event.endAt);

    // 시간 레이블 (종일 / 같은 날 범위 / 다른 날 범위)
    final timeLabel = event.allDay
        ? '종일'
        : (localStart.year == localEnd.year &&
                localStart.month == localEnd.month &&
                localStart.day == localEnd.day)
            ? '${_timeLabel(context, localStart)} - ${_timeLabel(context, localEnd)}'
            : '${_dateLabel(localStart)} ${_timeLabel(context, localStart)} - '
                '${_dateLabel(localEnd)} ${_timeLabel(context, localEnd)}';

    final hasOwner =
        ownerName != null && ownerName!.trim().isNotEmpty;

    return Card(
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 제목 + 상태 칩
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.title,
                      style:
                          Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                  ),
                  _TileChip(label: _statusLabel(event.status)),
                ],
              ),
              const SizedBox(height: 8),
              // 시간 레이블
              Text(
                timeLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              // 소유자 행 (ownerName이 있을 때만)
              if (hasOwner) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.person_outline,
                      size: 14,
                      color: PlanFlowColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '공유 · ${ownerName!.trim()}',
                      style:
                          Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                              ),
                    ),
                  ],
                ),
              ],
              // 장소
              if ((event.location ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  event.location!.trim(),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
              const SizedBox(height: 10),
              // 종일/반복 칩
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (event.allDay)
                    _TileChip(
                      label: '종일',
                      backgroundColor: PlanFlowColors.tagDoneBg,
                      textColor: PlanFlowColors.tagDoneText,
                    ),
                  _TileChip(label: _recurrenceLabel(event.recurrenceType)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 상태 레이블 ──────────────────────────────────────────────────────────────

String _statusLabel(String status) {
  return switch (status) {
    'active' => '활성',
    'cancelled' => '취소됨',
    'archived' => '보관됨',
    _ => status,
  };
}

// ─── 반복 레이블 ──────────────────────────────────────────────────────────────

String _recurrenceLabel(String recurrenceType) {
  return switch (recurrenceType) {
    'none' => '반복 없음',
    'daily' => '매일 반복',
    'weekly' => '매주 반복',
    'monthly' => '매월 반복',
    _ => recurrenceType,
  };
}

// ─── 시간 포맷 헬퍼 ───────────────────────────────────────────────────────────

String _timeLabel(BuildContext context, DateTime value) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(value),
    alwaysUse24HourFormat: false,
  );
}

String _dateLabel(DateTime value) {
  return '${value.year}.'
      '${value.month.toString().padLeft(2, '0')}.'
      '${value.day.toString().padLeft(2, '0')}';
}

// ─── 인라인 칩 위젯 ───────────────────────────────────────────────────────────
// (private _InfoChip 대신 이 파일 전용으로 인라인 구현)

class _TileChip extends StatelessWidget {
  const _TileChip({
    required this.label,
    this.backgroundColor = PlanFlowColors.tagNormalBg,
    this.textColor = PlanFlowColors.tagNormalText,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
