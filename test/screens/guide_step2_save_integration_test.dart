import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_bubble_visibility.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart'
    show realUiGuideVersion;
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_local_backend.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'guide-step2-user';
const _guideQa = bool.fromEnvironment('PLANFLOW_GUIDE_QA');
const _isolatedQa = bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA');
const _bothDefines = _guideQa && _isolatedQa;
const _surface = Size(412, 915);

void main() {
  testWidgets(
      'real Step 2 save with guideQa=$_guideQa and isolatedQa=$_isolatedQa',
      (tester) async {
    await tester.binding.setSurfaceSize(_surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => authProvider.setUser(null));
    addTearDown(GuideQuotaRuntime.reset);
    addTearDown(SupabaseClientAccess.clearOverride);

    // LocalGuideBackend serializes operations across instances. Keep all
    // mounts in one widget clock, each with fresh persisted progress.
    final unresolved = await _SaveFixture.mount(tester, hasCoordinates: false);
    if (_bothDefines) {
      await _verifyQaSave(tester, unresolved);
    } else {
      await tester.tap(unresolved.saveButton);
      await tester.pump();
      _expectVisibleNotice(tester, '장소와 좌표가 필요해요', coachmark: true);
      await unresolved.expectNoWrite();
    }
    await unresolved.unmount(tester);

    for (final changeOwner in [true, false]) {
      final fixture = await _SaveFixture.mount(tester);
      await _verifyChangedSaveContext(tester, fixture,
          changeOwner: changeOwner);
      await fixture.unmount(tester);
    }

    final recurring = await _SaveFixture.mount(tester, recurring: true);
    await tester.tap(recurring.saveButton);
    await _pumpUntil(tester, () => _notice.evaluate().isNotEmpty,
        'The repeating-event guard should explain why save was blocked');
    _expectVisibleNotice(tester, '반복하지 않는 개인 일정만', coachmark: true);
    await recurring.expectNoWrite();
    await recurring.unmount(tester);
  });
}

Future<void> _verifyQaSave(WidgetTester tester, _SaveFixture fixture) async {
  final before = fixture.guide.state.value;
  final createReply = fixture.repository.createReply = Completer<void>();
  final buttonCenter = tester.getCenter(fixture.saveButton);
  await tester.tapAt(buttonCenter);
  await tester.tapAt(buttonCenter);
  await _pumpUntil(tester, () => fixture.repository.createCalls > 0,
      'The actual save tap should reach the repository');
  expect(fixture.repository.createCalls, 1);
  expect(fixture.repository.savedEvents, hasLength(1));
  expect(fixture.guide.state.value.step, GuideStep.correctAndSave);

  // The write has happened, but the repository has not returned its ID yet.
  await tester.tapAt(buttonCenter);
  await tester.pump();
  expect(fixture.repository.createCalls, 1);
  expect(fixture.repository.savedEvents, hasLength(1));
  createReply.complete();
  await _pumpUntil(
      tester,
      () => fixture.guide.state.value.step == GuideStep.savedDetail,
      'The real local backend should accept the saved event');
  await _pumpUntil(tester, () => find.text('테스트 일정 목록').evaluate().isNotEmpty,
      'ConfirmScreen should leave the create form after accepting the save');

  final event = fixture.repository.savedEvents.single;
  final checkpoint = await fixture.readProgress();
  expect(event.location, '강남역');
  expect(event.locationLat, isNull);
  expect(event.locationLng, isNull);
  expect(checkpoint.step, GuideStep.savedDetail);
  expect(checkpoint.run, GuideRun.active);
  expect(checkpoint.createdEventId, event.id);
  expect(checkpoint.savedCreateOperationId, isNotEmpty);
  expect(checkpoint.serverRevision, before.serverRevision + 1,
      reason: 'the local backend accepted the checkpoint');
  expect(fixture.guide.state.value.createdEventId, event.id);
  expect(fixture.repository.createCalls, 1);
}

