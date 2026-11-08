import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/region_settings.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_bubble_visibility.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/ad_reward_state.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';

/// planflow/critical_alarm_ownership 채널(소유권 RPC) fixture.
///
/// ConfirmScreen 위젯 테스트는 논리적으로 Android로 실행되므로
/// CriticalAlarmPreflightService의 정적 소유권 호출이 실제 채널을 향한다.
/// 목업이 없으면 호출이 완료되지 않아 3초 RPC 타임아웃이 남는다.
/// 계약에 없는 메서드는 조용히 참을 돌려주지 않고 실패한다(fail loud).
class _CriticalAlarmOwnershipChannelStub {
  static const MethodChannel channel =
      MethodChannel('planflow/critical_alarm_ownership');

  static final Map<String, Map<String, Object?>> _owners =
      <String, Map<String, Object?>>{};

  static void install() {
    _owners.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    _owners.clear();
  }

  static Future<Object?> _handle(MethodCall call) async {
    final Object? arguments = call.arguments;
    final Map<Object?, Object?> args =
        arguments is Map ? arguments : const <Object?, Object?>{};
    switch (call.method) {
      case 'readOwner':
        return _owners[args['eventId'] as String?];
      case 'invalidateOwner':
        return _owners.remove(args['eventId'] as String?);
      case 'listOwners':
        return Map<String, Object?>.of(_owners);
      case 'updateOwner':
        final previous = _owners[args['eventId'] as String?];
        _storeOwner(args);
        return previous;
      case 'releaseIfOwner':
        return _takeIfOwner(
              args,
              generation: args['generation'],
              trigger: args['expectedTrigger'],
            ) !=
            null;
      case 'claimTrigger':
        final owner = _owners[args['eventId'] as String?];
        return owner == null ||
            _matchesGenerationAndTrigger(
              owner,
              generation: args['generation'],
              trigger: args['triggerAt'],
            );
      case 'replaceOwnerIfMatches':
        if (!_matchesGenerationAndTrigger(
          _owners[args['eventId'] as String?],
          generation: args['expectedGeneration'],
          trigger: args['expectedTrigger'],
        )) {
          return false;
        }
        _storeOwner(args);
        return true;
      case 'updateTriggerIfOwner':
        final owner = _owners[args['eventId'] as String?];
        if (!_matchesGenerationAndTrigger(
          owner,
          generation: args['expectedGeneration'],
          trigger: args['expectedTrigger'],
        )) {
          return false;
        }
        _storeOwner(args);
        return true;
      default:
        throw PlatformException(
          code: 'unhandled-method',
          message: 'critical_alarm_ownership.${call.method} is not mocked',
        );
    }
  }

  static void _storeOwner(Map<Object?, Object?> args) {
    if (args['eventId'] is! String ||
        args['generation'] is! String ||
        args['triggerAt'] is! int ||
        args['metadataJson'] is! String) {
      throw PlatformException(
        code: 'invalid-owner-state',
        message: 'owner state contract violated',
      );
    }
    _owners[args['eventId'] as String] = <String, Object?>{
      for (final entry in args.entries) entry.key as String: entry.value,
    };
  }

  static Object? _takeIfOwner(
    Map<Object?, Object?> args, {
    required Object? generation,
    required Object? trigger,
  }) {
    final Object? eventId = args['eventId'];
    if (eventId is! String) {
      return null;
    }
    if (!_matchesGenerationAndTrigger(
      args,
      generation: generation,
      trigger: trigger,
    )) {
      return null;
    }
    return _owners.remove(eventId);
  }

  static bool _matchesGenerationAndTrigger(
    Map<Object?, Object?>? owner, {
    required Object? generation,
    required Object? trigger,
  }) {
    return owner != null &&
        generation is String &&
        trigger is int &&
        owner['generation'] == generation &&
        owner['triggerAt'] == trigger;
  }
}

void _installEnvironment() {
  PlanFlowRegionController.instance.reset();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  _CriticalAlarmOwnershipChannelStub.install();
  guideSaveStageActive.value = false;
  guideSaveStage.value = GuideSaveStage.important;
  guideConfirmReady.value = false;
  guideConfirmUserScrolled.value = false;
}

