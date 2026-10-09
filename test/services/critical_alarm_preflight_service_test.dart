import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/critical_alarm_acknowledgement_store.dart';
import 'package:planflow/services/critical_alarm_preflight_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _routed30 = TravelTimeBufferEstimate(
  buffer: Duration(minutes: 30),
  source: TravelTimeBufferSource.tmap,
  reason: 'test',
);

final _testDay = DateTime.now().add(const Duration(days: 30));
DateTime _at(int hour, [int minute = 0, int second = 0]) =>
    DateTime(_testDay.year, _testDay.month, _testDay.day, hour, minute, second);

EventModel _event({
  String id = 'event-1',
  DateTime? startAt,
  bool isCritical = true,
  bool useStrongAlarm = true,
  double? lat = 36.327,
  double? lng = 127.427,
  String title = '13시 병원 예약',
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt ?? _at(13),
    location: '대전 성심당',
    locationLat: lat,
    locationLng: lng,
    isCritical: isCritical,
    useStrongAlarm: useStrongAlarm,
  );
}

UserSettingsModel _settings(
        {int margin = 0,
        String travelMode = 'car',
        String provider = 'tmap'}) =>
    UserSettingsModel.defaults(userId: 'user-1').copyWith(
      departureSafetyMarginMin: margin,
      travelMode: travelMode,
      preferredMapProvider: provider,
    );

/// 실제 CriticalAlarmPreflightService 로직 + 기록용 가짜 경계(알림/알람/위치/
/// 경로/설정/이벤트). 실제 OS 알람만 대체한다.
class _Harness {
  _Harness({
    List<EventModel>? events,
    UserSettingsModel? settings,
    TravelTimeBufferEstimate estimate = _routed30,
    DateTime? now,
    bool android = true,
    bool supabaseReady = true,
    CriticalPreflightBudget budget = const CriticalPreflightBudget(),
    AppPermissionService? permissions,
    bool injectLocation = true,
  })  : now = now ?? _at(11),
        repo = _FakeEventRepository(events ?? <EventModel>[_event()]),
        settingsRepo = _FakeSettingsRepository(settings ?? _settings()),
        travel = _FakeTravelService(estimate) {
    service = CriticalAlarmPreflightService(
      notificationService: notifications,
      eventRepository: repo,
      settingsRepository: settingsRepo,
      travelTimeBufferService: travel,
      acknowledgementStore: acks,
      permissionService: permissions ??
          _ScriptedPermissionService(fresh: null, lastKnown: null),
      freshLocationProvider: injectLocation ? _location : null,
      preflightScheduler: scheduler.call,
      preflightCanceller: scheduler.cancel,
      now: () => this.now,
      supabaseReadyOverride: supabaseReady,
      androidOverride: android,
      budget: budget,
    );
  }

  DateTime now;
  GeoPoint? location = const GeoPoint(latitude: 37.5, longitude: 127);
  Future<GeoPoint?> Function()? locationOverride;
  int locationCalls = 0;
  final notifications = _RecordingNotificationService();
  final scheduler = _RecordingPreflightScheduler();
  final acks = _MutableAckStore();
  final _FakeEventRepository repo;
  final _FakeSettingsRepository settingsRepo;
  final _FakeTravelService travel;
  late final CriticalAlarmPreflightService service;

  Future<GeoPoint?> _location() async {
    locationCalls += 1;
    final override = locationOverride;
    if (override != null) {
      return override();
    }
    return location;
  }

  int get legacyCriticalId =>
      notifications.notificationIdFor('event-1:critical');

  int audibleIdFor(String generation, [String eventId = 'event-1']) =>
      notifications.notificationIdFor(
        CriticalAlarmPreflightService.audibleKeyFor(eventId, generation),
      );

  Future<NotificationScheduleResult> arm({
    EventModel? event,
    DateTime? notifyAt,
  }) {
    final target = event ?? repo.events.first;
    return service.scheduleCriticalAlarmWithTravelRecalc(
      event: target,
      id: notifications.notificationIdFor('${target.id}:critical'),
      title: target.title,
      notifyAt: notifyAt ?? target.startAt!.subtract(const Duration(hours: 1)),
      body: '중요 일정이 곧 시작됩니다.',
      payload: 'event:${target.id}',
      useStrongAlarm: target.useStrongAlarm,
    );
  }

  Future<CriticalPreflightOutcome> fire([CriticalPreflightRequest? request]) {
    return service.runCriticalPreflight(request ?? scheduler.requests.last);
  }
}

