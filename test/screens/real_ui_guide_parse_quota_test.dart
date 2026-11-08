// Real-UI guide × schedule-parse quota behavior on the ACTUAL ConfirmScreen.
//
// Pins (see parent task brief):
// 1. Every guided parse attempt (initial AND retry/reparse) needs a FRESH
//    server-backed permit with a unique operationId; denial (wrong uid /
//    expired / phase mismatch / replay) stops the attempt with NO normal
//    fallback and NO AI call.
// 2. The charge lane is captured PER REQUEST at dispatch: a valid guided
//    request that completes after the guide skipped/ended must NOT consume
//    the normal free quota at completion.
// 3. Outside the guide the normal path is unchanged: one grant, consume once.
// 4. After the guide has ended, a NEW parse request goes through the normal
//    gate and consumes the normal quota exactly once.
//
// No real RPC, Supabase, ads, or STT are involved: the guide coordinator is a
// stub bound via GuideQuotaRuntime + GuideScope, auth UID is injected through
// SupabaseClientAccess.overrideForRun, and ordinary quota goes through the
// existing gate/entitlement test delegates.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/region_settings.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/ad_reward_state.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const String _uid = '11111111-1111-4111-8111-111111111111';
const String _otherUid = '99999999-9999-4999-8999-999999999999';
const String _sessionId = '22222222-2222-4222-8222-222222222222';

const String _guideDenialMessage =
    '안내 사용 승인을 확인하지 못했어요. 일반 무료 사용으로 전환하지 않았어요.';
const String _retryButtonKey = 'retry-ai-parse';

Map<String, dynamic> _parsedSchedule() {
  return {
    'title': '원본 제목',
    'start_at':
        DateTime.now().add(const Duration(hours: 3)).toIso8601String(),
    'end_at': null,
    'location': '성남',
    'memo': '테스트 일정',
    'supplies': const <String>[],
    'is_critical': false,
    'recurrence_rule': null,
    'pre_actions': <Map<String, dynamic>>[],
    'raw_text': '내일 오전 10시에 성남으로 출발',
  };
}

Map<String, dynamic> _successParse([String title = '안내 파싱 제목']) => {
      'title': title,
      'location': '판교역',
      'memo': null,
      'start_at': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
      'end_at': null,
      'supplies': <String>[],
      'is_critical': false,
      'pre_actions': <Map<String, dynamic>>[],
      'parse_failed': false,
    };

/// ConfirmScreen 위젯 테스트가 Android 타깃으로 실행되므로 critical-alarm 소유권
/// 채널 호출을 즉시 응답시켜 남는 타이머를 막는다(confirm_screen_test와 동일).
class _CriticalAlarmOwnershipChannelStub {
  static const MethodChannel channel =
      MethodChannel('planflow/critical_alarm_ownership');

  static void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'readOwner':
        case 'invalidateOwner':
          return null;
        case 'listOwners':
          return <String, Object?>{};
        default:
          throw PlatformException(
            code: 'unhandled-method',
            message: 'critical_alarm_ownership.${call.method} is not mocked',
          );
      }
    });
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

class _GuideStubCoordinator implements GuideCoordinator {
  _GuideStubCoordinator(GuideSnapshot initial)
      : _state = ValueNotifier<GuideSnapshot>(initial);

  final ValueNotifier<GuideSnapshot> _state;

  /// authorize()가 받은 operationId들 — 시도마다 새로운(고유한) 값이어야 한다.
  final List<String> authorizeCalls = <String>[];

  /// null이면 granted permit을 operationId 에코로 반환한다.
  GuideAccess Function(String operationId)? onAuthorize;

  static GuideSnapshot activeCreate({
    String uid = _uid,
    String sessionId = _sessionId,
    GuideStep step = GuideStep.correctAndSave,
    int revision = 1,
    int serverRevision = 1,
  }) =>
      GuideSnapshot(
        uid: uid,
        version: 'real_ui_v1',
        revision: revision,
        serverRevision: serverRevision,
        step: step,
        run: GuideRun.active,
        sessionId: sessionId,
      );

  /// 사용자가 안내를 skip해 종료된 상태(세션 무효화 포함).
  void becomeTerminal() {
    _state.value = _state.value.copyWith(
      run: GuideRun.terminal,
      step: GuideStep.skipped,
      clearSessionId: true,
    );
  }

  @override
  ValueListenable<GuideSnapshot> get state => _state;