Future<void> _tearDownEnvironment() async {
  _CriticalAlarmOwnershipChannelStub.uninstall();
  SupabaseClientAccess.clearOverride();
  await AdRewardState.instance.clear(feature: 'schedule_parse');
  await AdRewardState.instance.clearPendingConsume(
    feature: 'schedule_parse',
  );
  SharedPreferencesAsyncPlatform.instance = null;
  ScheduleParseAdGate.instance.delegateForTest = null;
  ScheduleParseEntitlementService.instance.delegateForTest = null;
}

/// 앱 전역 "지금"을 고정해 미래/과거 판정을 흔들림 없이 만든다.
/// [now]은 KST 벽시계 기준 시각으로 취급된다(planflowLocalDateTimeToUtc와 동일).
final DateTime _fixedNow = DateTime(2030, 5, 10, 9);

DateTime _fixedNowProvider() => _fixedNow;

Widget _testApp(Widget child) {
  final router = GoRouter(
    initialLocation: AppRoutes.confirm,
    routes: [
      GoRoute(path: AppRoutes.confirm, builder: (_, __) => child),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, __) => const Scaffold(body: Text('홈')),
      ),
      GoRoute(
        path: AppRoutes.calendar,
        builder: (_, __) => const Scaffold(body: Text('일정')),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, __) => const Scaffold(body: Text('설정')),
      ),
    ],
  );

  return MaterialApp.router(
    scaffoldMessengerKey: AppFeedbackService.scaffoldMessengerKey,
    routerConfig: router,
  );
}

/// 미래 1회성 개인 일정 + 해석된 목적지 좌표가 포함된 파싱 결과.
Map<String, dynamic> _parsedSchedule({
  DateTime? startAt,
  String? location = '성남역',
  double? latitude = 37.4449,
  double? longitude = 127.1551,
  String? recurrenceRule,
}) {
  final start = startAt ?? _fixedNow.add(const Duration(days: 1));
  return <String, dynamic>{
    'title': '성남 출발',
    'start_at': start.toIso8601String(),
    'end_at': null,
    'location': location,
    'location_lat': latitude,
    'location_lng': longitude,
    'memo': '테스트 일정',
    'supplies': <String>[],
    'is_critical': false,
    'recurrence_rule': recurrenceRule,
    'pre_actions': <Map<String, dynamic>>[],
    'raw_text': '내일 오전 10시에 ${location ?? '장소'}으로 출발',
  };
}

/// 저장 파이프라인에서 실제로 호출된 순서를 기록한다.
class _CallLog {
  final List<String> entries = <String>[];

  void add(String entry) => entries.add(entry);

  int indexOf(String entry) => entries.indexOf(entry);
}

class _FakeConfirmBackend extends ConfirmScreenBackend {
  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async =>
      const <String>[];

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.log);

  final _CallLog log;
  final createdEvents = <EventModel>[];

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async =>
      const <EventModel>[];

  @override
  Future<EventModel> createEvent(EventModel event) async {
    log.add('create');
    final saved = EventModel(
      id: 'event-${createdEvents.length + 1}',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      isCritical: event.isCritical,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      category: event.category,
    );
    createdEvents.add(saved);
    return saved;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      createdEvents.where((event) => event.id == eventId).firstOrNull;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => createdEvents;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;

  @override
  Future<List<GroupModel>> listGroups() async => groups;

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async =>
      membersByGroupId[groupId] ?? const <GroupMemberModel>[];

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }
}

class _FakeGroupEventRepository extends GroupEventRepository {
  final createdEvents = <GroupEventModel>[];

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async =>
      const <GroupEventModel>[];

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    final saved = event.copyWith(
      id: 'group-event-${createdEvents.length + 1}',
    );
    createdEvents.add(saved);
    return saved;
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async => event;

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
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
    List<HomeWidgetMonthDayData> monthDays =
        const <HomeWidgetMonthDayData>[],
    List<HomeWidgetMonthCellData> monthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> previousMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetMonthCellData> nextMonthCells =
        const <HomeWidgetMonthCellData>[],
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> previousWeekDays =
        const <HomeWidgetWeekDayData>[],
    List<HomeWidgetWeekDayData> nextWeekDays = const <HomeWidgetWeekDayData>[],
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
  }) async =>
      const <LocationLookupResult>[];
}

