import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'package:planflow/widgets/schedule_progress_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'guide-step2-user';
const _guideQa = bool.fromEnvironment('PLANFLOW_GUIDE_QA');
const _isolatedQa = bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA');
const _skipMap = _guideQa &&
    _isolatedQa &&
    bool.fromEnvironment('PLANFLOW_GUIDE_QA_SKIP_MAP');
const _surface = Size(412, 915);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ownership = MethodChannel('planflow/critical_alarm_ownership');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(ownership, (call) async {
      if (call.method == 'invalidateOwner' || call.method == 'readOwner') {
        return null;
      }
      throw MissingPluginException(call.method);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(ownership, null));

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
    await _verifySave(tester, unresolved);
    await unresolved.unmount(tester);

    final blank = await _SaveFixture.mount(
      tester,
      hasCoordinates: false,
      location: ' ',
    );
    await tester.tap(blank.saveButton);
    await tester.pump();
    _expectVisibleNotice(tester, '일정 장소를 입력해 주세요.', coachmark: true);
    await blank.expectNoWrite();
    await blank.unmount(tester);

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

    final ordinary = await _SaveFixture.mount(tester, guided: false);
    await tester.ensureVisible(ordinary.saveButton);
    await tester.pump();
    await tester.tap(ordinary.saveButton);
    await _pumpUntil(tester, () => find.text('테스트 일정 목록').evaluate().isNotEmpty,
        'Ordinary saves still navigate to the calendar');
    expect(ordinary.calendarBuilds, greaterThan(0));
    expect(ordinary.repository.savedEvents, hasLength(1));
    await ordinary.unmount(tester);

    final ended = _EndedSaveGuide();
    addTearDown(ended.dispose);
    for (final coordinator in <GuideCoordinator?>[null, ended]) {
      final pending = await _SaveFixture.mount(
        tester,
        guided: false,
        pending: true,
        pendingCoordinator: coordinator,
      );
      await tester.ensureVisible(pending.saveButton);
      await tester.pump();
      await tester.tap(pending.saveButton);
      await _pumpUntil(tester, () => _notice.evaluate().isNotEmpty,
          'A lost guide must display the save recovery message');
      _expectVisibleNotice(tester, '로그인 또는 안내 세션이 바뀌어 저장하지 않았어요.',
          coachmark: false);
      expect(pending.repository.createCalls, 0);
      expect(pending.repository.savedEvents, isEmpty);
      expect(pending.calendarBuilds, 0);
      await pending.unmount(tester);
    }

    final interrupted = await _SaveFixture.mount(tester, pending: true);
    await _verifyPendingRetryAfterTermination(tester, interrupted);
    await interrupted.unmount(tester);
  });
}

