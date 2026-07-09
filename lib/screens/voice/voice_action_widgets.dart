part of 'voice_action_screen.dart';

class _VoiceCandidateSection extends StatelessWidget {
  const _VoiceCandidateSection({
    required this.action,
    required this.isLoading,
    required this.events,
    required this.rawText,
    required this.querySummary,
    required this.queryRangeLabel,
    required this.queryDayGroups,
    required this.selectedDeleteCount,
    required this.selectedDeleteEventIds,
    required this.disabled,
    required this.forceManualEdit,
    required this.allowDirectApply,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAdd,
    required this.onRetryVoice,
    required this.onOpenCalendar,
    required this.onRetrySync,
    required this.onOpenQueryResult,
    required this.onOpenEdit,
    required this.onApplyAndSave,
    required this.onDeleteSelected,
    required this.onToggleDeleteSelection,
    required this.onDelete,
    required this.buildChangePreviewText,
    this.groupEventIds = const <String>{},
    this.isConvertToPersonalRequested = false,
    this.onConvertToPersonal,
    this.diagnostics,
    this.message,
  });

  final VoiceScheduleAction action;
  final bool isLoading;
  final List<EventModel> events;
  final _CandidateLoadDiagnostics? diagnostics;
  final String? message;
  final String rawText;
  final String querySummary;
  final String queryRangeLabel;
  final List<_QueryDayGroup> queryDayGroups;
  final int selectedDeleteCount;
  final Set<String> selectedDeleteEventIds;
  final bool disabled;
  final bool forceManualEdit;
  final bool allowDirectApply;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAdd;
  final VoidCallback onRetryVoice;
  final VoidCallback onOpenCalendar;
  final Future<void> Function() onRetrySync;
  final void Function(EventModel event) onOpenQueryResult;
  final void Function(EventModel event) onOpenEdit;
  final void Function(EventModel event) onApplyAndSave;
  final VoidCallback onDeleteSelected;
  final void Function(EventModel event, bool selected) onToggleDeleteSelection;
  final void Function(EventModel event) onDelete;
  final String? Function(EventModel event) buildChangePreviewText;
  /// 그룹 일정으로 병합된 후보의 id 집합. 카드가 그룹 일정인지 판정해
  /// "직접 편집" 버튼을 숨기고 전환 라벨을 붙이는 데 쓴다.
  final Set<String> groupEventIds;
  /// 이번 발화가 그룹 일정을 개인 일정으로 전환하라는 요청인지.
  final bool isConvertToPersonalRequested;
  /// 그룹 일정을 개인 일정으로 전환하는 콜백. isConvertToPersonalRequested가
  /// true이고 카드가 그룹 일정일 때만 쓰인다.
  final void Function(EventModel event)? onConvertToPersonal;

  bool get _isQuery => action == VoiceScheduleAction.query;
  bool get _isDelete => action == VoiceScheduleAction.delete;
  bool get _isEdit => action == VoiceScheduleAction.edit;

  String get _title => _isQuery ? '단순 조회 결과' : '대상 일정';