const _ownershipChannel = MethodChannel('planflow/critical_alarm_ownership');
final _owners = <String, Map<String, dynamic>>{};
int _ownershipInvocationCount = 0;
String? _ownershipFailure;
Future<void> Function()? _beforeOwnerReplace;
Future<Object?> _ownershipHandler(MethodCall call) async {
  _ownershipInvocationCount++;
  if (_ownershipFailure == call.method) {
    throw PlatformException(code: 'storage_failure');
  }
  final a = Map<String, dynamic>.from(call.arguments as Map? ?? {});
  final id = a['eventId'] as String?;
  final owner = _owners[id];
  bool matches(String genKey, String timeKey) =>
      owner != null &&
      owner['generation'] == a[genKey] &&
      owner['triggerAt'] == a[timeKey];
  Map<String, dynamic> newOwner() => {
        'generation': a['generation'],
        'triggerAt': a['triggerAt'],
        'originalNotifyAt': a['originalNotifyAt'],
        'claimedTrigger': null,
        'metadataJson': a['metadataJson'],
      };
  switch (call.method) {
    case 'readOwner':
      return owner == null ? null : Map<String, dynamic>.from(owner);
    case 'listOwners':
      return {
        for (final e in _owners.entries)
          e.key: Map<String, dynamic>.from(e.value)
      };
    case 'updateOwner':
      final previous = owner == null ? null : Map<String, dynamic>.from(owner);
      _owners[id!] = newOwner();
      return previous;
    case 'invalidateOwner':
      return _owners.remove(id);
    case 'claimTrigger':
      if (!matches('generation', 'triggerAt') ||
          owner!['claimedTrigger'] == a['triggerAt']) {
        return false;
      }
      owner['claimedTrigger'] = a['triggerAt'];
      return true;
    case 'updateTriggerIfOwner':
      if (!matches('generation', 'expectedTrigger')) return false;
      owner!['triggerAt'] = a['nextTrigger'];
      owner['claimedTrigger'] = null;
      return true;
    case 'releaseIfOwner':
      if (!matches('generation', 'expectedTrigger')) return false;
      _owners.remove(id);
      return true;
    case 'replaceOwnerIfMatches':
      final before = _beforeOwnerReplace;
      _beforeOwnerReplace = null;
      await before?.call();
      final current = _owners[id];
      if (current == null ||
          current['generation'] != a['expectedGeneration'] ||
          current['triggerAt'] != a['expectedTrigger']) {
        return false;
      }
      _owners[id!] = newOwner();
      return true;
  }
  throw MissingPluginException('Unexpected ownership method');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _owners.clear();
    _ownershipInvocationCount = 0;
    _ownershipFailure = null;
    _beforeOwnerReplace = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ownershipChannel, _ownershipHandler);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ownershipChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.windows]) {
    testWidgets('unsupported $platform ownership APIs have no RPC or timers',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final before = _ownershipInvocationCount;
        expect(
            await CriticalAlarmPreflightService.isDynamicCriticalArmed(
                'event-1'),
            isFalse);
        expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
            isNull);
        await CriticalAlarmPreflightService.cancelScheduledPreflight('event-1');
        expect(
            await const CriticalAlarmPreflightService()
                .restorePendingAfterConsentRevoked(),
            {'restored': 0, 'skipped': 0, 'failed': 0});
        expect(_ownershipInvocationCount, before);
        expect(tester.binding.transientCallbackCount, 0);
        // testWidgets also asserts that no pending Timer survives test completion.
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  test('restore respects Android override false without any ownership RPC',
      () async {
    final h = _Harness(android: false);
    final before = _ownershipInvocationCount;
    expect(await h.service.restorePendingAfterConsentRevoked(),
        {'restored': 0, 'skipped': 0, 'failed': 0});
    expect(_ownershipInvocationCount, before);
  });

  test('preflight budget fits inside the 90s watchdog allowance', () {
    const budget = CriticalPreflightBudget();
    final worstCase = budget.supabaseInit + budget.total + budget.eventFetch;
    expect(worstCase, lessThan(CriticalAlarmPreflightService.watchdogDelay));
    expect(
      CriticalAlarmPreflightService.watchdogDelay - worstCase,
      greaterThanOrEqualTo(const Duration(seconds: 20)),
    );
  });

  test(
      'consent restore returns postponed chain to original time under a new owner',
      () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    await h.fire();
    final old =
        await CriticalAlarmPreflightService.currentGeneration('event-1');
    h.now = _at(12, 5);
    final result = await h.service.restorePendingAfterConsentRevoked();
    expect(result, {'restored': 1, 'skipped': 0, 'failed': 0});
    final replacement =
        await CriticalAlarmPreflightService.currentGeneration('event-1');
    expect(replacement, isNot(old));
    expect(h.notifications.pending.keys, [h.audibleIdFor(replacement!)]);
    expect(h.notifications.pending.values.single.notifyAt, _at(12, 5, 3));
    expect(
        await CriticalAlarmPreflightService.isDynamicCriticalArmed('event-1'),
        isFalse);
    expect((await h.fire()).detail, 'stale_generation');
    expect(h.notifications.pending.keys, [h.audibleIdFor(replacement)]);
  });

  test('consent restore before original time never rings early', () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(11, 30);
    expect(await h.service.restorePendingAfterConsentRevoked(),
        {'restored': 1, 'skipped': 0, 'failed': 0});
    expect(h.notifications.pending.values.single.notifyAt, _at(12));
  });

  test('staged failure preserves old watchdog during stale callback', () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    await h.fire();
    final old = h.scheduler.requests.last;
    final oldId = h.audibleIdFor(old.generation);
    final oldAlarm = h.notifications.pending[oldId];
    h.now = _at(12, 5);
    h.notifications.failAt = _at(12, 5, 3);
    h.notifications.onCriticalSchedule = () async {
      expect((await h.fire(old)).detail, 'stale_generation');
      expect(h.notifications.pending[oldId], oldAlarm);
    };
    expect(await h.service.restorePendingAfterConsentRevoked(),
        {'restored': 0, 'skipped': 0, 'failed': 1});
    expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
        old.generation);
    expect(h.notifications.pending[oldId], oldAlarm);
    expect(h.notifications.cancelledIds.where((id) => id == oldId), isEmpty);
  });

  test('staged success cancels old watchdog once after delivery', () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    await h.fire();
    final old = h.scheduler.requests.last;
    final oldId = h.audibleIdFor(old.generation);
    h.now = _at(12, 5);
    h.notifications.onCriticalSchedule = () async {
      await h.fire(old);
      expect(h.notifications.pending.containsKey(oldId), isTrue);
      expect(h.notifications.cancelledIds.where((id) => id == oldId), isEmpty);
    };
    expect(await h.service.restorePendingAfterConsentRevoked(),
        {'restored': 1, 'skipped': 0, 'failed': 0});
    expect(
        h.notifications.cancelledIds.where((id) => id == oldId), hasLength(1));
    expect(h.notifications.pending.containsKey(oldId), isFalse);
  });

  test('ACK during restore stage cancels old and new owners', () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    await h.fire();
    final old = h.scheduler.requests.last;
    String? replacement;
    h.now = _at(12, 5);
    h.notifications.onCriticalSchedule = () async {
      replacement =
          await CriticalAlarmPreflightService.currentGeneration('event-1');
      await h.acks.markAcknowledged('event-1', _at(13));
      await CriticalAlarmPreflightService.cancelScheduledPreflight('event-1',
          notifications: h.notifications, alarmCanceller: h.scheduler.cancel);
    };
    await h.service.restorePendingAfterConsentRevoked();
    expect(h.notifications.pending, isEmpty);
    expect(
        h.notifications.cancelledIds,
        containsAll([
          h.audibleIdFor(old.generation),
          h.audibleIdFor(replacement!),
        ]));
    expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
        isNull);
  });

  for (final action in ['ack', 'delete']) {
    test('consent restore $action guard prevents alarm resurrection', () async {
      final h = _Harness();
      await h.arm();
      h.now = _at(12);
      await h.fire();
      if (action == 'ack') {
        await h.acks.markAcknowledged('event-1', _at(13));
      } else {
        h.repo.events.clear();
      }
      expect(await h.service.restorePendingAfterConsentRevoked(),
          {'restored': 0, 'skipped': 1, 'failed': 0});
      expect(h.notifications.pending, isEmpty);
      expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
          isNull);
    });
  }

  test('consent restore snapshot CAS cannot overwrite a newly armed owner',
      () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    await h.fire();
    String? latest;
    _beforeOwnerReplace = () async {
      h.now = _at(11);
      await h.arm();
      latest = await CriticalAlarmPreflightService.currentGeneration('event-1');
    };
    final result = await h.service.restorePendingAfterConsentRevoked();
    expect(result, {'restored': 0, 'skipped': 1, 'failed': 0});
    expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
        latest);
    expect(h.notifications.pending.keys, [h.audibleIdFor(latest!)]);
  });

  test('old same-generation release cannot delete a rearmed owner', () async {
    final h = _Harness();
    await h.arm();
    final request = h.scheduler.requests.single;
    h.now = _at(12);
    await h.fire();
    expect(
        await _ownershipChannel.invokeMethod<bool>('releaseIfOwner', {
          'eventId': request.eventId,
          'generation': request.generation,
          'expectedTrigger': request.triggerAt.millisecondsSinceEpoch,
        }),
        isFalse);
    expect(
        _owners['event-1']!['triggerAt'], _at(12, 30).millisecondsSinceEpoch);
  });

  test('owner storage failure keeps callback watchdog without prefs fallback',
      () async {
    final h = _Harness();
    await h.arm();
    final pending = Map<int, _Scheduled>.of(h.notifications.pending);
    h.now = _at(12);
    _ownershipFailure = 'claimTrigger';
    expect((await h.fire()).kind, CriticalPreflightOutcomeKind.watchdogKept);
    expect(h.notifications.pending, pending);
    expect(h.locationCalls, 0);
  });

  test('request preserves original alarm time after rearm and params roundtrip',
      () {
    final request = CriticalPreflightRequest(
      eventId: 'event-1',
      userId: 'user-1',
      generation: 'original-time',
      triggerAt: _at(12),
      occurrenceStartAt: _at(13),
      title: 'meeting',
    ).rearmedAt(_at(12, 30));
    final restored = CriticalPreflightRequest.fromParams(request.toParams())!;
    expect(restored.triggerAt, _at(12, 30));
    expect(restored.originalTriggerAt, _at(12));
  });

  test('consent revoked during GPS sends no coordinates to route provider',
      () async {
    final permissions =
        _ScriptedPermissionService(fresh: null, lastKnown: null);
    final h = _Harness(permissions: permissions);
    await h.arm();
    h.now = _at(12);
    h.locationOverride = () async {
      permissions.backgroundCapability = false;
      return h.location;
    };
    final result = await h.fire();
    expect(result.kind, CriticalPreflightOutcomeKind.rangNow);
    expect(result.detail, 'consent_revoked_before_route');
    expect(h.travel.calls, isEmpty);
    expect(h.scheduler.requests.length, 1);
  });

  test(
      'consent revoked during route restores original alarm instead of postpone',
      () async {
    final permissions =
        _ScriptedPermissionService(fresh: null, lastKnown: null);
    final h = _Harness(permissions: permissions);
    await h.arm();
    h.now = _at(12);
    h.travel.onRoute = () async {
      permissions.backgroundCapability = false;
      return _routed30;
    };
    final result = await h.fire();
    expect(result.kind, CriticalPreflightOutcomeKind.rangNow);
    expect(result.detail, 'consent_revoked_before_postpone');
    expect(h.scheduler.requests.length, 1);
    expect(h.notifications.pending.values.single.notifyAt, _at(12, 0, 3));
  });

  for (final failure in ['off_or_denied', 'probe_error', 'probe_timeout']) {
    test('headless capability $failure keeps original alarm without watchdog',
        () async {
      final permissions =
          _ScriptedPermissionService(fresh: null, lastKnown: null);
      permissions.backgroundCapability = false;
      permissions.capabilityError =
          failure == 'probe_error' ? StateError('probe failed') : null;
      permissions.capabilityHangs = failure == 'probe_timeout';
      final h = _Harness(
        permissions: permissions,
        budget:
            const CriticalPreflightBudget(settings: Duration(milliseconds: 10)),
      );
      expect((await h.arm()).isScheduled, isTrue);
      expect(h.notifications.pending.keys, [h.legacyCriticalId]);
      expect(h.notifications.pending.values.single.notifyAt, _at(12));
      expect(h.scheduler.requests, isEmpty);
      expect(permissions.freshCalls, 0);
      expect(permissions.capabilityCalls, 1);
      expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
          isNull);
    });
  }

  test('concurrent duplicate trigger performs only one fresh GPS request',
      () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    final entered = Completer<void>();
    final fix = Completer<GeoPoint?>();
    h.locationOverride = () {
      entered.complete();
      return fix.future;
    };
    final first = h.fire();
    await entered.future;
    expect((await h.fire()).detail, 'duplicate_trigger');
    fix.complete(h.location);
    expect((await first).kind, CriticalPreflightOutcomeKind.rearmed);
    expect(h.locationCalls, 1);
  });

  test('destination changed during route cannot postpone from old ETA',
      () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    h.travel.onRoute = () async {
      h.repo.events[0] = _event(lat: 35, lng: 129);
      return _routed30;
    };
    expect((await h.fire()).kind, CriticalPreflightOutcomeKind.rangNow);
    expect(h.scheduler.requests.length, 1);
  });

  test('travel settings changed during route cannot postpone from old ETA',
      () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    h.travel.onRoute = () async {
      h.settingsRepo.value =
          _settings(provider: 'naver', travelMode: 'transit');
      return _routed30;
    };
    final result = await h.fire();
    expect(result.kind, CriticalPreflightOutcomeKind.rangNow);
    expect(result.detail, 'settings_changed');
    expect(h.scheduler.requests.length, 1);
  });

  test('a route from an unselected provider never postpones the alarm',
      () async {
    final h = _Harness(settings: _settings(provider: 'naver'));
    await h.arm();
    h.now = _at(12);
    expect((await h.fire()).kind, CriticalPreflightOutcomeKind.rangNow);
    expect(h.scheduler.requests.length, 1);
  });

  test('selected Naver route respects transit settings', () async {
    final h = _Harness(
      settings: _settings(provider: 'naver', travelMode: 'transit'),
      estimate: const TravelTimeBufferEstimate(
        buffer: Duration(minutes: 30),
        source: TravelTimeBufferSource.naverMap,
        reason: 'selected provider',
      ),
    );
    await h.arm();
    h.now = _at(12);
    expect((await h.fire()).rearmedAt, _at(12, 30));
    expect(h.travel.calls.single.mode, MapTravelMode.transit);
  });

  test('duplicate old trigger cannot replace the postponed watchdog', () async {
    final h = _Harness();
    await h.arm();
    final old = h.scheduler.requests.single;
    h.now = _at(12);
    expect((await h.fire(old)).kind, CriticalPreflightOutcomeKind.rearmed);
    final scheduled = h.notifications.scheduledAt.length;
    expect((await h.fire(old)).detail, 'duplicate_trigger');
    expect(h.locationCalls, 1);
    expect(h.notifications.scheduledAt.length, scheduled);
  });

  test('remote delete during failed GPS does not ring fallback', () async {
    final h = _Harness();
    await h.arm();
    h.now = _at(12);
    h.locationOverride = () async {
      h.repo.events.clear();
      return null;
    };
    expect((await h.fire()).kind, CriticalPreflightOutcomeKind.aborted);
    expect(h.notifications.pending, isEmpty);
  });

  test('cancellation during refused initial schedule cannot arm legacy',
      () async {
    final h = _Harness();
    h.scheduler.onSchedule = (request) async {
      await CriticalAlarmPreflightService.cancelScheduledPreflight(
        request.eventId,
        notifications: h.notifications,
        alarmCanceller: h.scheduler.cancel,
      );
    };
    final result = await h.arm();
    expect(result.isScheduled, isFalse);
    expect(h.notifications.pending, isEmpty);
  });

  group('13:00 meeting example', () {
    test('12:00 old fire time is silent; fresh 30min ETA rearms to 12:30',
        () async {
      final h = _Harness(settings: _settings(margin: 0, travelMode: 'transit'));

      final armed = await h.arm();
      expect(armed.isScheduled, isTrue);
      expect(armed.notifyAt, _at(12));
      final generation = h.scheduler.requests.single.generation;
      expect(h.scheduler.requests.single.triggerAt, _at(12));
      expect(h.scheduler.requests.single.occurrenceStartAt, _at(13));
      // Nothing audible at 12:00: only the gen-owned watchdog at 12:01:30.
      expect(h.notifications.pending.keys, [h.audibleIdFor(generation)]);
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 1, 30));
      expect(h.notifications.pending.containsKey(h.legacyCriticalId), isFalse);
      expect(
          await CriticalAlarmPreflightService.isDynamicCriticalArmed('event-1'),
          isTrue);

      h.now = _at(12);
      final outcome = await h.fire();

      expect(outcome.kind, CriticalPreflightOutcomeKind.rearmed);
      expect(outcome.rearmedAt, _at(12, 30));
      expect(h.travel.calls.single.origin.latitude, 37.5);
      expect(h.travel.calls.single.mode, MapTravelMode.transit);
      expect(h.scheduler.requests.last.triggerAt, _at(12, 30));
      expect(h.scheduler.requests.last.generation, generation);
      // Watchdog replaced (same gen-owned id) to 12:31:30; nothing at/before 12:30.
      expect(h.notifications.pending.length, 1);
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 31, 30));
      // Nothing was ever scheduled to sound at the old 12:00 fire time, and
      // the only pending audible (the replaced watchdog) is after 12:30.
      expect(
        h.notifications.scheduledAt.where((at) => !at.isAfter(_at(12))),
        isEmpty,
      );
      expect(
        h.notifications.pending.values.where(
          (entry) => !entry.notifyAt.isAfter(_at(12, 30)),
        ),
        isEmpty,
      );

      // Re-evaluated at the new 12:30 trigger: still 30min => due now.
      h.now = _at(12, 30);
      final second = await h.fire();
      expect(second.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(second.detail, 'due_now');
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 30, 3));
      expect(h.travel.calls, hasLength(2));
    });

    test('each new trigger re-evaluates: 12:30 trigger with 20min ETA -> 12:40',
        () async {
      final h = _Harness();
      await h.arm();
      h.now = _at(12);
      await h.fire();
      h.travel.routeEstimate = const TravelTimeBufferEstimate(
        buffer: Duration(minutes: 20),
        source: TravelTimeBufferSource.tmap,
        reason: 'test',
      );
      h.now = _at(12, 30);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rearmed);
      expect(outcome.rearmedAt, _at(12, 40));
    });

    test('stored safety margin is respected (20min => 12:10)', () async {
      final h = _Harness(settings: _settings(margin: 20));
      await h.arm();
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.rearmedAt, _at(12, 10));
    });

    test('departure already past at old fire time rings immediately', () async {
      final h = _Harness(
        settings: _settings(provider: 'google'),
        estimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 75),
          source: TravelTimeBufferSource.googleMaps,
          reason: 'test',
        ),
      );
      await h.arm();
      final generation = h.scheduler.requests.single.generation;
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(outcome.detail, 'due_now');
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 0, 3));
      expect(h.scheduler.requests, hasLength(1));
    });

    test('departure 29s in the future: exact ring at departure, never early',
        () async {
      final h = _Harness();
      await h.arm();
      final generation = h.scheduler.requests.single.generation;
      h.now = _at(12, 29, 31);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rearmed);
      expect(outcome.detail, 'exact');
      expect(outcome.rearmedAt, _at(12, 30));
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 30));
      // No zero-delay headless re-run loop.
      expect(h.scheduler.requests, hasLength(1));
    });
  });

  group('bounded fail-safe (no postponement)', () {
    Future<void> expectRing(_Harness h, String reason) async {
      await h.arm();
      final generation = h.scheduler.requests.single.generation;
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(outcome.detail, reason);
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 0, 3));
      expect(h.scheduler.requests, hasLength(1));
    }

    test('no fresh location', () async {
      final h = _Harness()..location = null;
      await expectRing(h, 'no_fresh_location');
    });

    test('location getter hangs -> bounded timeout', () async {
      final h = _Harness(
        budget: const CriticalPreflightBudget(
          location: Duration(milliseconds: 50),
        ),
      )..locationOverride = () => Completer<GeoPoint?>().future;
      final watch = Stopwatch()..start();
      await expectRing(h, 'no_fresh_location');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('settings null (unverifiable stored settings)', () async {
      final h = _Harness()..settingsRepo.value = null;
      await expectRing(h, 'settings_unavailable');
    });

    test('settings throw', () async {
      final h = _Harness()..settingsRepo.error = StateError('offline');
      await expectRing(h, 'settings_unavailable');
    });

    test('settings hang -> bounded', () async {
      final h = _Harness(
        budget: const CriticalPreflightBudget(
          settings: Duration(milliseconds: 50),
        ),
      )..settingsRepo.hang = true;
      await expectRing(h, 'settings_unavailable');
    });

    test('heuristic fallback estimate is not a route', () async {
      final h = _Harness(
        estimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 5),
          source: TravelTimeBufferSource.coordinates,
          reason: 'fallback',
        ),
      );
      await expectRing(h, 'unrouted_estimate_coordinates');
    });

    test('route throws', () async {
      final h = _Harness()..travel.error = StateError('http 500');
      await expectRing(h, 'unrouted_estimate_error');
    });

    test('route hangs -> bounded timeout', () async {
      final h = _Harness(
        budget: const CriticalPreflightBudget(
          route: Duration(milliseconds: 50),
        ),
      )..travel.hang = true;
      await expectRing(h, 'unrouted_estimate_timeout');
    });

    test('overall budget exhausted -> ring', () async {
      final h = _Harness(
        budget: const CriticalPreflightBudget(
          total: Duration(milliseconds: 150),
        ),
      )
        ..locationOverride = () async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return const GeoPoint(latitude: 37.5, longitude: 127);
        }
        ..settingsRepo.hang = true;
      final watch = Stopwatch()..start();
      // settings step (6s) is clipped to the remaining overall budget.
      await expectRing(h, 'settings_unavailable');
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('event fetch failure rings with the original alarm details', () async {
      final h = _Harness();
      await h.arm();
      h.repo.error = StateError('network');
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.detail, 'event_fetch_failed');
      final ring = h.notifications.pending.values.single;
      expect(ring.title, '13시 병원 예약');
      expect(ring.payload, 'event:event-1');
    });

    test('supabase unavailable in headless isolate -> ring', () async {
      final h = _Harness(supabaseReady: false);
      await expectRing(h, 'supabase_unavailable');
    });

    test('recheck fetch failure after route -> ring, not postpone', () async {
      final h = _Harness();
      await h.arm();
      h.now = _at(12);
      h.repo.failAfterCalls = 1;
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(outcome.detail, 'recheck_failed');
    });
  });

  group('cancel / ACK / delete / edit / disable during await', () {
    Future<_Harness> armedWaitingOnGps(Completer<GeoPoint?> gps) async {
      final h = _Harness()..locationOverride = () => gps.future;
      await h.arm();
      h.now = _at(12);
      return h;
    }

    test('ACK during GPS await (real ACK cancel hook) does not resurrect',
        () async {
      final gps = Completer<GeoPoint?>();
      final h = await armedWaitingOnGps(gps);
      final pendingRun = h.fire();
      await pumpEventQueue();
      await h.acks.markAcknowledged('event-1', _at(13));
      await h.notifications.cancelEventNotifications('event-1');
      gps.complete(const GeoPoint(latitude: 37.5, longitude: 127));
      final outcome = await pendingRun;
      expect(outcome.kind, CriticalPreflightOutcomeKind.aborted);
      expect(h.notifications.pending, isEmpty);
      expect(h.scheduler.requests, hasLength(1));
    });

    test('occurrence ACK already stored at old fire time cleans up', () async {
      final h = _Harness();
      await h.arm();
      await h.acks.markAcknowledged('event-1', _at(13));
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.detail, 'critical_acknowledged');
      expect(h.notifications.pending, isEmpty);
      expect(h.locationCalls, 0);
      expect(
          await CriticalAlarmPreflightService.isDynamicCriticalArmed('event-1'),
          isFalse);
    });

    test('ACK for a different occurrence does not gate this one', () async {
      final h = _Harness();
      await h.arm();
      await h.acks.markAcknowledged(
          'event-1',
          _at(13).subtract(
            const Duration(days: 7),
          ));
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rearmed);
    });

    test('delete during GPS await does not resurrect', () async {
      final gps = Completer<GeoPoint?>();
      final h = await armedWaitingOnGps(gps);
      final pendingRun = h.fire();
      await pumpEventQueue();
      h.repo.events.clear();
      await h.notifications.cancelEventNotifications('event-1');
      gps.complete(const GeoPoint(latitude: 37.5, longitude: 127));
      final outcome = await pendingRun;
      expect(outcome.kind, CriticalPreflightOutcomeKind.aborted);
      expect(h.notifications.pending, isEmpty);
    });

    test('remote delete without local cancel: event_not_found, no ring',
        () async {
      final h = _Harness();
      await h.arm();
      h.repo.events.clear();
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.detail, 'event_not_found');
      expect(h.notifications.pending, isEmpty);
    });

    test('edit during await re-arms a newer generation that stays intact',
        () async {
      final gps = Completer<GeoPoint?>();
      final h = await armedWaitingOnGps(gps);
      final oldRequest = h.scheduler.requests.single;
      final pendingRun = h.fire(oldRequest);
      await pumpEventQueue();
      // User edits 13:00 -> 14:00; the real edit path re-arms.
      final edited = _event(startAt: _at(14));
      h.repo.events
        ..clear()
        ..add(edited);
      await h.arm(event: edited, notifyAt: _at(13));
      final newRequest = h.scheduler.requests.last;
      expect(newRequest.generation, isNot(oldRequest.generation));
      gps.complete(const GeoPoint(latitude: 37.5, longitude: 127));
      final outcome = await pendingRun;

      expect(outcome.kind, CriticalPreflightOutcomeKind.aborted);
      expect(h.scheduler.requests, hasLength(2));
      // Newer generation's watchdog and preflight alarm are untouched.
      expect(h.notifications.pending.keys,
          [h.audibleIdFor(newRequest.generation)]);
      expect(h.notifications.pending.values.single.notifyAt, _at(13, 1, 30));
      expect(
        h.scheduler.cancelledAlarmIds,
        isNot(contains(CriticalAlarmPreflightService.preflightAlarmIdFor(
          'event-1',
          newRequest.generation,
        ))),
      );
      expect(await CriticalAlarmPreflightService.currentGeneration('event-1'),
          newRequest.generation);
    });

    test('disable strong alarm during await (real reminder cancel hook)',
        () async {
      final gps = Completer<GeoPoint?>();
      final h = await armedWaitingOnGps(gps);
      final pendingRun = h.fire();
      await pumpEventQueue();
      h.repo.events[0] = _event(useStrongAlarm: false);
      await h.notifications.cancelEventReminderNotifications('event-1');
      gps.complete(const GeoPoint(latitude: 37.5, longitude: 127));
      final outcome = await pendingRun;
      expect(outcome.kind, CriticalPreflightOutcomeKind.aborted);
      expect(h.notifications.pending, isEmpty);
    });

    test('stale generation run only cancels its own artifacts', () async {
      final h = _Harness();
      await h.arm();
      final first = h.scheduler.requests.single;
      await h.arm();
      final current = h.scheduler.requests.last;
      h.now = _at(12);
      final outcome = await h.fire(first);
      expect(outcome.detail, 'stale_generation');
      expect(
          h.notifications.pending.keys, [h.audibleIdFor(current.generation)]);
      expect(h.locationCalls, 0);
    });

    test('ACK while rearm is in flight: post-check cancels own replacement',
        () async {
      final h = _Harness();
      await h.arm();
      h.now = _at(12);
      h.scheduler.onSchedule = (request) async {
        if (request.triggerAt == _at(12, 30)) {
          await h.acks.markAcknowledged('event-1', _at(13));
          await h.notifications.cancelEventNotifications('event-1');
        }
      };
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.aborted);
      expect(h.notifications.pending, isEmpty);
    });
  });

  group('scheduler failures and watchdog ownership', () {
    test(
        'initial scheduler refusal keeps a generation-owned fallback at old time',
        () async {
      final h = _Harness()..scheduler.accept = false;
      final result = await h.arm();
      expect(result.isScheduled, isTrue);
      final activeGeneration =
          await CriticalAlarmPreflightService.currentGeneration('event-1');
      expect(h.notifications.pending.keys, [h.audibleIdFor(activeGeneration!)]);
      expect(h.notifications.pending.values.single.notifyAt, _at(12));
      expect(
          await CriticalAlarmPreflightService.isDynamicCriticalArmed('event-1'),
          isTrue);
    });

    test('initial watchdog failure keeps owned fallback and cancels preflight',
        () async {
      final h = _Harness();
      h.notifications.failAt = _at(12, 1, 30);
      final result = await h.arm();
      final generation = h.scheduler.requests.single.generation;
      expect(result.isScheduled, isTrue);
      expect(h.notifications.pending.keys, [h.audibleIdFor(generation)]);
      expect(
        h.scheduler.cancelledAlarmIds,
        contains(CriticalAlarmPreflightService.preflightAlarmIdFor(
            'event-1', generation)),
      );
      expect(
          await CriticalAlarmPreflightService.isDynamicCriticalArmed('event-1'),
          isTrue);
    });

    test('rearm refusal rings now instead of waiting for the watchdog',
        () async {
      final h = _Harness();
      await h.arm();
      h.scheduler.accept = false;
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(outcome.detail, 'rearm_refused');
      expect(h.notifications.pending.values.single.notifyAt, _at(12, 0, 3));
    });

    test('watchdog rearm failure keeps the old gen-owned watchdog', () async {
      final h = _Harness();
      await h.arm();
      final generation = h.scheduler.requests.single.generation;
      h.notifications.failAt = _at(12, 31, 30);
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.watchdogKept);
      expect(h.notifications.pending[h.audibleIdFor(generation)]!.notifyAt,
          _at(12, 1, 30));
    });

    test('ring scheduling failure keeps the watchdog', () async {
      final h = _Harness()..location = null;
      await h.arm();
      h.notifications.failAt = _at(12, 0, 3);
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.watchdogKept);
      expect(h.notifications.pending.values.single.notifyAt, _at(12, 1, 30));
    });

    test('request survives AlarmManager params round-trip', () async {
      final h = _Harness();
      await h.arm();
      final request = h.scheduler.requests.single;
      final decoded = CriticalPreflightRequest.fromParams(request.toParams())!;
      expect(decoded.generation, request.generation);
      expect(decoded.occurrenceStartAt, request.occurrenceStartAt);
      expect(decoded.triggerAt, request.triggerAt);
      expect(decoded.title, request.title);
      expect(CriticalPreflightRequest.fromParams(<String, dynamic>{}), isNull);
    });
  });

  group('preserved legacy paths', () {
    Future<void> expectLegacy(_Harness h, EventModel event) async {
      h.repo.events
        ..clear()
        ..add(event);
      final result = await h.arm(event: event);
      expect(result.isScheduled, isTrue);
      expect(h.scheduler.requests, isEmpty);
      final legacyId =
          h.notifications.notificationIdFor('${event.id}:critical');
      expect(h.notifications.pending.keys, [legacyId]);
      expect(h.notifications.pending.values.single.notifyAt, _at(12));
    }

    test('iOS keeps legacy native alarm (no Dart pre-sound hook)', () async {
      await expectLegacy(_Harness(android: false), _event());
    });

    test('no location keeps legacy', () async {
      await expectLegacy(_Harness(), _event(lat: null, lng: null));
    });

    test('weak alarm keeps legacy', () async {
      await expectLegacy(_Harness(), _event(useStrongAlarm: false));
    });
  });

  group('native fresh getter path (no injected provider)', () {
    test('genuinely fresh stationary fix (same coords as lastKnown) is used',
        () async {
      final permissions = _ScriptedPermissionService(
        fresh: const GeoPoint(latitude: 37.5, longitude: 127),
        lastKnown: const GeoPoint(latitude: 37.5, longitude: 127),
      );
      final h = _Harness(permissions: permissions, injectLocation: false);
      await h.arm();
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.kind, CriticalPreflightOutcomeKind.rearmed);
      expect(permissions.freshCalls, 1);
      expect(permissions.backgroundPermissionRequirements, [true]);
      // Headless: no Activity channel permission check, no prompt, no cache.
      expect(permissions.checkPermissionCalls, 0);
      expect(permissions.requestPermissionCalls, 0);
      expect(permissions.lastKnownCalls, 0);
      expect(permissions.legacyCurrentCalls, 0);
    });

    test('getter null (no permission / stale / background) rings', () async {
      final permissions = _ScriptedPermissionService(
        fresh: null,
        lastKnown: const GeoPoint(latitude: 37.5, longitude: 127),
      );
      final h = _Harness(permissions: permissions, injectLocation: false);
      await h.arm();
      h.now = _at(12);
      final outcome = await h.fire();
      expect(outcome.detail, 'no_fresh_location');
      expect(outcome.kind, CriticalPreflightOutcomeKind.rangNow);
      expect(permissions.backgroundPermissionRequirements, [true]);
      expect(permissions.lastKnownCalls, 0);
      expect(permissions.requestPermissionCalls, 0);
    });
  });

  group('departure-only duplicate prompts', () {
    test('arming cancels pending departure-only prompts, keeps preparation',
        () async {
      final h = _Harness();
      final n = h.notifications;
      String body(String title) =>
          '스마트 준비 알람: $title\n13시 병원 예약 일정 전에 필요한 준비를 확인해 주세요.';
      final departNow = n.notificationIdFor('event-1:smart_preparation:2');
      final departSoon = n.notificationIdFor('event-1:pre_action:1');
      final prep = n.notificationIdFor('event-1:smart_preparation:0');
      final merged = n.notificationIdFor('event-1:smart_preparation:1');
      final otherEvent = n.notificationIdFor('event-2:smart_preparation:0');
      n.seedPending(departNow, body('지금 출발하세요 🚗 (이동 약 30분)'));
      n.seedPending(departSoon, body('30분 뒤 출발해야 해요 🔔'));
      n.seedPending(prep, body('지금 준비 시작하세요 🚿'));
      n.seedPending(merged, body('지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'));
      n.seedPending(otherEvent, body('지금 출발하세요 🚗 (이동 약 30분)'));

      await h.arm();

      expect(n.cancelledIds, containsAll(<int>[departNow, departSoon]));
      expect(n.pending.keys, containsAll(<int>[prep, merged, otherEvent]));
      expect(n.pending.keys, isNot(contains(departNow)));
    });

    test('legacy-path events keep their departure prompts', () async {
      final h = _Harness(android: false);
      final id =
          h.notifications.notificationIdFor('event-1:smart_preparation:0');
      h.notifications.seedPending(id, '스마트 준비 알람: 지금 출발하세요 🚗');
      await h.arm();
      expect(h.notifications.pending.keys, contains(id));
    });

    test(
        'smart prep / pre_action resync skips departure-only prompts only '
        'while the dynamic chain owns the event', () async {
      final h = _Harness();
      final start = DateTime.now().add(const Duration(hours: 5));
      final payloads = <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '지금 준비 시작하세요 🚿',
          'notify_at':
              start.subtract(const Duration(hours: 2)).toIso8601String(),
        },
        <String, dynamic>{
          'title': '30분 뒤 출발해야 해요 🔔',
          'notify_at':
              start.subtract(const Duration(minutes: 90)).toIso8601String(),
        },
        <String, dynamic>{
          'title': '지금 출발하세요 🚗 (이동 약 30분)',
          'notify_at':
              start.subtract(const Duration(hours: 1)).toIso8601String(),
        },
      ];
      final prep = SmartPreparationAlarmService(
        notificationService: h.notifications,
      );

      await prep.schedulePayloads(
        eventId: 'event-1',
        eventTitle: '13시 병원 예약',
        payloads: payloads,
        notificationKeyPrefix: 'pre_action',
      );
      expect(h.notifications.reminderBodies, hasLength(3));

      h.notifications.reminderBodies.clear();
      await h.arm();
      await prep.schedulePayloads(
        eventId: 'event-1',
        eventTitle: '13시 병원 예약',
        payloads: payloads,
        notificationKeyPrefix: 'pre_action',
      );
      expect(h.notifications.reminderBodies, hasLength(1));
      expect(h.notifications.reminderBodies.single, contains('준비 시작'));
    });
  });

  group('real critical callsite: Manual.scheduleLocalNotifications', () {
    test('strong located critical event arms the preflight chain', () async {
      final notifications = _RecordingNotificationService();
      final scheduler = _RecordingPreflightScheduler();
      final start = DateTime.now().add(const Duration(hours: 3));
      final event = EventModel(
        id: 'manual-1',
        userId: 'user-1',
        title: '중요 미팅',
        startAt: start,
        location: '서울역',
        locationLat: 37.55,
        locationLng: 126.97,
        isCritical: true,
        useStrongAlarm: true,
      );
      final manual = ManualEventSideEffectService(
        gateway: _NoopGateway(),
        eventRepository: _FakeEventRepository(<EventModel>[event]),
        departureAlarmService: const DepartureAlarmService(),
        notificationService: notifications,
        criticalAlarmAcknowledgementStore: _MutableAckStore(),
        criticalAlarmPreflightService: CriticalAlarmPreflightService(
          notificationService: notifications,
          permissionService:
              _ScriptedPermissionService(fresh: null, lastKnown: null),
          preflightScheduler: scheduler.call,
          preflightCanceller: scheduler.cancel,
          androidOverride: true,
        ),
      );

      await manual.scheduleLocalNotifications(
        event,
        criticalAlarmOffset: ManualEventSideEffectService.criticalAlarmOffset,
      );

      final request = scheduler.requests.single;
      expect(request.eventId, 'manual-1');
      expect(request.triggerAt, start.subtract(const Duration(hours: 1)));
      expect(request.occurrenceStartAt, start);
      expect(
        notifications.pending.containsKey(
          notifications.notificationIdFor('manual-1:critical'),
        ),
        isFalse,
      );
      expect(
        notifications.pending.values.single.notifyAt,
        start
            .subtract(const Duration(hours: 1))
            .add(CriticalAlarmPreflightService.watchdogDelay),
      );
    });

    test('resync cancels the old chain even when ACK prevents re-arming',
        () async {
      final notifications = _RecordingNotificationService();
      final scheduler = _RecordingPreflightScheduler();
      final acks = _MutableAckStore();
      final start = DateTime.now().add(const Duration(hours: 3));
      final event = EventModel(
        id: 'manual-2',
        userId: 'user-1',
        title: '중요 미팅',
        startAt: start,
        location: '서울역',
        locationLat: 37.55,
        locationLng: 126.97,
        isCritical: true,
        useStrongAlarm: true,
      );
      final manual = ManualEventSideEffectService(
        gateway: _NoopGateway(),
        eventRepository: _FakeEventRepository(<EventModel>[event]),
        departureAlarmService: const DepartureAlarmService(),
        notificationService: notifications,
        criticalAlarmAcknowledgementStore: acks,
        criticalAlarmPreflightService: CriticalAlarmPreflightService(
          notificationService: notifications,
          permissionService:
              _ScriptedPermissionService(fresh: null, lastKnown: null),
          preflightScheduler: scheduler.call,
          preflightCanceller: scheduler.cancel,
          androidOverride: true,
        ),
      );
      await manual.scheduleLocalNotifications(
        event,
        criticalAlarmOffset: ManualEventSideEffectService.criticalAlarmOffset,
      );
      expect(notifications.pending, hasLength(1));

      await acks.markAcknowledged('manual-2', start);
      final ok = await manual.resyncRemindersForEvents(
        events: <EventModel>[event],
        userId: 'user-1',
      );

      expect(ok, isTrue);
      expect(notifications.pending, isEmpty);
      expect(
          await CriticalAlarmPreflightService.isDynamicCriticalArmed(
              'manual-2'),
          isFalse);
    });
  });
}