  @override
  Future<GuideSnapshot> start({required String uid}) async => _state.value;

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => _state.value;

  @override
  void suspend(GuidePauseReason reason) {}

  @override
  Future<void> terminate(GuideExit exit) async => becomeTerminal();

  @override
  Future<GuideAccess> authorize({
    required GuideChargeContext context,
    required String operationId,
  }) async {
    authorizeCalls.add(operationId);
    final stub = onAuthorize;
    if (stub != null) {
      return stub(operationId);
    }
    return GuideAccess(
      status: GuideAccessStatus.granted,
      permit: GuidePermit(
        grantId: 'grant-${authorizeCalls.length}',
        uid: context.uid,
        sessionId: context.sessionId,
        operationId: operationId,
        kind: context.kind,
        operation: context.operation,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      ),
    );
  }
}

class _ScriptedGptService extends GptService {
  _ScriptedGptService(this._results);

  final List<Map<String, dynamic>> _results;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    calls += 1;
    return _results[calls - 1];
  }
}

class _DeferredGptService extends GptService {
  _DeferredGptService(this._completer);

  final Completer<Map<String, dynamic>> _completer;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    calls += 1;
    return _completer.future;
  }
}

/// 일반 무료/광고 게이트 위임: 호출마다 새 dailyFree grant.
class _DailyFreeAdGateDelegate implements ScheduleParseAdGateDelegate {
  int calls = 0;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  }) async {
    calls += 1;
    onEnterAllowed(
      ScheduleParseEntryGrant(
        sessionId: ScheduleParseSessionIdGenerator.next(),
        source: ScheduleParseEntitlementSource.dailyFree,
        dailyRemainingAtGate: 1,
      ),
    );
  }
}

/// 일반 quota consume 호출 횟수를 세는 fake(peek는 소진 상태로 고정).
class _CountingEntitlementDelegate implements ScheduleParseEntitlementDelegate {
  final List<String> consumedSessionIds = <String>[];

  @override
  Future<ScheduleParseEntitlementPeek?> peek() async =>
      const ScheduleParseEntitlementPeek(dailyRemaining: 0, requiresAd: true);

  @override
  Future<ScheduleParseConsumeResult?> consume(String sessionId) async {
    consumedSessionIds.add(sessionId);
    return const ScheduleParseConsumeResult(
      source: 'daily_free',
      dailyRemaining: 0,
    );
  }
}

class _FakeConfirmBackend extends ConfirmScreenBackend {
  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async =>
      const <String>[];

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _FakeEventRepository extends EventRepository {
  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async =>
      const <EventModel>[];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      const <EventModel>[];

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeNotificationService extends NotificationService {
  @override
  int notificationIdFor(String id) => id.hashCode & 0x7fffffff;

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async {}

  @override
  Future<NotificationScheduleResult> scheduleEventReminderWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async =>
      NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
      );

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {}

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async =>
      NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
        notifyAt: notifyAt,
      );
}