Future<void> _verifyChangedSaveContext(
    WidgetTester tester, _SaveFixture fixture,
    {required bool changeOwner}) async {
  final overlapReply = fixture.repository.overlapReply = Completer<void>();
  final before = fixture.guide.state.value;
  await tester.tap(fixture.saveButton);
  await _pumpUntil(tester, () => fixture.repository.overlapCalls == 1,
      'Save should reach the overlap lookup before the second write guard');
  if (changeOwner) {
    authProvider.setUser('different-user');
  } else {
    fixture.guide.suspend(GuidePauseReason.background);
    expect(fixture.guide.state.value.revision, greaterThan(before.revision));
  }
  overlapReply.complete();
  await _pumpUntil(tester, () => _notice.evaluate().isNotEmpty,
      'The final write guard should explain why save was blocked');
  _expectVisibleNotice(
    tester,
    changeOwner ? '로그인 또는 안내 세션이 바뀌어' : '안내 상태가 바뀌어',
    coachmark: changeOwner,
  );
  await fixture.expectNoWrite();
}

final _notice = find.byKey(const ValueKey('guide-step2-save-feedback'));

void _expectVisibleNotice(WidgetTester tester, String message,
    {required bool coachmark}) {
  expect(_notice, findsOneWidget);
  expect(
    find.descendant(of: _notice, matching: find.textContaining(message)),
    findsOneWidget,
  );
  expect(tester.widget<Semantics>(_notice).properties.liveRegion, isTrue);
  final rect = tester.getRect(_notice);
  expect(rect.isEmpty, isFalse);
  expect(rect.intersect(Offset.zero & _surface), rect);

  // A semantics node can exist in the Navigator even while the root guide
  // paints over it. Check the actual paint order of the common parent stack.
  Stack? topStack;
  tester.element(_notice).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is! Stack) return true;
    topStack = widget;
    return false;
  });
  final layers = topStack!.children;
  expect(layers, hasLength(2));
  expect(find.descendant(of: find.byWidget(layers.last), matching: _notice),
      findsOneWidget);
  if (coachmark) {
    expect(
      find.descendant(
        of: find.byWidget(layers.first),
        matching: find.byType(GuidedCoachmarkOverlay),
      ),
      findsOneWidget,
    );
  }
  expect(tester.takeException(), isNull);
}

Future<void> _pumpUntil(
    WidgetTester tester, bool Function() ready, String reason) async {
  for (var frame = 0; frame < 30 && !ready(); frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: reason);
}

class _SaveFixture {
  _SaveFixture(this.container, this.router, this.repository);

  final ProviderContainer container;
  final GoRouter router;
  final _EventStore repository;

  GuideCoordinator get guide => container.read(realUiGuideCoordinatorProvider);