Future<void> _verifySave(WidgetTester tester, _SaveFixture fixture) async {
  final before = fixture.guide.state.value;
  expect(GuideQuotaRuntime.blocksOrdinaryUse(uid: _uid), isTrue);
  expect(GuideQuotaRuntime.blocksAdDisplay(uid: _uid), isTrue);
  final createReply = fixture.repository.createReply = Completer<void>();
  final buttonCenter = tester.getCenter(fixture.saveButton);
  await tester.tapAt(buttonCenter);
  await tester.tapAt(buttonCenter);
  await _pumpUntil(tester, () => fixture.repository.createCalls > 0,
      'The actual save tap should reach the repository');
  await tester.pump();
  expect(fixture.repository.createCalls, 1);
  expect(fixture.repository.savedEvents, hasLength(1));
  expect(fixture.guide.state.value.step, GuideStep.correctAndSave);
  expect(
      tester
          .widget<ScheduleProgressOverlay>(find.byType(ScheduleProgressOverlay))
          .dark,
      isTrue);
  expect(fixture.calendarBuilds, 0);

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
  await _pumpUntil(tester, () => find.text('테스트 홈').evaluate().isNotEmpty,
      'ConfirmScreen should go directly Home after accepting the guide save');
  expect(fixture.calendarBuilds, 0,
      reason: 'The calendar must not build even during the transition');
  expect(find.byType(ScheduleProgressOverlay), findsNothing);

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
  expect(fixture.notifications.criticalAlarms,
      [event.startAt!.subtract(const Duration(hours: 1))]);
  expect(GuideQuotaRuntime.blocksOrdinaryUse(uid: _uid), isTrue);
  expect(GuideQuotaRuntime.blocksAdDisplay(uid: _uid), isTrue);

  final changedStart = event.startAt!.add(const Duration(hours: 3));
  final changedEnd = event.endAt!.add(const Duration(hours: 3));
  final createReminderAt = event.startAt!.subtract(const Duration(hours: 1));
  final changedReminderAt = changedStart.subtract(const Duration(hours: 1));
  // The editor commits the two time columns before queuing its alarm work.
  fixture.repository.savedEvents[0] =
      event.copyWith(startAt: changedStart, endAt: changedEnd);
  final editStarted = Completer<void>();
  final finishEditEffects = Completer<void>();
  DateTime? reminderSeenAtEdit;
  unawaited(GuideEventSaveFollowUps.enqueue(event, () async {
    final stored = fixture.backend.reminderBatches.single.single['notify_at'];
    reminderSeenAtEdit = DateTime.parse(stored as String);
    editStarted.complete();
    await finishEditEffects.future;
    final current = fixture.repository.savedEvents.single;
    fixture.notifications.criticalAlarms.clear();
    await fixture.notifications.scheduleCriticalAlarmWithResult(
      id: 1,
      title: current.title,
      notifyAt: current.startAt!.subtract(const Duration(hours: 1)),
    );
    fixture.backend.reminderBatches.single.single['notify_at'] =
        changedReminderAt.toIso8601String();
  }));
  // The editor may attach a second listener after its save for cold resumes.
  GuideEventSaveFollowUps.deferCalendarSync(
    state: fixture.guide.state,
    event: event,
    repository: fixture.repository,
    stillOwnsEvent: () => true,
    export: (latest) async => fixture.calendarExports.add(latest),
  );
  expect(fixture.calendarExports, isEmpty);

  if (!_skipMap) {
    expect(fixture.locationLookup.savedEventLookups, ['강남역']);
    expect(fixture.repository.updateCalls, 0);
    expect(fixture.backend.reminderBatches, isEmpty,
        reason: 'The queued edit cannot outrun the guide create effects');
    expect(editStarted.isCompleted, isFalse);
    fixture.locationLookup.reply.complete(const [
      LocationLookupResult(
        name: '강남역 2호선',
        address: '',
        latitude: 37.4979,
        longitude: 127.0276,
      ),
    ]);
    await _pumpUntil(tester, () => fixture.repository.updateCalls == 1,
        'Coordinate resolution should update the saved event');
    final resolved = fixture.repository.savedEvents.single;
    expect(resolved.id, event.id);
    expect(resolved.location, '강남역');
    expect(resolved.locationLat, 37.4979);
    expect(resolved.locationLng, 127.0276);
  }
  await _pumpUntil(tester, () => fixture.departureAlarms.attempts.isNotEmpty,
      'The create reminder should be stored before preparation finishes');
  expect(editStarted.isCompleted, isFalse);
  expect(fixture.departureAlarms.attempts.single.startAt, event.startAt);
  fixture.departureAlarms.finishCreatePreparation.complete();
  await _pumpUntil(tester, () => editStarted.isCompleted,
      'Edit rescheduling should wait for all create side effects');
  expect(reminderSeenAtEdit!.isAtSameMomentAs(createReminderAt), isTrue);
  expect(fixture.calendarExports, isEmpty);
  expect(fixture.repository.savedEvents.single.externalId, isNull);
  expect(fixture.repository.savedEvents.single.startAt, changedStart);
  expect(fixture.repository.savedEvents.single.endAt, changedEnd);

  await fixture.guide.terminate(GuideExit.completed);
  await tester.pump();
  expect(fixture.calendarExports, isEmpty,
      reason: 'Terminal export must wait for the edit reminder and alarm');
  finishEditEffects.complete();
  await _pumpUntil(tester, () => fixture.calendarExports.isNotEmpty,
      'Guide termination should export the latest bound event');
  await tester.pump();
  expect(fixture.calendarExports.single.startAt, changedStart);
  expect(fixture.calendarExports.single.endAt, changedEnd);
  expect(fixture.notifications.criticalAlarms, [changedReminderAt]);
  expect(fixture.backend.reminderBatches.single.single['notify_at'],
      changedReminderAt.toIso8601String());
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

Future<void> _verifyPendingRetryAfterTermination(
    WidgetTester tester, _SaveFixture fixture) async {
  final createReply = fixture.repository.createReply = Completer<void>();
  await tester.tap(fixture.saveButton);
  await _pumpUntil(tester, () => fixture.repository.createCalls == 1,
      'The repository writes before it returns the event ID');
  expect(fixture.repository.savedEvents, hasLength(1));

  await fixture.guide.terminate(GuideExit.skip);
  expect(fixture.guide.state.value.run, GuideRun.terminal);
  createReply.complete();
  await _pumpUntil(tester, () => _notice.evaluate().isNotEmpty,
      'Ending the guide while saving leaves the result uncertain');
  await tester.pump(const Duration(seconds: 6));
  expect(_notice, findsNothing);

  expect(fixture.saveButton.hitTestable(), findsOneWidget);
  await tester.tap(fixture.saveButton);
  await _pumpUntil(tester, () => _notice.evaluate().isNotEmpty,
      'A retry must warn that the first write may have succeeded');
  _expectVisibleNotice(tester, '일정이 이미 저장됐을 수 있어요.', coachmark: false);
  expect(fixture.repository.createCalls, 1);
  expect(fixture.repository.savedEvents, hasLength(1));
  expect(fixture.calendarBuilds, 0);
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
  _SaveFixture(
    this.container,
    this.router,
    this.repository,
    this.locationLookup,
    this.notifications,
    this.backend,
    this.calendarExports,
    this.departureAlarms,
  );

  final ProviderContainer container;
  final GoRouter router;
  final _EventStore repository;
  final _DeferredLocationLookup locationLookup;
  final _RecordingNotifications notifications;
  final _ConfirmBackend backend;
  final List<EventModel> calendarExports;
  final _DeferredDepartureAlarms departureAlarms;
  int calendarBuilds = 0;

  GuideCoordinator get guide => container.read(realUiGuideCoordinatorProvider);

  Finder get saveButton => find.descendant(
        of: find.byWidgetPredicate(
            (widget) => widget is GuidedAnchor && widget.id == 'confirm.save'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );

  static Future<_SaveFixture> mount(
    WidgetTester tester, {
    bool guided = true,
    bool hasCoordinates = true,
    bool recurring = false,
    bool pending = false,
    GuideCoordinator? pendingCoordinator,
    String location = '강남역',
  }) async {
    SharedPreferences.setMockInitialValues({});
    authProvider.setUser(_uid);
    SupabaseClientAccess.overrideForRun(() => authProvider.userId);
    final repository = _EventStore();
    final locationLookup = _DeferredLocationLookup(repository);
    final notifications = _RecordingNotifications();
    final backend = _ConfirmBackend();
    final departureAlarms = _DeferredDepartureAlarms();
    final calendarExports = <EventModel>[];
    final container = ProviderContainer(overrides: [
      realUiGuideBackendProvider.overrideWith((ref) => LocalGuideBackend(
            progress: ref.watch(realUiGuideProgressStoreProvider),
            fetchBoundEvent: (uid, id) =>
                repository.fetchEvent(id, userId: uid),
          )),
    ]);
    final now = DateTime.now();
    final startAt = DateTime(now.year, now.month, now.day + 1, 14);
    late final _SaveFixture fixture;
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
            pendingGuideConfirm: pending
                ? PendingGuideConfirm(
                    parsedSchedule: const {},
                    authorize: (isCurrent, beginTransition) async =>
                        isCurrent() && beginTransition(),
                  )
                : null,
            parsedSchedule: {
              'title': '강남역 일정',
              'start_at': startAt.toIso8601String(),
              'end_at': startAt.add(const Duration(hours: 1)).toIso8601String(),
              'location': location,
              'location_lat': hasCoordinates ? 37.4979 : null,
              'location_lng': hasCoordinates ? 127.0276 : null,
              'is_critical': true,
              'use_strong_alarm': true,
              if (recurring)
                'recurrence_rule': 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO',
            },
            backend: backend,
            eventRepository: repository,
            permissionService: _ReadyPermissions(),
            locationLookupService: locationLookup,
            notificationService: notifications,
            departureAlarmService: departureAlarms,
            homeWidgetService: _RecordingHomeWidget(),
            exportCalendarAfterSave: (event) async {
              calendarExports.add(event);
            },
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) {
            fixture.calendarBuilds++;
            return const Scaffold(body: Text('테스트 일정 목록'));
          },
        ),
      ],
    );
    fixture = _SaveFixture(container, router, repository, locationLookup,
        notifications, backend, calendarExports, departureAlarms);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => guided
            ? RootGuideScope(
                uid: _uid,
                isGuideQa: _isolatedQa,
                bindRuntime: (guide) =>
                    GuideQuotaRuntime.bind(guide, uid: _uid),
                unbindRuntime: GuideQuotaRuntime.unbind,
                child: child!,
              )
            : GuideSaveFeedbackHost(
                child: pendingCoordinator == null
                    ? child!
                    : GuideScope(
                        coordinator: pendingCoordinator, child: child!),
              ),
      ),
    ));
    if (!guided) {
      router.go(AppRoutes.confirm);
      await _pumpUntil(tester, () => fixture.saveButton.evaluate().isNotEmpty,
          'The ordinary ConfirmScreen should mount');
      return fixture;
    }
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

