import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/services/voice_conversation_controller.dart';

// Synthetic local parser/order tests only. No engine or cloud proof.
void main() {
  const guide = GuideSnapshot(
      uid: 'u',
      version: 'v',
      sessionId: 's',
      revision: 4,
      serverRevision: 2,
      step: GuideStep.changeSpeech,
      run: GuideRun.active,
      createdEventId: 'owned');
  EventModel event(String id, String uid) => EventModel(
      id: id,
      userId: uid,
      title: id,
      // banned-ok: Fixed event fixture for the guide assertion.
      startAt: DateTime(2030, 1, 2, 10),
      // banned-ok: Fixed event fixture for the guide assertion.
      endAt: DateTime(2030, 1, 2, 11));
  test('pinned order feeds cards and ordinal parser', () {
    final controller = VoiceConversationController(
        // banned-ok: Supplies the fixed clock for the event-order fixture.
        now: () => DateTime(2030, 1, 1),
        guideSnapshot: () => guide,
        events: [event('foreign', 'other'), event('owned', 'u')]);
    final result = controller.handle('내일 일정 보여줘');
    expect(result.visibleEvents.first.id, 'owned');
    expect(controller.visibleEvents.map((e) => e.id),
        result.visibleEvents.map((e) => e.id));
    final binding = controller.bindGuideResults(guide, result.visibleEvents);
    expect(
        GuideResultOrder.validForOrdinalEdit(
            guide: guide, binding: binding, expectedRevision: 4),
        isTrue);
    expect(controller.handle('첫 번째 일정 오후 3시로 바꿔줘').targetEvent?.id, 'owned');
  });
  test('revision increment requires rebind', () {
    final controller = VoiceConversationController();
    final old = controller.bindGuideResults(guide, [event('owned', 'u')]);
    final current = guide.copyWith(revision: 5);
    expect(
        GuideResultOrder.validForOrdinalEdit(
            guide: current, binding: old, expectedRevision: 5),
        isFalse);
    final rebound = controller.bindGuideResults(current, old.ordered);
    expect(
        GuideResultOrder.validForOrdinalEdit(
            guide: current, binding: rebound, expectedRevision: 5),
        isTrue);
  });
  test('foreign identity missing duplicate block', () {
    for (final results in <List<EventModel>>[
      [event('owned', 'foreign')],
      [event('foreign', 'u')],
      [event('owned', 'u'), event('owned', 'u')]
    ]) {
      final binding = GuideResultOrder.bind(guide: guide, results: results);
      expect(
          GuideResultOrder.validForOrdinalEdit(
              guide: guide, binding: binding, expectedRevision: 4),
          isFalse);
    }
  });
  test('outside guide chronological first unchanged', () {
    final controller =
        // banned-ok: Supplies the fixed clock for the event-order fixture.
        VoiceConversationController(now: () => DateTime(2030, 1, 1), events: [
      event('first', 'u'),
      // banned-ok: Fixed event fixture for the guide assertion.
      event('owned', 'u').copyWith(startAt: DateTime(2030, 1, 2, 12))
    ]);
    expect(controller.handle('내일 일정 보여줘').visibleEvents.first.id, 'first');
  });
}