class _Scheduled {
  _Scheduled(this.notifyAt, {this.title, this.payload, this.body});

  final DateTime notifyAt;
  final String? title;
  final String? payload;
  final String? body;
}

class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService() : super(allowPermissionRequests: false);

  final pending = <int, _Scheduled>{};
  final cancelledIds = <int>[];
  final scheduledAt = <DateTime>[];
  final reminderBodies = <String>[];
  DateTime? failAt;
  Future<void> Function()? onCriticalSchedule;

  void seedPending(int id, String body) {
    pending[id] = _Scheduled(DateTime(2099), body: body);
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
    pending.remove(id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingRequestsForCleanup() async {
    return pending.entries
        .map((entry) => PendingNotificationRequest(
              entry.key,
              entry.value.title,
              entry.value.body,
              entry.value.payload,
            ))
        .toList();
  }

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    await onCriticalSchedule?.call();
    if (failAt == notifyAt) {
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.error,
        notifyAt: notifyAt,
      );
    }
    scheduledAt.add(notifyAt);
    pending[id] = _Scheduled(notifyAt, title: title, payload: payload);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async {
    reminderBodies.add(body);
    pending[id] = _Scheduled(notifyAt, title: title, body: body);
  }
}

class _RecordingPreflightScheduler {
  bool accept = true;
  final requests = <CriticalPreflightRequest>[];
  final cancelledAlarmIds = <int>[];
  Future<void> Function(CriticalPreflightRequest request)? onSchedule;

