import 'dart:async';
import 'package:flutter/material.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_route_recovery.dart';

class ReadOnlyCoordinator implements GuideCoordinator {
  ReadOnlyCoordinator(GuideSnapshot s) : state = ValueNotifier(s);
  @override
  final ValueNotifier<GuideSnapshot> state;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('no guide actions during recovery');
}
GuideSnapshot snapshot(GuideStep step) => GuideSnapshot(
    uid: 'u', version: 'v', revision: 9, serverRevision: 5,
    sessionId: 'session', createdEventId: 'bound', step: step,
    // banned-ok: Fixed event fixture for the guide assertion.
    run: GuideRun.active, savedLocalDate: DateTime(2026, 10, 20),
    // banned-ok: Fixed event fixture for the guide assertion.
    expectedUpdatedStartLocal: DateTime(2026, 10, 20, 16));
const event = EventModel(id: 'bound', userId: 'u', title: 'saved');
void main() {
  testWidgets('cold home offers explicit CTA without navigation or actions', (tester) async {
    final c = ReadOnlyCoordinator(snapshot(GuideStep.changeSpeech));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
      GuidedAnchor(id: 'home.mic', registry: realUiGuideAnchorRegistry,
          child: const Text('home microphone off')),
      RealUiGuideCoachmark(coordinator: c),
    ]))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('안내 계속'), findsOneWidget);
    expect(find.text('home microphone off'), findsOneWidget);
    expect(c.state.value.step, GuideStep.changeSpeech);
    expect(c.state.value.revision, 9);
    await tester.pumpWidget(const SizedBox.shrink());
    c.state.dispose();
  });
  for (final entry in <GuideStep, String>{
    GuideStep.savedDetail: '/calendar?date=2026-10-20',
    GuideStep.queryMic: '/voice', GuideStep.querySpeech: '/voice',
    GuideStep.queryResults: '/voice/conversation',
    GuideStep.changeSpeech: '/voice/conversation',
    GuideStep.editPreview: '/event/edit/bound',
    GuideStep.updatedDetail: '/event/detail/bound',
  }.entries) {
    test('${entry.key.name} read-only route preserves phase', () async {
      final c = ReadOnlyCoordinator(snapshot(entry.key));
      var reads = 0;
      final r = await GuideRouteRecovery.load(coordinator: c,
          currentUid: () => 'u', attachedToRoute: () => true,
          read: (uid, id) async { reads++; expect(uid, 'u'); expect(id, 'bound'); return [event]; });
      expect(r!.location, entry.value);
      expect(reads, 1);
      expect(c.state.value.step, entry.key);
      expect(c.state.value.revision, 9);
      c.state.dispose();
    });
  }
  for (final kind in ['uid', 'session', 'revision', 'id', 'detached', 'coordinator']) {
    test('late read rejects $kind', () async {
      final c = ReadOnlyCoordinator(snapshot(GuideStep.changeSpeech));
      String uid = 'u'; bool attached = true;
      final pending = Completer<List<EventModel>>();
      final result = GuideRouteRecovery.load(coordinator: c,
          currentUid: () => uid, attachedToRoute: () => attached,
          read: (_, __) => pending.future);
      switch (kind) {
        case 'uid': uid = 'other';
        case 'session': c.state.value = c.state.value.copyWith(sessionId: 'other');
        case 'revision': c.state.value = c.state.value.copyWith(revision: 10);
        case 'id': c.state.value = c.state.value.copyWith(createdEventId: 'other');
        case 'detached': attached = false;
        case 'coordinator': attached = false;
      }
      pending.complete([event]);
      expect(await result, isNull);
      c.state.dispose();
    });
  }
  for (final events in <List<EventModel>>[[], [event, event],
    [const EventModel(id: 'bound', userId: 'foreign', title: 'foreign')],
    [const EventModel(id: 'bound', userId: 'u', title: 'linked', externalId: 'x')],
    [const EventModel(id: 'bound', userId: 'u', title: 'group', groupEventId: 'x')],
  ]) {
    test('missing duplicate foreign linked targets fail closed ${events.length} ${events.isEmpty ? '' : events.first.title}', () async {
      final c = ReadOnlyCoordinator(snapshot(GuideStep.savedDetail));
      await expectLater(GuideRouteRecovery.load(coordinator: c,
          currentUid: () => 'u', attachedToRoute: () => true,
          read: (_, __) async => events), throwsStateError);
      c.state.dispose();
    });
  }
  test('missing preview never invents time or regresses phase', () async {
    final c = ReadOnlyCoordinator(snapshot(GuideStep.editPreview)
        .copyWith(clearExpectedUpdatedStartLocal: true));
    await expectLater(GuideRouteRecovery.load(coordinator: c,
        currentUid: () => 'u', attachedToRoute: () => true,
        read: (_, __) async => [event]), throwsStateError);
    expect(c.state.value.step, GuideStep.editPreview);
    expect(c.state.value.expectedUpdatedStartLocal, isNull);
    c.state.dispose();
  });
  test('request rejects replacement coordinator even with identical snapshot', () {
    final c = ReadOnlyCoordinator(snapshot(GuideStep.changeSpeech));
    final replacement = ReadOnlyCoordinator(c.state.value);
    final r = GuideRouteRecovery(c, c.state.value, event);
    expect(r.isCurrent(replacement, 'u'), isFalse);
    expect(r.isCurrent(c, 'u'), isTrue);
    c.state.dispose(); replacement.state.dispose();
  });
  test('sync choice remains owned by existing route gate', () async {
    final c = ReadOnlyCoordinator(snapshot(GuideStep.syncChoice));
    final r = await GuideRouteRecovery.load(coordinator: c,
        currentUid: () => 'u', attachedToRoute: () => true,
        read: (_, __) async => throw StateError('must not read'));
    expect(r, isNull);
    c.state.dispose();
  });
}