  String? get _candidateCountText {
    final count = events.length;
    final targetQuery = diagnostics?.targetQuery.trim() ?? '';
    if (diagnostics == null && count == 0) {
      return null;
    }
    if (count > 0 && targetQuery.isNotEmpty) {
      return '$count개 후보 · 검색어: $targetQuery';
    }
    return '$count개 후보';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    debugPrint(
      'VoiceActionScreen candidate section build: action=${action.name} '
      'loading=$isLoading events=${events.length} '
      'diagnostics=${diagnostics?.toLogLine() ?? '(none)'}',
    );

    return Column(
      key: const ValueKey('voice-target-events-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (_candidateCountText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 18),
            child: Text(
              _candidateCountText!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          )
        else if (_isDelete && events.isNotEmpty)
          const SizedBox(height: 18),
        if (_isDelete && events.isNotEmpty) ...[
          KeyedSubtree(
            key: const ValueKey('voice-delete-candidate-list'),
            child: _DeleteCandidateInlineActions(
              events: events,
              disabled: disabled,
              selectedEventIds: selectedDeleteEventIds,
              selectedCount: selectedDeleteCount,
              onToggleSelection: onToggleDeleteSelection,
              onDeleteSelected: onDeleteSelected,
              onDelete: onDelete,
            ),
          ),
        ],
        if (!_isDelete || events.isEmpty) const SizedBox(height: 8),
        if (isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (events.isEmpty)
          _EmptyCard(
            message: message ?? '대상 일정을 찾지 못했어요. 캘린더 동기화 상태를 확인하거나 다시 말해 주세요.',
            rawText: rawText,
            showRecoveryActions: true,
            diagnosticsText: diagnostics?.toDisplayText(),
            onAdd: onAdd,
            onRetryVoice: onRetryVoice,
            onOpenCalendar: onOpenCalendar,
            onRetrySync: onRetrySync,
          )
        else if (_isQuery) ...[
          _QueryOverviewCard(
            summary: querySummary,
            rangeLabel: queryRangeLabel,
          ),
          const SizedBox(height: 12),
          ...queryDayGroups.map(
            (dayGroup) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _QueryDayGroupCard(
                dayGroup: dayGroup,
                actionLabel: actionLabel,
                actionIcon: actionIcon,
                isDanger: _isDelete,
                disabled: disabled,
                onTapEvent: onOpenQueryResult,
              ),
            ),
          ),
        ] else if (_isDelete)
          const SizedBox.shrink()
        else
          ...events.map((event) {
            final isGroupEvent = groupEventIds.contains(event.id);
            final isConvertTarget =
                isGroupEvent && _isEdit && isConvertToPersonalRequested;
            final changePreview = isConvertTarget
                ? '개인 일정으로 전환'
                : _isEdit
                    ? buildChangePreviewText(event)
                    : null;
            final effectiveActionLabel =
                isConvertTarget ? '개인 일정으로 전환' : actionLabel;
            final effectiveActionIcon =
                isConvertTarget ? Icons.person_outline : actionIcon;
            final VoidCallback? onDirectApply;
            if (isConvertTarget) {
              onDirectApply = onConvertToPersonal == null
                  ? null
                  : () => onConvertToPersonal!(event);
            } else if (_isEdit &&
                changePreview != null &&
                allowDirectApply &&
                !forceManualEdit) {
              onDirectApply = () => onApplyAndSave(event);
            } else if (isGroupEvent && _isEdit && changePreview != null) {
              // 그룹 일정은 개인 전용 편집 화면이 없으므로, 변경이 감지되면
              // allowDirectApply 여부와 무관하게 "바로 저장" 경로로만 반영한다.
              onDirectApply = () => onApplyAndSave(event);
            } else {
              onDirectApply = null;
            }
            // 그룹 일정은 개인 전용 편집 화면(_openEdit)을 재사용할 수 없으므로
            // "직접 편집"/단일 액션 버튼(onTap)을 비활성화한다.
            final VoidCallback? onTap = isGroupEvent
                ? null
                : () => _isEdit ? onOpenEdit(event) : onOpenQueryResult(event);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EventCandidateCard(
                event: event,
                actionLabel: effectiveActionLabel,
                actionIcon: effectiveActionIcon,
                isDanger: false,
                disabled: disabled,
                isGroupEvent: isGroupEvent,
                onTap: onTap,
                changePreviewText: changePreview,
                onDirectApply: onDirectApply,
              ),
            );
          }),
      ],
    );
  }
}

class _RankedEvent {
  const _RankedEvent({
    required this.event,
    required this.score,
    required this.matchScore,
  });

  final EventModel event;
  final int score;
  final int matchScore;
}

class _DateRange {
  const _DateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

class _VoiceRequestedTime {
  const _VoiceRequestedTime(this.hour, this.minute);

  final int hour;
  final int minute;
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({
    required this.title,
    required this.rawText,
    required this.description,
  });

  final String title;
  final String rawText;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
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
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '말한 내용',
              style: theme.textTheme.labelLarge?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              rawText.trim().isEmpty ? '내용이 비어 있어요.' : rawText.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroup {
  const _QueryDayGroup({
    required this.label,
    required this.events,
    required this.buckets,
  });

  final String label;
  final List<EventModel> events;
  final List<MapEntry<String, List<EventModel>>> buckets;
}

class _QueryOverviewCard extends StatelessWidget {
  const _QueryOverviewCard({
    required this.summary,
    required this.rangeLabel,
  });