  Future<bool> call(CriticalPreflightRequest request) async {
    if (!accept) {
      return false;
    }
    requests.add(request);
    await onSchedule?.call(request);
    return true;
  }

  Future<bool> cancel(int alarmId) async {
    cancelledAlarmIds.add(alarmId);
    return true;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(List<EventModel> events) : events = List.of(events);

  final List<EventModel> events;
  Object? error;
  int? failAfterCalls;
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    calls += 1;
    final limit = failAfterCalls;
    if (error != null || (limit != null && calls > limit)) {
      throw error ?? StateError('fetch failed');
    }
    for (final event in events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      List<EventModel>.of(events);
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository(this.value);

  UserSettingsModel? value;
  Object? error;
  bool hang = false;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    if (hang) {
      return Completer<UserSettingsModel?>().future;
    }
    if (error != null) {
      throw error!;
    }
    return value;
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel value) async =>
      value;
}

class _TravelCall {
  _TravelCall(this.origin, this.mode);

  final GeoPoint origin;
  final MapTravelMode mode;
}

class _FakeTravelService extends TravelTimeBufferService {
  _FakeTravelService(this.routeEstimate);

  TravelTimeBufferEstimate routeEstimate;
  Future<TravelTimeBufferEstimate> Function()? onRoute;
  Object? error;
  bool hang = false;
  final calls = <_TravelCall>[];