class _EndedSaveGuide implements GuideCoordinator {
  @override
  final ValueNotifier<GuideSnapshot> state = ValueNotifier(const GuideSnapshot(
    uid: _uid,
    version: realUiGuideVersion,
    revision: 2,
    serverRevision: 2,
    run: GuideRun.terminal,
    step: GuideStep.completed,
  ));

  void dispose() => state.dispose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EventStore extends EventRepository {
  final savedEvents = <EventModel>[];
  int overlapCalls = 0;
  int createCalls = 0;
  int updateCalls = 0;
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
  Future<EventModel> updateEvent(EventModel event) async {
    final index = savedEvents.indexWhere(
      (saved) => saved.id == event.id && saved.userId == event.userId,
    );
    if (index == -1) throw StateError('Event not found');
    updateCalls++;
    savedEvents[index] = event;
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) =>
      throw UnsupportedError('Unexpected event deletion');
}

class _ConfirmBackend extends ConfirmScreenBackend {
  final reminderBatches = <List<Map<String, dynamic>>>[];

  @override
  Future<List<String>> fetchPastSupplies(
          {required String userId, required String location}) async =>
      const [];

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    reminderBatches.add(payloads);
  }

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
  Future<GeoPoint?> getLastKnownLocation() async => null;

  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async =>
      null;
}

class _DeferredLocationLookup extends LocationLookupService {
  _DeferredLocationLookup(this.repository);

  final _EventStore repository;
  final savedEventLookups = <String>[];
  final reply = Completer<List<LocationLookupResult>>();

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    if (repository.savedEvents.isEmpty) return const [];
    savedEventLookups.add(query);
    return reply.future;
  }
}

class _RecordingNotifications extends NotificationService {
  final criticalAlarms = <DateTime>[];

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    criticalAlarms.add(notifyAt);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}

class _DeferredDepartureAlarms extends DepartureAlarmService {
  final attempts = <EventModel>[];
  final finishCreatePreparation = Completer<void>();

  @override
  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,
    bool cacheOnlyLocation = false,
  }) async {
    attempts.add(event);
    if (attempts.length == 1) await finishCreatePreparation.future;
    return const DepartureAlarmScheduleResult.skipped('test_no_route');
  }
}

class _RecordingHomeWidget extends HomeWidgetService {
  @override
  Future<bool> updateSchedulePayload(
    HomeWidgetSchedulePayload payload, {
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async =>
      true;
}