  Finder get saveButton => find.descendant(
        of: find.byWidgetPredicate(
            (widget) => widget is GuidedAnchor && widget.id == 'confirm.save'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );

  static Future<_SaveFixture> mount(WidgetTester tester,
      {bool hasCoordinates = true, bool recurring = false}) async {
    SharedPreferences.setMockInitialValues({});
    authProvider.setUser(_uid);
    SupabaseClientAccess.overrideForRun(() => authProvider.userId);
    final repository = _EventStore();
    final container = ProviderContainer(overrides: [
      realUiGuideBackendProvider.overrideWith((ref) => LocalGuideBackend(
            progress: ref.watch(realUiGuideProgressStoreProvider),
            fetchBoundEvent: (uid, id) =>
                repository.fetchEvent(id, userId: uid),
          )),
    ]);
    final now = DateTime.now();
    final startAt = DateTime(now.year, now.month, now.day + 1, 14);
    final router = GoRouter(
      initialLocation: AppRoutes.home,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('테스트 홈')),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (_, __) => ConfirmScreen(
            userId: _uid,
            parsedSchedule: {
              'title': '강남역 일정',
              'start_at': startAt.toIso8601String(),
              'end_at': startAt.add(const Duration(hours: 1)).toIso8601String(),
              'location': '강남역',
              'location_lat': hasCoordinates ? 37.4979 : null,
              'location_lng': hasCoordinates ? 127.0276 : null,
              'is_critical': true,
              'use_strong_alarm': true,
              if (recurring)
                'recurrence_rule': 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO',
            },
            backend: const _ConfirmBackend(),
            eventRepository: repository,
            permissionService: _ReadyPermissions(),
            locationLookupService: _EmptyLocationLookup(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) => const Scaffold(body: Text('테스트 일정 목록')),
        ),
      ],
    );
    final fixture = _SaveFixture(container, router, repository);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => RootGuideScope(
          uid: _uid,
          isGuideQa: _isolatedQa,
          bindRuntime: (guide) => GuideQuotaRuntime.bind(guide, uid: _uid),
          unbindRuntime: GuideQuotaRuntime.unbind,
          child: child!,
        ),
      ),
    ));
    await _pumpUntil(tester, () => fixture.guide.state.value.sessionId != null,
        'Guide start');
    final guide = fixture.guide;
    expect(
        container.read(realUiGuideBackendProvider), isA<LocalGuideBackend>());
    final home = await guide.dispatch(
        IntroFinished(uid: _uid, expectedRevision: guide.state.value.revision));
    final speech = await guide.dispatch(HomeMicTapped(
        uid: _uid, sessionId: home.sessionId, expectedRevision: home.revision));
    await guide.dispatch(ParseConfirmed(
      uid: _uid,
      sessionId: speech.sessionId,
      expectedRevision: speech.revision,
      operationId: 'step2-input',
    ));
    expect(guide.state.value.step, GuideStep.correctAndSave);
    expect(guide.state.value.run, GuideRun.active);

    router.go(AppRoutes.confirm);
    await _pumpUntil(tester, () => guideConfirmReady.value,
        'The ready ConfirmScreen should mount');
    final overlay = find.byType(GuidedCoachmarkOverlay);
    bool saveSpotlightVisible() =>
        overlay.evaluate().isNotEmpty &&
        tester.widget<GuidedCoachmarkOverlay>(overlay).targetId ==
            'confirm.save' &&
        fixture.saveButton.hitTestable().evaluate().isNotEmpty;
    // Drag inside the form and outside the instruction bubble's side margin.
    for (var attempt = 0; attempt < 12 && !saveSpotlightVisible(); attempt++) {
      await tester.dragFrom(const Offset(6, 760), const Offset(0, -220));
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(guideConfirmUserScrolled.value, isTrue);
    expect(saveSpotlightVisible(), isTrue,
        reason: 'real save spotlight and tap');
    expect(
        tester.widget<FilledButton>(fixture.saveButton).onPressed, isNotNull);
    return fixture;
  }

  Future<GuideSnapshot> readProgress() async => (await container
      .read(realUiGuideProgressStoreProvider)
      .load(uid: _uid, version: realUiGuideVersion))!;

  Future<void> expectNoWrite() async {
    expect(repository.createCalls, 0);
    expect(repository.savedEvents, isEmpty);
    final checkpoint = await readProgress();
    expect(checkpoint.createdEventId, isNull);
    expect(checkpoint.step, GuideStep.correctAndSave);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    router.dispose();
    container.dispose();
    guideSaveStageActive.value = false;
    guideSaveStage.value = GuideSaveStage.important;
    guideConfirmReady.value = false;
    guideConfirmUserScrolled.value = false;
  }
}

class _EventStore extends EventRepository {
  final savedEvents = <EventModel>[];
  int overlapCalls = 0;
  int createCalls = 0;
  Completer<void>? overlapReply;
  Completer<void>? createReply;

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    overlapCalls++;
    await overlapReply?.future;
    return const [];
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    createCalls++;
    final saved = event.copyWith(id: 'step2-event-$createCalls');
    savedEvents.add(saved);
    await createReply?.future;
    return saved;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => savedEvents
      .where((event) => userId == null || event.userId == userId)
      .toList();

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      (await listEvents(userId: userId))
          .where((event) => event.id == eventId)
          .firstOrNull;

  @override
  Future<EventModel> updateEvent(EventModel event) =>
      throw UnsupportedError('Unexpected event update');

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) =>
      throw UnsupportedError('Unexpected event deletion');
}

class _ConfirmBackend extends ConfirmScreenBackend {
  const _ConfirmBackend();

  @override
  Future<List<String>> fetchPastSupplies(
          {required String userId, required String location}) async =>
      const [];

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _ReadyPermissions extends AppPermissionService {
  @override
  Future<AppPermissionSnapshot> checkAll() async => const AppPermissionSnapshot(
        microphoneGranted: true,
        locationGranted: true,
        calendarGranted: true,
        notificationStatus: NotificationPermissionStatus(
          notificationsEnabled: true,
          exactAlarmsEnabled: true,
          fullScreenIntentStatus: PermissionCheckState.granted,
        ),
        batteryOptimizationIgnored: true,
      );

  @override
  Future<bool> checkLocationPermission() async => true;

  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async =>
      null;
}

class _EmptyLocationLookup extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async =>
      const [];
}