class _FakeHomeWidgetService extends HomeWidgetService {
  @override
  Future<bool> updateScheduleData({
    required HomeWidgetNextEventData nextEvent,
    List<Map<String, Object?>> rawEvents = const <Map<String, Object?>>[],
    List<HomeWidgetListEventData> todayEvents =
        const <HomeWidgetListEventData>[],
    HomeWidgetListEventData? lastPastEvent,
    List<HomeWidgetListEventData> todayUpcomingEvents =
        const <HomeWidgetListEventData>[],
    List<HomeWidgetListEventData> tomorrowEvents =
        const <HomeWidgetListEventData>[],
    List<HomeWidgetListEventData> yesterdayEvents =
        const <HomeWidgetListEventData>[],
    DateTime? month,
    List<HomeWidgetMonthDayData> monthDays = const <HomeWidgetMonthDayData>[],
    List<HomeWidgetMonthCellData> monthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> previousMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> nextMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> previousWeekDays =
        const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> nextWeekDays =
        const <HomeWidgetWeekDayData>[],
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async =>
      true;

  @override
  Future<bool> updateNextEvent({
    required String title,
    String? eventId,
    DateTime? startAt,
    String? location,
    String? travelOrigin,
    double? latitude,
    double? longitude,
    int? travelBufferMinutes,
    bool isCritical = false,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async =>
      true;
}

class _EmptyLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return const <LocationLookupResult>[];
  }
}

Widget _guidedTestApp({
  required Widget child,
  _GuideStubCoordinator? coordinator,
}) {
  final router = GoRouter(
    initialLocation: AppRoutes.confirm,
    routes: [
      GoRoute(
        path: AppRoutes.confirm,
        builder: (_, __) => coordinator == null
            ? child
            : GuideScope(coordinator: coordinator, child: child),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, __) => const Scaffold(body: Text('홈')),
      ),
    ],
  );
  return MaterialApp.router(
    scaffoldMessengerKey: AppFeedbackService.scaffoldMessengerKey,
    routerConfig: router,
  );
}

Future<ConfirmScreen> _pumpConfirm(
  WidgetTester tester, {
  required GptService gptService,
  _GuideStubCoordinator? coordinator,
}) async {
  final screen = ConfirmScreen(
    userId: _uid,
    parsedSchedule: _parsedSchedule()
      ..['parse_pending'] = true
      ..['manual_text_confirmed'] = true,
    gptService: gptService,
    backend: _FakeConfirmBackend(),
    eventRepository: _FakeEventRepository(),
    notificationService: _FakeNotificationService(),
    homeWidgetService: _FakeHomeWidgetService(),
    locationLookupService: _EmptyLocationLookupService(),
  );
  await tester.pumpWidget(
    _guidedTestApp(child: screen, coordinator: coordinator),
  );
  return screen;
}

Future<void> _settleParse(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _titleField() => find.ancestor(
      of: find.text('제목'),
      matching: find.byType(TextFormField),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PlanFlowRegionController.instance.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    _CriticalAlarmOwnershipChannelStub.install();
    SupabaseClientAccess.overrideForRun(() => _uid);
  });

  tearDown(() async {
    _CriticalAlarmOwnershipChannelStub.uninstall();
    await AdRewardState.instance.clear(feature: 'schedule_parse');
    await AdRewardState.instance.clearPendingConsume(
      feature: 'schedule_parse',
    );
    SharedPreferencesAsyncPlatform.instance = null;
    ScheduleParseAdGate.instance.delegateForTest = null;
    ScheduleParseEntitlementService.instance.delegateForTest = null;
    GuideQuotaRuntime.reset();
    SupabaseClientAccess.clearOverride();
  });

