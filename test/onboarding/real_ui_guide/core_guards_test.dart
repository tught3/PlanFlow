import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';

EventModel event(String id,
        {String user = 'u', String? group, String? recurrence}) =>
    EventModel(
        id: id,
        userId: user,
        title: id,
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13),
        location: 'Station',
        recurrenceRule: recurrence,
        groupEventId: group);
GuideSnapshot snapshot(
        {GuideStep step = GuideStep.querySpeech,
        String? id = 'new',
        int rev = 4}) =>
    GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        sessionId: 's',
        createdEventId: id,
        revision: rev,
        serverRevision: 2,
        step: step,
        run: GuideRun.active,
        // banned-ok: Fixed event fixture for the guide assertion.
        originalStartLocal: DateTime(2026, 10, 20, 13),
        // banned-ok: Fixed event fixture for the guide assertion.
        expectedUpdatedStartLocal: DateTime(2026, 10, 20, 15));
void main() {
  test('result order pins only owned created ID and preserves remaining order',
      () {
    final g = snapshot();
    final bound = GuideResultOrder.bind(
        guide: g, results: [event('x'), event('new'), event('y')]);
    expect(bound.ordered.map((e) => e.id), ['new', 'x', 'y']);
    expect(
        GuideResultOrder.validForOrdinalEdit(
            guide: g, binding: bound, expectedRevision: 4),
        isTrue);
  });
  test('result binding reports missing, duplicate, and foreign identities', () {
    final g = snapshot();
    expect(GuideResultOrder.bind(guide: g, results: [event('x')]).missingTarget,
        isTrue);
    expect(
        GuideResultOrder.bind(guide: g, results: [event('new'), event('new')])
            .duplicateTarget,
        isTrue);
    expect(
        GuideResultOrder.bind(guide: g, results: [event('new', user: 'other')])
            .identityIssue,
        isTrue);
    expect(
        GuideResultOrder.bind(guide: g, results: [event('new', group: 'g')])
            .identityIssue,
        isTrue);
  });
  test(
      'mutation policy requires confirmation and only allows same target/time fields',
      () {
    final g = snapshot(step: GuideStep.editPreview);
    GuideMutationIntent i(
            {bool confirmed = true,
            String id = 'new',
            Set<String> fields = const {'startAt'},
            DateTime? time}) =>
        GuideMutationIntent(
            kind: GuideWriteKind.changeTime,
            operationId: 'op',
            eventId: id,
            isPersonal: true,
            isRecurrence: false,
            changedFields: fields,
            requestedStartLocal: time ?? g.expectedUpdatedStartLocal,
            userConfirmed: confirmed);
    expect(GuideMutationPolicy.check(guide: g, intent: i()).allowed, isTrue);
    expect(
        GuideMutationPolicy.check(guide: g, intent: i(confirmed: false))
            .allowed,
        isFalse);
    expect(
        GuideMutationPolicy.check(guide: g, intent: i(id: 'foreign')).allowed,
        isFalse);
    expect(
        GuideMutationPolicy.check(guide: g, intent: i(fields: const {'title'}))
            .allowed,
        isFalse);
    final createGuide = snapshot(step: GuideStep.correctAndSave, id: null);
    final create = GuideMutationIntent(
        kind: GuideWriteKind.createPersonal,
        operationId: 'new-create',
        isPersonal: true,
        isRecurrence: false,
        changedFields: const {'title', 'startAt'},
        userConfirmed: true);
    expect(
        GuideMutationPolicy.check(guide: createGuide, intent: create).allowed,
        isTrue);
  });
}