/// 저장 시점에 호출되는 권한 서비스 가짜.
/// 호출 순서·횟수·예외를 주입해서 "권한 프롬프트가 저장보다 앞에 나가는지"
/// 를 실제 저장 파이프라인에서 관찰한다.
class _RecordingPermissionService extends AppPermissionService {
  _RecordingPermissionService({
    this.granted = false,
    this.requestResult = false,
    this.checkError,
    this.requestError,
    this.checkGate,
    this.log,
  });

  final bool granted;
  final bool requestResult;
  final Object? checkError;
  final Object? requestError;
  final Future<void>? checkGate;
  final _CallLog? log;

  int checkCalls = 0;
  int requestCalls = 0;
  final List<bool> backgroundRequestFlags = <bool>[];

  @override
  Future<AppPermissionSnapshot> checkAll() async =>
      const AppPermissionSnapshot(
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
  Future<bool> checkLocationPermission() async {
    checkCalls += 1;
    log?.add('check');
    final gate = checkGate;
    if (gate != null) {
      await gate;
    }
    final error = checkError;
    if (error != null) {
      throw error;
    }
    return granted;
  }

  @override
  Future<bool> requestLocationPermission() async {
    requestCalls += 1;
    log?.add('request');
    final error = requestError;
    if (error != null) {
      throw error;
    }
    return requestResult;
  }

  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async {
    backgroundRequestFlags.add(requestIfMissing);
    return null;
  }
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.text('일정 저장'));
  await tester.tap(find.text('일정 저장'));
}