  testWidgets(
      'guided initial parse: exactly one fresh server permit, zero normal '
      'consume', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final gpt = _ScriptedGptService([_successParse()]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);

    // 정확히 한 번의 authorize, 고유 operationId, 서버 backstamped permit 경로.
    expect(coord.authorizeCalls.length, 1);
    expect(
      coord.authorizeCalls.single,
      contains('schedule_parse:$_uid:createParse:'),
    );
    expect(gpt.calls, 1);
    // 가이드 레인 요청은 성공해도 일반 무료 사용량을 소비하지 않는다.
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(
      tester.widget<TextFormField>(_titleField()).controller?.text,
      '안내 파싱 제목',
    );
  });

  testWidgets(
      'guided retry after a failed parse requests a NEW permit with a '
      'different operationId and still consumes zero normal quota',
      (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final gpt = _ScriptedGptService([
      {'parse_failed': true},
      _successParse('재시도 파싱 제목'),
    ]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);
    expect(gpt.calls, 1);
    expect(find.byKey(const ValueKey(_retryButtonKey)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey(_retryButtonKey)));
    await _settleParse(tester);

    // 재시도도 캐시된 permit을 재사용하지 않고 새 서버 승인을 받는다.
    expect(coord.authorizeCalls.length, 2);
    expect(coord.authorizeCalls[0], isNot(coord.authorizeCalls[1]));
    expect(gpt.calls, 2);
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(
      tester.widget<TextFormField>(_titleField()).controller?.text,
      '재시도 파싱 제목',
    );
  });

  testWidgets(
      'wrong auth uid: guide denial is fail-closed — no authorize, no AI, '
      'no normal consume', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    SupabaseClientAccess.overrideForRun(() => _otherUid);
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final gpt = _ScriptedGptService([_successParse()]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);

    expect(gpt.calls, 0, reason: '거절된 가이드 요청은 AI를 호출하지 않는다');
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(coord.authorizeCalls, isEmpty);
    expect(find.text(_guideDenialMessage), findsOneWidget);
  });

  testWidgets(
      'expired server grant: fail-closed — no AI call and no normal consume',
      (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    coord.onAuthorize = (_) =>
        const GuideAccess(status: GuideAccessStatus.expired);
    final gpt = _ScriptedGptService([_successParse()]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);

    expect(coord.authorizeCalls.length, 1);
    expect(gpt.calls, 0);
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(find.text(_guideDenialMessage), findsOneWidget);
  });

  testWidgets(
      'guide bound at a non-create step: phase mismatch is fail-closed — '
      'no authorize RPC, no AI, no consume', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(
      _GuideStubCoordinator.activeCreate(step: GuideStep.queryResults),
    );
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final gpt = _ScriptedGptService([_successParse()]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);

    // createParse는 createSpeech/correctAndSave 정준 단계에서만 유효하다.
    expect(coord.authorizeCalls, isEmpty);
    expect(gpt.calls, 0);
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(find.text(_guideDenialMessage), findsOneWidget);
  });

  testWidgets(
      'replayed operationId denied by the server: fail-closed — no AI, no '
      'normal consume', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    coord.onAuthorize = (_) => const GuideAccess(
          status: GuideAccessStatus.denied,
          reasonCode: 'replayed_operation',
        );
    final gpt = _ScriptedGptService([_successParse()]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);

    expect(coord.authorizeCalls.length, 1);
    expect(gpt.calls, 0);
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(find.text(_guideDenialMessage), findsOneWidget);
  });

  testWidgets(
      'guide skip while a guided parse is in flight: completion keeps the '
      'dispatch lane and never consumes normal quota', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final completer = Completer<Map<String, dynamic>>();
    final gpt = _DeferredGptService(completer);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);
    expect(gpt.calls, 1);
    expect(coord.authorizeCalls.length, 1);

    // 응답을 기다리는 동안 사용자가 안내를 skip했다.
    coord.becomeTerminal();
    await tester.pump(const Duration(milliseconds: 50));

    completer.complete(_successParse('늦게 끝난 파싱'));
    await _settleParse(tester);

    // dispatch 시점에 가이드 레인이었던 요청은 완료 시 일반 소비로 전환되지
    // 않는다(스킵/종료가 과거 요청을 소급 청구하지 않는다).
    expect(entitlement.consumedSessionIds, isEmpty);
    expect(
      tester.widget<TextFormField>(_titleField()).controller?.text,
      '늦게 끝난 파싱',
    );
  });

  testWidgets(
      'retry after the guide has ended: fresh normal gate grant and normal '
      'consume exactly once', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final adGate = _DailyFreeAdGateDelegate();
    ScheduleParseAdGate.instance.delegateForTest = adGate;
    final coord = _GuideStubCoordinator(_GuideStubCoordinator.activeCreate());
    GuideQuotaRuntime.bind(coord, uid: _uid);
    final gpt = _ScriptedGptService([
      {'parse_failed': true},
      _successParse('가이드 종료 후 재시도'),
    ]);

    await _pumpConfirm(tester, gptService: gpt, coordinator: coord);
    await _settleParse(tester);
    expect(gpt.calls, 1);
    expect(adGate.calls, 0, reason: '가이드 동안에는 일반 게이트를 거치지 않는다');

    // 가이드 종료 → 이후의 새 요청은 일반 레인이다.
    coord.becomeTerminal();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey(_retryButtonKey)));
    await _settleParse(tester);

    expect(adGate.calls, 1, reason: '가이드 종료 후 새 요청은 일반 게이트에서 새 승인을 받는다');
    expect(gpt.calls, 2);
    expect(entitlement.consumedSessionIds, hasLength(1));
    expect(
      tester.widget<TextFormField>(_titleField()).controller?.text,
      '가이드 종료 후 재시도',
    );
  });

  testWidgets(
      'no guide at all: ordinary path unchanged — one gate grant, one AI '
      'parse, normal consume exactly once', (tester) async {
    final entitlement = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest = entitlement;
    final adGate = _DailyFreeAdGateDelegate();
    ScheduleParseAdGate.instance.delegateForTest = adGate;
    final gpt = _ScriptedGptService([_successParse('일반 파싱 제목')]);

    await _pumpConfirm(tester, gptService: gpt);
    await _settleParse(tester);

    expect(adGate.calls, 1);
    expect(gpt.calls, 1);
    expect(entitlement.consumedSessionIds, hasLength(1));
    expect(
      tester.widget<TextFormField>(_titleField()).controller?.text,
      '일반 파싱 제목',
    );
  });
}