  final String summary;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: const Color(0xFFEAF4FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF92BEE8), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.record_voice_over_outlined,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$rangeLabel 일정 요약',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textPrimary,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroupCard extends StatelessWidget {
  const _QueryDayGroupCard({
    required this.dayGroup,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final _QueryDayGroup dayGroup;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    dayGroup.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${dayGroup.events.length}개',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...dayGroup.buckets.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _QueryBucketSection(
                  label: entry.key,
                  events: entry.value,
                  actionLabel: actionLabel,
                  actionIcon: actionIcon,
                  isDanger: isDanger,
                  disabled: disabled,
                  onTapEvent: onTapEvent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryBucketSection extends StatelessWidget {
  const _QueryBucketSection({
    required this.label,
    required this.events,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final String label;
  final List<EventModel> events;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primaryMid,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
        ...events.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _QueryEventCard(
              event: event,
              actionLabel: actionLabel,
              actionIcon: actionIcon,
              isDanger: isDanger,
              disabled: disabled,
              onTap: () => onTapEvent(event),
            ),
          ),
        ),
      ],
    );
  }
}

class _QueryEventCard extends StatelessWidget {
  const _QueryEventCard({
    required this.event,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTap,
  });

  final EventModel event;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeStr = _formatTimeChip(startAt);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    timeStr,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      startAt == null
                          ? '시간 미정'
                          : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    if ((event.location ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 104,
                child: FilledButton.tonalIcon(
                  onPressed: disabled ? null : onTap,
                  icon: Icon(actionIcon, size: 18),
                  label: Text(
                    actionLabel,
                    textAlign: TextAlign.center,
                  ),
                  style: FilledButton.styleFrom(
                    foregroundColor:
                        isDanger ? colorScheme.onErrorContainer : null,
                    backgroundColor:
                        isDanger ? colorScheme.errorContainer : null,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTimeChip(DateTime? value) {
    if (value == null) {
      return '미정';
    }
    final hour = value.hour;
    final period = hour < 12
        ? '오전'
        : hour < 18
            ? '오후'
            : '저녁';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    final minute =
        value.minute == 0 ? '' : '\n${value.minute.toString().padLeft(2, '0')}';
    return '$period\n$displayHour시$minute';
  }
}

class _AddConfirmCard extends StatelessWidget {
  const _AddConfirmCard({
    required this.rawText,
    required this.onContinue,
  });

  final String rawText;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '일정 추가 확인',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '음성 원문을 확인한 뒤 일정 확인 화면으로 넘겨드립니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onContinue,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('확인 화면으로 이동'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChooserCard extends StatelessWidget {
  const _ActionChooserCard({
    required this.currentAction,
    required this.onSelected,
  });

  final VoiceScheduleAction currentAction;
  final ValueChanged<VoiceScheduleAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = <(VoiceScheduleAction, String, IconData)>[
      (VoiceScheduleAction.add, '추가', Icons.add_circle_outline),
      (VoiceScheduleAction.edit, '수정', Icons.edit_note),
      (VoiceScheduleAction.delete, '삭제', Icons.delete_outline),
      (VoiceScheduleAction.query, '조회', Icons.search),
    ];

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '무엇을 할까요?',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ...options.map((option) {
              final selected = currentAction == option.$1;
              final button = selected
                  ? FilledButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    );
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: button,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.message,
    this.rawText,
    this.showRecoveryActions = false,
    this.diagnosticsText,
    this.onAdd,
    this.onRetryVoice,
    this.onOpenCalendar,
    this.onRetrySync,
  });

  final String message;
  final String? rawText;
  final bool showRecoveryActions;
  final String? diagnosticsText;
  final VoidCallback? onAdd;
  final VoidCallback? onRetryVoice;
  final VoidCallback? onOpenCalendar;
  final Future<void> Function()? onRetrySync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showRecoveryActions) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: PlanFlowColors.primaryFaint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.cloud_off_outlined,
                      color: PlanFlowColors.primaryMid,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '저장된 일정이 앱 DB에서 보이지 않아요',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            if (diagnosticsText != null &&
                diagnosticsText!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '후보 조회 결과',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: PlanFlowColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                diagnosticsText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (showRecoveryActions) ...[
              const SizedBox(height: 12),
              if (rawText != null && rawText!.trim().isNotEmpty)
                Text(
                  '말한 내용: ${rawText!.trim()}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('새 일정으로 추가'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onRetryVoice,
                    icon: const Icon(Icons.mic_none),
                    label: const Text('다시 말하기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenCalendar,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('일정 탭 보기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onRetrySync == null
                        ? null
                        : () {
                            unawaited(onRetrySync!());
                          },
                    icon: const Icon(Icons.sync_outlined),
                    label: const Text('동기화 후 다시 찾기'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VoiceLocationResolution {
  const _VoiceLocationResolution({
    required this.event,
    required this.message,
  });

  final EventModel event;
  final String message;
}

/// "제목을 '주간 회의'로 바꿔줘", "이름을 팀 워크숍으로 변경해줘"처럼
/// 그룹 일정 제목 변경 발화에서 새 제목만 뽑아낸다. 매치되지 않으면 null.
String? _extractGroupTitleChange(String text) {
  final match = RegExp(
    '(?:제목|이름|명칭)\\s*(?:을|를|은|는)?\\s*[\'"]?(.+?)[\'"]?\\s*(?:으로|로)\\s*(?:변경|바꿔|수정|고쳐)',
  ).firstMatch(text);
  if (match == null) {
    return null;
  }
  final extracted = match.group(1)?.trim();
  if (extracted == null || extracted.isEmpty) {
    return null;
  }
  return extracted;
}

class _CandidateLoadDiagnostics {
  const _CandidateLoadDiagnostics({
    required this.action,
    required this.userIdAvailable,
    required this.totalEventCount,
    required this.filteredCount,
    required this.displayedCount,
    required this.targetQuery,
  });

  final String action;
  final bool userIdAvailable;
  final int totalEventCount;
  final int filteredCount;
  final int displayedCount;
  final String targetQuery;

  String toDisplayText() {
    return [
      'action=$action',
      'userId=${userIdAvailable ? '있음' : '없음'}',
      'totalEventCount=$totalEventCount',
      'filteredCount=$filteredCount',
      'displayedCount=$displayedCount',
      'targetQuery=${targetQuery.isEmpty ? '(비어 있음)' : targetQuery}',
    ].join('\n');
  }

  String toLogLine() => toDisplayText().replaceAll('\n', ' ');
}

class _CandidateLoadSnapshot {
  const _CandidateLoadSnapshot({
    required this.diagnostics,
    required this.events,
  });

  final _CandidateLoadDiagnostics diagnostics;
  final List<EventModel> events;
}

class _DeleteCandidateInlineActions extends StatelessWidget {
  const _DeleteCandidateInlineActions({
    required this.events,
    required this.disabled,
    required this.selectedEventIds,
    required this.selectedCount,
    required this.onToggleSelection,
    required this.onDeleteSelected,
    required this.onDelete,
  });

  final List<EventModel> events;
  final bool disabled;
  final Set<String> selectedEventIds;
  final int selectedCount;
  final void Function(EventModel event, bool selected) onToggleSelection;
  final VoidCallback onDeleteSelected;
  final void Function(EventModel event) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final materialLocalizations = MaterialLocalizations.of(context);

    return Container(
      key: const ValueKey('voice-delete-inline-actions'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '삭제할 일정을 선택해 주세요.',
            style: theme.textTheme.labelLarge?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '카드를 누르면 삭제 확인이 열리고, 여러 개는 왼쪽 체크로 선택할 수 있어요.',
            key: const ValueKey('voice-delete-inline-instruction'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          if (selectedCount > 0) ...[
            Text(
              '선택된 일정 $selectedCount개',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.error,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('voice-delete-selected-inline-button'),
              onPressed: disabled ? null : onDeleteSelected,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('선택 삭제'),
              style: FilledButton.styleFrom(
                foregroundColor: colorScheme.onErrorContainer,
                backgroundColor: colorScheme.errorContainer,
                minimumSize: const Size.fromHeight(44),
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ] else ...[
            Text(
              '선택된 일정 0개',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '여러 개를 지우려면 체크박스를 선택해 주세요.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary.withValues(alpha: 0.82),
              ),
            ),
            const SizedBox(height: 10),
          ],
          for (var index = 0; index < events.length; index += 1)
            _DeleteCandidateCard(
              key:
                  ValueKey('voice-delete-candidate-$index-${events[index].id}'),
              event: events[index],
              index: index,
              disabled: disabled,
              isSelected: selectedEventIds.contains(events[index].id),
              materialLocalizations: materialLocalizations,
              onToggleSelection: (selected) =>
                  onToggleSelection(events[index], selected),
              onDelete: () => onDelete(events[index]),
            ),
        ],
      ),
    );
  }
}

class _DeleteCandidateCard extends StatelessWidget {
  const _DeleteCandidateCard({
    super.key,
    required this.event,
    required this.index,
    required this.disabled,
    required this.isSelected,
    required this.materialLocalizations,
    required this.onToggleSelection,
    required this.onDelete,
  });

  final EventModel event;
  final int index;
  final bool disabled;
  final bool isSelected;
  final MaterialLocalizations materialLocalizations;
  final ValueChanged<bool> onToggleSelection;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        key: ValueKey('voice-delete-inline-button-$index-${event.id}'),
        color: isSelected
            ? PlanFlowColors.primaryFaint.withValues(alpha: 0.82)
            : PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        elevation: isSelected ? 1 : 0,
        shadowColor: PlanFlowColors.primary.withValues(alpha: 0.12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onDelete,
          child: Container(
            constraints: const BoxConstraints(minHeight: 82),
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? PlanFlowColors.primaryMid
                    : PlanFlowColors.primaryFaint,
                width: isSelected ? 1.3 : 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: disabled
                          ? null
                          : (value) => onToggleSelection(value ?? false),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w800,
                              height: 1.22,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _candidateMetaText(event, materialLocalizations),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: ValueKey('voice-delete-button-$index-${event.id}'),
                  onPressed: disabled ? null : onDelete,
                  style: FilledButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    backgroundColor: colorScheme.errorContainer
                        .withValues(alpha: isSelected ? 0.72 : 0.52),
                    minimumSize: const Size.fromHeight(40),
                    textStyle: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  child: const Text('삭제'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _candidateMetaText(
    EventModel event,
    MaterialLocalizations materialLocalizations,
  ) {
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeText = startAt == null
        ? '시간 미정'
        : '${materialLocalizations.formatFullDate(startAt)} · ${materialLocalizations.formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}';
    final location = event.location?.trim();
    if (location == null || location.isEmpty) {
      return timeText;
    }
    return '$timeText · $location';
  }
}

class _EventCandidateCard extends StatelessWidget {
  const _EventCandidateCard({
    required this.event,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTap,
    this.isGroupEvent = false,
    this.changePreviewText,
    this.onDirectApply,
  });

  final EventModel event;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;

  /// null이면 이 카드에서 "직접 편집"/단일 액션 버튼 탭을 비활성화한다.
  /// 그룹 일정은 개인 전용 편집 화면(event_edit_screen)을 재사용할 수 없어
  /// 호출부가 null을 넘긴다.
  final VoidCallback? onTap;

  /// 그룹 일정으로 병합된 후보인지. true면 "직접 편집" 버튼을 숨긴다.
  final bool isGroupEvent;

  /// 감지된 변경 내용 요약 (예: "1/22(수) 오전 9시"). null이면 표시 안 함.
  final String? changePreviewText;

  /// 변경사항을 바로 저장하는 콜백. null이면 바로저장 버튼 표시 안 함.
  final VoidCallback? onDirectApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final hasDirectApply = onDirectApply != null;
    final canTap = !disabled && onTap != null;

    return Card(
      key: isDanger
          ? ValueKey('voice-delete-candidate-${event.id}')
          : ValueKey('voice-action-candidate-${event.id}'),
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: hasDirectApply
              ? PlanFlowColors.primary.withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: hasDirectApply ? 1.0 : 0.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: canTap ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: PlanFlowColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          startAt == null
                              ? '시간 미정'
                              : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: changePreviewText != null
                                ? PlanFlowColors.textSecondary
                                    .withValues(alpha: 0.6)
                                : PlanFlowColors.textSecondary,
                            decoration: changePreviewText != null
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (changePreviewText != null) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              const Icon(
                                Icons.arrow_forward,
                                size: 13,
                                color: PlanFlowColors.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                changePreviewText!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: PlanFlowColors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if ((event.location ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            event.location!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!hasDirectApply) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 104,
                      child: FilledButton.tonalIcon(
                        key: isDanger
                            ? ValueKey('voice-delete-button-${event.id}')
                            : null,
                        onPressed: canTap ? onTap : null,
                        icon: Icon(actionIcon, size: 18),
                        label: Text(
                          actionLabel,
                          textAlign: TextAlign.center,
                        ),
                        style: FilledButton.styleFrom(
                          foregroundColor:
                              isDanger ? colorScheme.onErrorContainer : null,
                          backgroundColor:
                              isDanger ? colorScheme.errorContainer : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              // 변경사항이 감지된 경우: 바로저장 (+ 그룹 일정이 아니면 직접편집) 버튼 행
              if (hasDirectApply) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: disabled ? null : onDirectApply,
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('바로 저장'),
                      ),
                    ),
                    // 그룹 일정은 개인 전용 편집 화면이 없어 "직접 편집" 버튼을
                    // 표시하지 않는다.
                    if (!isGroupEvent) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: canTap ? onTap : null,
                        child: const Text('직접 편집'),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