  @override
  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
    bool skipRemote = false,
  }) async {
    expect(skipRemote, isFalse);
    calls.add(
      _TravelCall(GeoPoint(latitude: originLat, longitude: originLng), mode),
    );
    if (hang) {
      return Completer<TravelTimeBufferEstimate>().future;
    }
    if (error != null) {
      throw error!;
    }
    return onRoute != null ? await onRoute!() : routeEstimate;
  }
}

class _MutableAckStore extends CriticalAlarmAcknowledgementStore {
  final Map<String, DateTime> _acks = <String, DateTime>{};

  @override
  Future<bool> isAcknowledged(String eventId, DateTime startAt) async =>
      _acks[eventId]?.toUtc() == startAt.toUtc();

  @override
  Future<bool> hasUnknownStartAcknowledgement(String eventId) async => false;

  @override
  Future<bool> hasAcknowledgement(String eventId) async =>
      _acks.containsKey(eventId);

  @override
  Future<void> markAcknowledged(String eventId, DateTime startAt) async {
    _acks[eventId] = startAt;
  }

  @override
  Future<void> clearAcknowledgement(String eventId) async {
    _acks.remove(eventId);
  }
}

class _ScriptedPermissionService extends AppPermissionService {
  _ScriptedPermissionService({required this.fresh, required this.lastKnown});

