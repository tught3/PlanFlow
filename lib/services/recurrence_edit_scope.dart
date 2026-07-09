import 'package:flutter/material.dart';

import '../data/models/event_model.dart';
import '../widgets/planflow_action_buttons.dart';
import '../widgets/recurrence_selector.dart';

/// 반복 일정을 수정할 때 어느 범위에 적용할지를 나타낸다.
/// [lib/screens/event/event_edit_screen.dart]의 `_chooseRecurrenceEditScopeSafe`가
/// 쓰는 'single'/'future'/'all' 문자열 스킴과 동일한 의미를 갖는다(화면별로
/// 독립 구현이며, 편집화면 코드를 수정하지 않기 위해 그쪽은 그대로 둔다).
enum RecurrenceEditScope { single, future, all }

/// "이 일정만 / 이후 모든 일정 / 전체 반복 일정" 선택 다이얼로그.
/// 사용자가 바깥을 탭해 취소하면 null을 반환한다.
Future<RecurrenceEditScope?> chooseRecurrenceEditScope(BuildContext context) {
  return showDialog<RecurrenceEditScope>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('반복 일정 수정'),
      content: const Text('반복 일정입니다. 어떤 범위에 수정 내용을 적용할까요?'),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      actions: [
        PlanFlowActionButtons(
          buttons: [
            PlanFlowActionButton(
              label: '이 일정만',
              onPressed: () =>
                  Navigator.of(context).pop(RecurrenceEditScope.single),
              type: ActionButtonType.secondary,
              flex: 1,
            ),
            PlanFlowActionButton(
              label: '이후 모든 일정',
              onPressed: () =>
                  Navigator.of(context).pop(RecurrenceEditScope.future),
              type: ActionButtonType.secondary,
              flex: 1,
            ),
            PlanFlowActionButton(
              label: '전체 반복 일정',
              onPressed: () =>
                  Navigator.of(context).pop(RecurrenceEditScope.all),
              type: ActionButtonType.primary,
              flex: 2,
            ),
          ],
        ),
      ],
    ),
  );
}

/// 반복 계열에서 분리된 단일/이후 이벤트를 만든다 (신규 insert용, id는 빈 문자열).
/// [keepRecurrence]가 false면 단발 이벤트로, true면 원래 반복 규칙을 이어받는
/// 새 계열의 시작 이벤트로 만든다.
EventModel detachedRecurringVoiceEvent(
  EventModel event, {
  required String parentEventId,
  required bool keepRecurrence,
}) {
  return event.copyWith(
    id: '',
    parentEventId: parentEventId,
    clearGroupEventId: true,
    clearRecurrenceRule: !keepRecurrence,
    source: 'manual',
    clearExternalId: true,
    clearExternalCalendarId: true,
    clearExternalEtag: true,
    clearExternalUpdatedAt: true,
    clearLastSyncedAt: true,
    clearCreatedAt: true,
    clearUpdatedAt: true,
  );
}

/// 기존 반복 규칙을 [boundary] 하루 전까지만 유효하도록 자른다.
String? truncateRRuleBefore(String? rule, DateTime boundary) {
  if (rule == null || rule.trim().isEmpty) {
    return null;
  }
  final until = DateTime(boundary.year, boundary.month, boundary.day)
      .subtract(const Duration(days: 1));
  return RecurrenceSelection.fromRRule(rule).copyWith(until: until).toRRule();
}