Future<void> _settleSave(
  WidgetTester tester,
  _FakeEventRepository repository, {
  int maxPumps = 60,
}) async {
  for (var i = 0; i < maxPumps && repository.createdEvents.isEmpty; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(_installEnvironment);
  tearDown(_tearDownEnvironment);

  testWidgets(
      'foreground location is requested before the save and the save still lands',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: false, log: log);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    // 프롬프트는 저장이 아니라 "저장 직전"에 한 번만 발생한다.
    expect(permissions.checkCalls, 1);
    expect(permissions.requestCalls, 1);
    expect(repository.createdEvents, hasLength(1));

    // 실제 호출 순서: 권한 확인 → 시스템 프롬프트 → 저장.
    expect(log.indexOf('check'), greaterThanOrEqualTo(0));
    expect(log.indexOf('request'), greaterThan(log.indexOf('check')));
    expect(log.indexOf('create'), greaterThan(log.indexOf('request')));

    // 목적지 좌표는 그대로 보존된다(현재 위치/출발지 대체 없음).
    final saved = repository.createdEvents.single;
    expect(saved.locationLat, closeTo(37.4449, 0.0001));
    expect(saved.locationLng, closeTo(127.1551, 0.0001));
    expect(saved.location, '성남역');
  });

  testWidgets(
      'already granted location does not trigger an extra system prompt',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: true);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.checkCalls, 1);
    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('denied location permission still saves the schedule',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(
      granted: false,
      requestResult: false,
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.requestCalls, 1);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('a throwing permission check still saves the schedule',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(
      granted: false,
      checkError: StateError('permission channel unavailable'),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.checkCalls, 1);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('a throwing permission request still saves the schedule',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(
      granted: false,
      requestError: PlatformException(code: 'permission_failed'),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.requestCalls, 1);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('a user switch during the permission await does not save',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final gate = Completer<void>();
    final permissions = _RecordingPermissionService(
      granted: false,
      checkGate: gate.future,
    );

    Widget buildScreen(String userId) => _testApp(
          ConfirmScreen(
            userId: userId,
            parsedSchedule: _parsedSchedule(),
            backend: _FakeConfirmBackend(),
            eventRepository: repository,
            notificationService: _FakeNotificationService(),
            homeWidgetService: _FakeHomeWidgetService(),
            locationLookupService: _EmptyLocationLookupService(),
            permissionService: permissions,
            nowProvider: _fixedNowProvider,
          ),
        );

    await tester.pumpWidget(buildScreen('user-1'));
    await tester.pump();

    await _tapSave(tester);
    await tester.pump();
    await tester.pump();

    // 권한 확인이 끝나기 전에 사용자가 바뀐다(세션 교체).
    await tester.pumpWidget(buildScreen('user-2'));
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(permissions.checkCalls, 1);
    // uid 검사에서 중단되었으므로 시스템 프롬프트 자체도 뜨지 않는다.
    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, isEmpty);
  });

  testWidgets('a past personal event does not ask for location permission',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: false);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            startAt: _fixedNow.subtract(const Duration(hours: 2)),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.checkCalls, 0);
    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('a recurring event does not ask for location permission',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: false);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets(
      'an event without destination coordinates does not ask for location '
      'permission', (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: false);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(latitude: null, longitude: null),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('a group-only save does not ask for location permission',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final groupEventRepository = _FakeGroupEventRepository();
    final permissions = _RecordingPermissionService(granted: false);
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2030, 5, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          groupContextProvider: contextProvider,
          groupEventRepository: groupEventRepository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('우리 팀만'));
    await tester.pump(const Duration(milliseconds: 200));

    await _tapSave(tester);
    for (var i = 0; i < 60 && groupEventRepository.createdEvents.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(permissions.requestCalls, 0);
    expect(repository.createdEvents, isEmpty);
    expect(groupEventRepository.createdEvents, hasLength(1));
  });

  testWidgets(
      'a personal + group save still asks for location permission once',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final groupEventRepository = _FakeGroupEventRepository();
    final permissions = _RecordingPermissionService(granted: false);
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2030, 5, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          groupContextProvider: contextProvider,
          groupEventRepository: groupEventRepository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('개인 + 우리 팀'));
    await tester.pump(const Duration(milliseconds: 200));

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(permissions.requestCalls, 1);
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets(
      'background location lookups never request a missing permission',
      (tester) async {
    final log = _CallLog();
    final repository = _FakeEventRepository(log);
    final permissions = _RecordingPermissionService(granted: false);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissions,
          nowProvider: _fixedNowProvider,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await _tapSave(tester);
    await _settleSave(tester, repository);

    expect(
      permissions.backgroundRequestFlags.where((flag) => flag).isEmpty,
      isTrue,
      reason: '백그라운드 GPS 조회는 requestIfMissing:false로만 호출되어야 한다',
    );
  });

  group('QA 지도 조회 생략 가드', () {
    test('only the full isolated debug QA flag set can skip the map lookup',
        () {
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: true,
          guideQa: true,
          isolatedQa: true,
          skipMap: true,
        ),
        isTrue,
      );
    });

    test('a single missing condition keeps the map lookup enabled', () {
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: false,
          guideQa: true,
          isolatedQa: true,
          skipMap: true,
        ),
        isFalse,
      );
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: true,
          guideQa: false,
          isolatedQa: true,
          skipMap: true,
        ),
        isFalse,
      );
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: true,
          guideQa: true,
          isolatedQa: false,
          skipMap: true,
        ),
        isFalse,
      );
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: true,
          guideQa: true,
          isolatedQa: true,
          skipMap: false,
        ),
        isFalse,
      );
    });

    test('an ordinary build cannot bypass the map lookup', () {
      expect(
        ConfirmScreen.canSkipGuideMapLookup(
          debug: kDebugMode,
          guideQa: const bool.fromEnvironment('PLANFLOW_GUIDE_QA'),
          isolatedQa:
              const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA'),
          skipMap: const bool.fromEnvironment('PLANFLOW_GUIDE_QA_SKIP_MAP'),
        ),
        isFalse,
        reason: '일반 테스트/릴리스 빌드에서는 지도 조회 생략이 불가능해야 한다',
      );
    });
  });
}