  final GeoPoint? fresh;
  final GeoPoint? lastKnown;
  bool backgroundCapability = true;
  bool capabilityHangs = false;
  Object? capabilityError;
  int capabilityCalls = 0;
  int freshCalls = 0;
  final backgroundPermissionRequirements = <bool>[];
  int checkPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int lastKnownCalls = 0;
  int legacyCurrentCalls = 0;

  @override
  Future<bool> canUseBackgroundFreshLocation() async {
    capabilityCalls++;
    if (capabilityHangs) return Completer<bool>().future;
    if (capabilityError != null) throw capabilityError!;
    return backgroundCapability;
  }

  @override
  Future<bool> checkLocationPermission() async {
    checkPermissionCalls += 1;
    throw StateError('Activity channel unavailable in headless engine');
  }

  @override
  Future<bool> requestLocationPermission() async {
    requestPermissionCalls += 1;
    return false;
  }

  @override
  Future<GeoPoint?> getLastKnownLocation() async {
    lastKnownCalls += 1;
    return lastKnown;
  }

  @override
  Future<GeoPoint?> getCurrentLocation() async {
    legacyCurrentCalls += 1;
    return lastKnown;
  }

  @override
  Future<GeoPoint?> getFreshCurrentLocation({
    bool requireBackgroundPermission = false,
  }) async {
    freshCalls += 1;
    backgroundPermissionRequirements.add(requireBackgroundPermission);
    return fresh;
  }
}

class _NoopGateway extends ManualEventSideEffectGateway {
  @override
  Future<void> deleteRemindersForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> deletePreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> deleteExternalPreparationPreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}
}
