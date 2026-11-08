import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import '../../integration_test/support/real_ui_guide_native_environment.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25);
  GuideSnapshot snap(GuideStep step,
          {String uid = 'qa',
          String? session = 's1',
          int revision = 7,
          GuideRun run = GuideRun.active,
          String? error,
          String? event = 'event-1'}) =>
      GuideSnapshot(
          uid: uid,
          version: 'v1',
          revision: revision,
          serverRevision: revision,
          step: step,
          run: run,
          sessionId: session,
          errorCode: error,
          createdEventId: event);
  String? check(GuideSnapshot? s,
          {String uid = 'qa',
          String? session = 's1',
          int? revision = 7,
          DateTime? expiry}) =>
      NativeGuideManualPhaseGate.denial(
          snapshot: s,
          expectedUid: uid,
          sessionId: session,
          serverRevision: revision,
          expiresAt: expiry ?? now.add(const Duration(minutes: 1)),
          createdId: 'event-1',
          now: now);

  test('bootstrap has no authorization; observed createSpeech enables create',
      () {
    expect(NativeGuideManualPhaseGate.phaseFor(GuideStep.intro), isNull);
    expect(check(snap(GuideStep.createSpeech)), isNull);
    expect(
        NativeGuideManualPhaseGate.phaseFor(GuideStep.createSpeech), 'create');
  });
  test('only narrow observed steps map to phases', () {
    expect(
        NativeGuideManualPhaseGate.phaseFor(GuideStep.correctAndSave), 'save');
    expect(NativeGuideManualPhaseGate.phaseFor(GuideStep.querySpeech), 'query');
    expect(
        NativeGuideManualPhaseGate.phaseFor(GuideStep.changeSpeech), 'change');
    expect(
        NativeGuideManualPhaseGate.phaseFor(GuideStep.editPreview), 'editSave');
    expect(NativeGuideManualPhaseGate.phaseFor(GuideStep.homeMic), isNull);
  });
  test('missing, stale, wrong uid/session/revision/run and expired states deny',
      () {
    expect(check(null), contains('missing'));
    expect(check(snap(GuideStep.createSpeech, uid: 'other')), contains('uid'));
    expect(check(snap(GuideStep.createSpeech, session: null)),
        contains('session'));
    expect(
        check(snap(GuideStep.createSpeech, revision: 6)), contains('revision'));
    expect(check(snap(GuideStep.createSpeech, run: GuideRun.paused)),
        contains('active'));
    expect(
        check(snap(GuideStep.createSpeech), expiry: now), contains('expired'));
  });
  test('operator phase changes remain allowed only when manual binding is off',
      () {
    expect(
        NativeGuideManualPhaseGate.operatorPhaseAllowed(
            manualBindingEnabled: false),
        isTrue);
    expect(
        NativeGuideManualPhaseGate.operatorPhaseAllowed(
            manualBindingEnabled: true),
        isFalse);
  });
  test('fence stage comes from the request, not the on-screen guide step', () {
    expect(
        NativeGuideManualPhaseGate.fenceStageForRequest(
            {'p_kind': 'scheduleParse', 'p_operation': 'createParse'}),
        'create');
    expect(
        NativeGuideManualPhaseGate.fenceStageForRequest(
            {'p_kind': 'voiceConversation', 'p_operation': 'query'}),
        'query');
    expect(
        NativeGuideManualPhaseGate.fenceStageForRequest(
            {'p_kind': 'voiceConversation', 'p_operation': 'changeTime'}),
        'change');
    expect(
        NativeGuideManualPhaseGate.fenceStageForRequest(
            {'p_kind': 'scheduleParse', 'p_operation': 'deleteEvent'}),
        isNull);
    expect(NativeGuideManualPhaseGate.fenceStageForRequest(const {}), isNull);
  });
  test('wire phase maps to the fence stage the server authorizes', () {
    expect(
        NativeGuideManualPhaseGate.fenceStageForWirePhase('create'), 'create');
    expect(NativeGuideManualPhaseGate.fenceStageForWirePhase('query'), 'query');
    expect(NativeGuideManualPhaseGate.fenceStageForWirePhase('edit'), 'change');
    expect(
        NativeGuideManualPhaseGate.fenceStageForWirePhase('preview'), 'change');
    expect(NativeGuideManualPhaseGate.fenceStageForWirePhase('saved'), isNull);
    expect(NativeGuideManualPhaseGate.fenceStageForWirePhase(null), isNull);
  });
  test('the guide may sit one step ahead of the authorized stage', () {
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('create', 'save'), isTrue);
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('create', 'create'), isTrue);
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('create', 'query'), isFalse);
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('query', 'query'), isTrue);
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('query', 'save'), isFalse);
    expect(NativeGuideManualPhaseGate.tourStageAllows('change', 'editSave'),
        isTrue);
    expect(
        NativeGuideManualPhaseGate.tourStageAllows('change', 'change'), isTrue);
    expect(NativeGuideManualPhaseGate.tourStageAllows('save', 'save'), isFalse);
  });
  test('manual create tags a copy without changing editor/parser payload', () {
    final original = <String, dynamic>{'user_id': 'qa', 'title': '일정'};
    final marked = NativeGuideManualPhaseGate.markedCreatePayload(original,
        expectedUid: 'qa', marker: '[QA:guide123]');
    expect(marked?['title'], '일정 [QA:guide123]');
    expect(original['title'], '일정');
    expect(identical(original, marked), isFalse);
  });
  test('manual create tagging is idempotent', () {
    final marked = NativeGuideManualPhaseGate.markedCreatePayload(
        {'user_id': 'qa', 'title': '일정 [QA:guide123]'},
        expectedUid: 'qa', marker: '[QA:guide123]');
    expect(marked?['title'], '일정 [QA:guide123]');
  });
  test('manual create rejects other owner and invalid title or marker', () {
    for (final payload in <Map<String, dynamic>?>[
      null,
      {'user_id': 'other', 'title': '일정'},
      {'user_id': 'qa', 'title': '  '},
      {'user_id': 'qa', 'title': 123},
    ]) {
      expect(
          NativeGuideManualPhaseGate.markedCreatePayload(payload,
              expectedUid: 'qa', marker: '[QA:guide123]'),
          isNull);
    }
    expect(
        NativeGuideManualPhaseGate.markedCreatePayload(
            {'user_id': 'qa', 'title': '일정'},
            expectedUid: 'qa', marker: 'unscoped'),
        isNull);
  });
  test('query/change require the created identity', () {
    expect(
        check(snap(GuideStep.querySpeech, event: null)), contains('identity'));
    expect(check(snap(GuideStep.changeSpeech, event: 'other')),
        contains('identity'));
    expect(check(snap(GuideStep.querySpeech)), isNull);
  });
}
