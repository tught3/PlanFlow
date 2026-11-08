import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/local_time.dart';
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
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';
import 'guide_save_stage_actual_mount_test.dart' as save_stage_fixture;
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/guide_quota_adapter.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';
import 'package:planflow/services/ad_reward_state.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// planflow/critical_alarm_ownership 채널(소유권 8종 RPC)의 즉시 응답 fixture.
///
/// ConfirmScreen 위젯 테스트는 논리적으로 Android(defaultTargetPlatform ==
/// android)로 실행되므로 CriticalAlarmPreflightService의 정적 소유권 호출이
/// 실제 채널을 향한다. 목업이 없으면 호출이 완료되지 않아 3초 RPC 타임아웃
/// FakeTimer(readOwner/invalidateOwner)가 테스트 종료까지 남는다.
/// 인메모리 저장소로 마이크로태스크에서 즉시 응답하고, 기본 상태는 소유권
/// 부재(absence)다. 계약에 없는 메서드는 조용히 참을 돌려주지 않고
/// PlatformException으로 크게 실패한다(fail loud, silent truthy 금지).
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
        // 소유권 부재는 오래된 실행이 아니다: 클레임 성공(fail-safe 재계산).
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
          generation: args['generation'],
          trigger: args['expectedTrigger'],
        )) {
          return false;
        }
        if (args['nextTrigger'] is! int) {
          throw PlatformException(
            code: 'invalid-next-trigger',
            message: 'nextTrigger must be epoch millis int',
          );
        }
        owner!['triggerAt'] = args['nextTrigger'] as int;
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
        args['originalNotifyAt'] is! int ||
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

  static Map<String, Object?>? _takeIfOwner(
    Map<Object?, Object?> args, {
    required Object? generation,
    required Object? trigger,
  }) {
    final Object? eventId = args['eventId'];
    if (eventId is! String) {
      return null;
    }
    if (!_matchesGenerationAndTrigger(
      _owners[eventId],
      generation: generation,
      trigger: trigger,
    )) {
      return null;
    }
    return _owners.remove(eventId);
  }

  static bool _matchesGenerationAndTrigger(
    Map<String, Object?>? owner, {
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

void _installConfirmScreenTestEnvironment() {
  PlanFlowRegionController.instance.reset();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  _CriticalAlarmOwnershipChannelStub.install();
}

Future<void> _tearDownConfirmScreenTestEnvironment() async {
  // Global guide notifiers must not leak between tests (a leaked active flag
  // would auto-expand the editor and move later tests' layout).
  guideSaveStageActive.value = false;
  guideSaveStage.value = GuideSaveStage.important;
  guideConfirmReady.value = false;
  guideConfirmUserScrolled.value = false;
  GuideQuotaRuntime.reset();
  SupabaseClientAccess.clearOverride();
  _CriticalAlarmOwnershipChannelStub.uninstall();
  await AdRewardState.instance.clear(feature: 'schedule_parse');
  await AdRewardState.instance.clearPendingConsume(
    feature: 'schedule_parse',
  );
  SharedPreferencesAsyncPlatform.instance = null;
  ScheduleParseAdGate.instance.delegateForTest = null;
  ScheduleParseEntitlementService.instance.delegateForTest = null;
}

void main() {
  setUp(_installConfirmScreenTestEnvironment);
  tearDown(_tearDownConfirmScreenTestEnvironment);

  registerConfirmScreenGuideSaveStageTests();

  testWidgets(
      'ConfirmScreen schedules critical alarm when important is enabled',
      (tester) async {
    final backend = _FakeConfirmBackend();
    final notifications = _FakeNotificationService();
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            isCritical: true,
            startAt: DateTime.now().add(const Duration(hours: 2)),
          ),
          backend: backend,
          eventRepository: repository,
          notificationService: notifications,
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0;
        i < 30 &&
            (notifications.criticalAlarmTitles.isEmpty ||
                backend.reminderPayloads
                    .where((row) => row['type'] == 'system_alarm')
                    .isEmpty);
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(
      backend.reminderPayloads.where((row) => row['type'] == 'system_alarm'),
      hasLength(1),
    );
    expect(notifications.criticalAlarmTitles, contains('성남 출발'));
    expect(
      notifications.criticalAlarmNotifyAts.single.difference(
        repository.createdEvents.single.startAt!,
      ),
      const Duration(minutes: -60),
    );
  });

  testWidgets('ConfirmScreen surfaces local reminder scheduling failures',
      (tester) async {
    final repository = _FakeEventRepository();
    final notifyAt = DateTime.now().add(const Duration(hours: 2));
    final notifications = _FakeNotificationService(
      eventReminderResult: NotificationScheduleResult(
        status: NotificationScheduleStatus.permissionBlocked,
        notifyAt: notifyAt,
        message: '앱 알림 권한이 꺼져 있어 알림을 예약하지 못했습니다.',
      ),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(startAt: notifyAt),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: notifications,
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _AlarmReadyPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0;
        i < 40 &&
            find
                .text('일정은 저장했지만 알림 권한이 꺼져 있어 알람을 예약하지 못했어요.')
                .evaluate()
                .isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(notifications.eventReminderTitles, contains('성남 출발'));
    expect(
      find.text('일정은 저장했지만 알림 권한이 꺼져 있어 알람을 예약하지 못했어요.'),
      findsOneWidget,
    );
  });

  testWidgets('ConfirmScreen preserves parsed recurrence when saving',
      (tester) async {
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '태블릿 계기판 찍기',
            recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    expect(find.text('반복'), findsOneWidget);

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(repository.createdEvents, hasLength(1));
    expect(
      repository.createdEvents.single.recurrenceRule,
      'FREQ=WEEKLY;BYDAY=MO',
    );
  });

  testWidgets('ConfirmScreen save leaves voice stack for calendar tab',
      (tester) async {
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _voiceStackTestApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(title: '저장 후 이동 확인'),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    expect(find.text('음성 입력'), findsOneWidget);

    await tester.tap(find.text('확인 화면 열기'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pumpAndSettle();

    expect(repository.createdEvents, hasLength(1));
    expect(find.text('일정'), findsOneWidget);
    expect(find.text('음성 입력'), findsNothing);
  });

  testWidgets(
      'ConfirmScreen exact alarm action opens settings after one save without duplicating',
      (tester) async {
    final repository = _FakeEventRepository();
    final permissionService = _ExactAlarmMissingPermissionService();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(title: '정확한 알람 테스트'),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissionService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 생성'), findsOneWidget);
    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));

    for (var i = 0;
        i < 20 && find.text('정확한 알람 설정으로 이동').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(repository.createdEvents, isEmpty);
    expect(find.text('정확한 알람 설정으로 이동'), findsOneWidget);

    await tester.tap(find.text('정확한 알람 설정으로 이동'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(permissionService.openAlarmSettingsCalls, 1);
    expect(repository.createdEvents, isEmpty);
    expect(find.text('일정 생성'), findsOneWidget);

    permissionService.exactAlarmGranted = true;
    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 20 && repository.createdEvents.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets('ConfirmScreen shows login guidance when save session is missing',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: _ThrowingEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('로그인 상태를 다시 확인해 주세요.'), findsOneWidget);
  });

  testWidgets('ConfirmScreen warns before saving overlapping events',
      (tester) async {
    final repository = _FakeEventRepository();
    final existingStart = DateTime.now().add(const Duration(hours: 3));
    repository.createdEvents.add(
      EventModel(
        id: 'existing-1',
        userId: 'user-1',
        title: '겹치는 일정',
        startAt: existingStart,
        endAt: existingStart.add(const Duration(hours: 1)),
        location: '강남역',
      ),
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            startAt: existingStart,
            endAt: existingStart.add(const Duration(hours: 1)),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('일정이 겹쳐요'), findsOneWidget);
    expect(find.text('겹치는 일정'), findsOneWidget);
    expect(find.text('강남역'), findsOneWidget);
    expect(find.textContaining('아래 기존 일정'), findsOneWidget);
    expect(find.text('계속 저장'), findsOneWidget);

    await tester.tap(find.text('중단'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(repository.createdEvents, hasLength(1));
    expect(find.text('일정이 겹쳐요'), findsNothing);
  });

  testWidgets('ConfirmScreen opens location picker even when location is empty',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(location: ''),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.byTooltip('지도에서 위치 선택'));
    await tester.tap(find.byTooltip('지도에서 위치 선택'));
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('위치 권한이 필요해요').evaluate().isNotEmpty) {
      await tester.tap(find.text('계속 선택'));
      await tester.pump(const Duration(milliseconds: 500));
    }
    for (var i = 0;
        i < 20 && find.text('지도에서 장소 선택').evaluate().isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('지도에서 장소 선택'), findsOneWidget);
    expect(find.byKey(const ValueKey('location-search-field')), findsOneWidget);
    expect(find.text('검색'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('ConfirmScreen auto-resolves parsed voice location coordinates',
      (tester) async {
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '원주기독에서 김두섭 리바로 갖다주기',
            location: '원주기독',
            memo: null,
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _SingleLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    for (var i = 0; i < 20; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      final locationField = _textFieldWithLabel('장소');
      if (tester.widget<TextFormField>(locationField).controller?.text ==
          '원주세브란스기독병원') {
        break;
      }
    }

    final locationField = _textFieldWithLabel('장소');
    expect(
      tester.widget<TextFormField>(locationField).controller?.text,
      '원주세브란스기독병원',
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(saved.title, '김두섭 리바로 갖다주기');
    expect(saved.location, '원주세브란스기독병원');
    expect(saved.locationLat, 37.3495);
    expect(saved.locationLng, 127.9458);
  });

  testWidgets('ConfirmScreen keeps empty details section collapsed',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(memo: null),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('설명 · 준비물'));
    expect(find.widgetWithText(TextFormField, '설명'), findsNothing);
  });

  testWidgets('ConfirmScreen keeps details collapsed for memo-only parses',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            memo: 'AI가 만든 설명',
            supplies: const <String>[],
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('설명 · 준비물'));

    expect(find.widgetWithText(TextFormField, '설명'), findsNothing);
    expect(find.text('AI가 만든 설명'), findsNothing);
  });

  testWidgets('ConfirmScreen saves before background location resolution',
      (tester) async {
    final repository = _FakeEventRepository();
    final lookup = _DelayedSingleLocationLookupService();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '병원 방문',
            location: '원주세브란스',
            memo: null,
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: lookup,
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 50));

    // Save is intentionally not blocked on geocoding; coordinates are filled
    // by the post-save update path.
    expect(repository.createdEvents, hasLength(1));

    // Geocoding continues after save and updates the event asynchronously;
    // this test only verifies that saving is not blocked by that lookup.
    await tester.pump(const Duration(milliseconds: 1100));
  });

  testWidgets('ConfirmScreen does not auto-resolve personal place aliases',
      (tester) async {
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '단기임대 렌트',
            location: '원주집',
            rawText: '5월 25일부터 6월 1일까지 원주집 단기임대 렌트',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _RestaurantLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 300));

    final locationField = _textFieldWithLabel('장소');
    expect(
      tester.widget<TextFormField>(locationField).controller?.text,
      '원주집',
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 200));

    final saved = repository.createdEvents.single;
    expect(saved.location, '원주집');
    expect(saved.locationLat, isNull);
    expect(saved.locationLng, isNull);
  });

  testWidgets(
      'ConfirmScreen drops stale coordinates when AI changes the place name',
      (tester) async {
    ScheduleParseAdGate.instance.delegateForTest = _DailyFreeAdGateDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest =
        _CountingEntitlementDelegate();
    final parseCompleter = Completer<Map<String, dynamic>>();
    final repository = _FakeEventRepository();
    final parsed = _parsedSchedule(
      title: '병원 방문',
      location: '경포대',
      rawText: '강릉아산병원으로 일정 잡아줘',
    )
      ..['location_lat'] = 37.795
      ..['location_lng'] = 128.907
      ..['parse_pending'] = true
      ..['manual_text_confirmed'] = true;

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: parsed,
          gptService: _DeferredGptService(parseCompleter.future),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _GangneungHospitalLocationLookupService(),
          permissionService: _AlarmReadyPermissionService(),
        ),
      ),
    );
    await tester.pump();

    parseCompleter.complete(<String, dynamic>{
      'title': '강릉아산병원 방문',
      'location': '강릉아산병원',
      'location_lat': null,
      'location_lng': null,
      'memo': null,
      'start_at': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
      'end_at': null,
      'supplies': <String>[],
      'is_critical': false,
      'pre_actions': <Map<String, dynamic>>[],
      'parse_failed': false,
    });

    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 20 && repository.createdEvents.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final saved = repository.createdEvents.single;
    expect(saved.location, '강릉아산병원');
    expect(saved.locationLat, closeTo(37.8182, 0.0001));
    expect(saved.locationLng, closeTo(128.8572, 0.0001));
    expect(saved.locationLat, isNot(closeTo(37.795, 0.0001)));
    expect(saved.locationLng, isNot(closeTo(128.907, 0.0001)));
  });

  testWidgets(
      'ConfirmScreen blocks the editor with a full-screen loader while hydrating',
      (tester) async {
    ScheduleParseAdGate.instance.delegateForTest = _DailyFreeAdGateDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest =
        _CountingEntitlementDelegate();
    final parseCompleter = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '초기 제목',
            location: '',
            memo: null,
            rawText: '내일 오전 9시에 대전출발',
          )
            ..['parse_pending'] = true
            ..['manual_text_confirmed'] = true,
          gptService: _DeferredGptService(parseCompleter.future),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pump();
    expect(
      find.text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.'),
      findsAtLeastNWidgets(1),
    );
    // The route-wide loader covers the editor while the deferred AI call is
    // pending, so no fields can be edited or saved at this point.
    expect(find.text('설명 · 준비물'), findsOneWidget);
    expect(find.text('제목'), findsOneWidget);

    parseCompleter.complete(
      <String, dynamic>{
        'title': 'AI 제목',
        'location': 'AI 장소',
        'memo': 'AI 메모',
        'start_at': DateTime(2026, 5, 11, 9).toIso8601String(),
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      },
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (var attempt = 0;
        attempt < 20 &&
            find
                .text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.')
                .evaluate()
                .isNotEmpty;
        attempt += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Once parsing completes the loader disappears and AI results populate
    // the editable fields.
    expect(
      find.text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.'),
      findsNothing,
    );
    final titleField = _textFieldWithLabel('제목');
    final locationField = _textFieldWithLabel('장소');
    expect(tester.widget<TextFormField>(titleField).controller?.text, 'AI 제목');
    expect(
      tester.widget<TextFormField>(locationField).controller?.text,
      'AI 장소',
    );
  });

  testWidgets(
      'ConfirmScreen retries a resolved AI parse failure without re-consuming reward',
      (tester) async {
    ScheduleParseAdGate.instance.delegateForTest = _DailyFreeAdGateDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest =
        _CountingEntitlementDelegate();
    final gpt = _SequenceGptService();
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '원본 제목',
            rawText: '내일 오전 9시 원본 제목',
          )
            ..['parse_pending'] = true
            ..['manual_text_confirmed'] = true,
          gptService: gpt,
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(gpt.calls, 1);
    expect(
        find.text('일정을 바로 정리하지 못했어요. 입력 내용을 확인하고 다시 시도해 주세요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-ai-parse')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('retry-ai-parse')));
    await tester.pump();
    expect(
      find.text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.'),
      findsAtLeastNWidgets(1),
    );
    gpt.completeRetry();
    for (var attempt = 0; attempt < 20 && gpt.calls < 2; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(gpt.calls, 2);
    for (var attempt = 0;
        attempt < 20 &&
            find
                .text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.')
                .evaluate()
                .isNotEmpty;
        attempt += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('retry-ai-parse')), findsNothing);
    final titleField = _textFieldWithLabel('제목');
    expect(tester.widget<TextFormField>(titleField).controller?.text, '재시도 제목');
  });

  testWidgets('ConfirmScreen stores Korean wall time as UTC once',
      (tester) async {
    final repository = _FakeEventRepository();
    // 과거 날짜는 _safeStartAt이 now()로 보정하므로(1일 이상 과거면 클램프),
    // 캘린더가 지나도 깨지지 않도록 항상 미래인 내년 날짜를 쓴다.
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 10);
    final end = DateTime(year, 6, 14, 9);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            startAt: start,
            endAt: end,
            rawText: '$year년 6월 13일부터 6월 14일까지 일정',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(saved.startAt, DateTime.utc(year, 6, 13, 1));
    expect(planflowLocal(saved.startAt!), start);
    expect(planflowLocal(saved.endAt!), end);
    expect(saved.isMultiDay, isTrue);
  });

  testWidgets('ConfirmScreen drops an unsupported next-day end before saving',
      (tester) async {
    final repository = _FakeEventRepository();
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 10);
    final unsupportedEnd = DateTime(year, 6, 14, 9);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '프로젝트 회의',
            startAt: start,
            endAt: unsupportedEnd,
            rawText: '$year년 6월 13일 오전 10시 프로젝트 회의',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(saved.endAt, isNull);
    expect(saved.isMultiDay, isFalse);
  });

  testWidgets('ConfirmScreen lets users choose PM for ambiguous evening time',
      (tester) async {
    final repository = _FakeEventRepository();
    final start = DateTime(2030, 6, 13, 7, 40);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '모란역 가기',
            startAt: start,
            location: '모란역',
            rawText: '7시 40분까지 모란역 가기',
          )..['time_period_ambiguous'] = true,
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('오후 7:40'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(2030, 6, 13, 19, 40));
  });

  testWidgets(
      'ConfirmScreen keeps 30-minute "반" time after PM selection (regression)',
      (tester) async {
    // "여덟시 반에" 처럼 "반" 뒤에 조사가 붙는 발화를 오전/오후 확인
    // 다이얼로그에서 선택한 뒤에도 분이 0으로 리셋되지 않고 30분이
    // 그대로 유지되는지 검증한다(_ambiguousClockFromRawText 회귀).
    final repository = _FakeEventRepository();
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 8, 0);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '팀 미팅',
            startAt: start,
            rawText: '여덟시 반에 미팅있어',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('오후 8:30'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(year, 6, 13, 20, 30));
  });

  testWidgets(
      'ConfirmScreen keeps 30-minute "삼십분" time after PM selection (regression)',
      (tester) async {
    // "여덟시 삼십분에" 발화도 동일한 그리디 매칭 버그 대상이었다 -
    // 오전/오후 선택 후 분이 30으로 유지되는지 검증한다.
    final repository = _FakeEventRepository();
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 8, 0);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '팀 회의',
            startAt: start,
            rawText: '여덟시 삼십분에 회의',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('오전 8:30'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(year, 6, 13, 8, 30));
  });

  testWidgets(
      'ConfirmScreen parses compound sino-Korean minute "십오분" (regression)',
      (tester) async {
    // "여덟시 십오분에" 처럼 십의 자리 없이 사이노-한글 조합(십오=15)만
    // 있는 분 표현이 0분으로 떨어지지 않고 정확히 파싱되는지 검증한다.
    final repository = _FakeEventRepository();
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 8, 0);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '팀 회의',
            startAt: start,
            rawText: '여덟시 십오분에 회의',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('오전 8:15'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(year, 6, 13, 8, 15));
  });

  testWidgets(
      'ConfirmScreen parses compound sino-Korean minute "이십오분" (regression)',
      (tester) async {
    // "여덟시 이십오분에" 처럼 십의 자리+일의 자리가 결합된 사이노-한글
    // 조합(이십오=25)도 정확히 파싱되는지 검증한다.
    final repository = _FakeEventRepository();
    final year = DateTime.now().year + 1;
    final start = DateTime(year, 6, 13, 8, 0);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '팀 회의',
            startAt: start,
            rawText: '여덟시 이십오분에 회의',
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('오전 8:25'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(year, 6, 13, 8, 25));
  });

  testWidgets('ConfirmScreen shows supplies as compact editable rows',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            supplies: const <String>['물', '충전기'],
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('설명 · 준비물'));
    await tester.pump(const Duration(milliseconds: 200));
    // 준비물이 있어도 이제 자동으로 펼치지 않으므로 직접 탭해서 연다.
    await tester.tap(find.text('설명 · 준비물'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('물'));

    expect(find.text('물'), findsOneWidget);
    expect(find.text('충전기'), findsOneWidget);
    expect(find.textContaining('체크리스트로'), findsNothing);
    expect(find.text('진행 중'), findsNothing);
  });

  testWidgets(
      'ConfirmScreen saves both personal and group event when 개인 + 그룹 is selected',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
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
    final repository = _FakeEventRepository();
    final groupEventRepository = _FakeGroupEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule()..['is_multi_day'] = true,
          backend: _FakeConfirmBackend(),
          eventRepository: repository,
          groupContextProvider: contextProvider,
          groupEventRepository: groupEventRepository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsOneWidget);

    await tester.tap(find.text('개인 + 우리 팀'));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0;
        i < 30 &&
            (repository.createdEvents.isEmpty ||
                groupEventRepository.createdEvents.isEmpty);
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(groupEventRepository.createdEvents, hasLength(1));
    expect(
      groupEventRepository.createdEvents.single.personalEventId,
      repository.createdEvents.single.id,
    );
    expect(
      groupEventRepository.createdEvents.single.endAt.difference(
        groupEventRepository.createdEvents.single.startAt,
      ),
      const Duration(minutes: 30),
    );
  });

  testWidgets(
      'ConfirmScreen saves only a group event when 그룹만 is selected (no personal copy)',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
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
    final repository = _FakeEventRepository();
    final groupEventRepository = _FakeGroupEventRepository();

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
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsOneWidget);

    await tester.tap(find.text('우리 팀만'));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0;
        i < 30 && groupEventRepository.createdEvents.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 100));

    // 개인 일정 사본은 생성되지 않고, 그룹 일정만 생성되며 연결된 개인
    // 일정이 없으므로 personalEventId는 null이어야 한다.
    expect(repository.createdEvents, isEmpty);
    expect(groupEventRepository.createdEvents, hasLength(1));
    expect(groupEventRepository.createdEvents.single.personalEventId, isNull);

    // 개인 저장이 없을 때는 평소(억제되는) 성공 메시지 대신 그룹 공유
    // 안내 메시지가 대체로 표시되어야 한다(사용자 피드백 유지).
    expect(find.text('그룹에 일정을 공유했어요.'), findsOneWidget);
  });

  testWidgets(
      'ConfirmScreen without a selected group hides save-scope card and saves personal only',
      (tester) async {
    final repository = _FakeEventRepository();

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
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsNothing);

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets(
      'ConfirmScreen asks a group leader to share before saving and persists the choice with 다시 보지 않기',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'user-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final repository = _FakeEventRepository();
    final groupEventRepository = _FakeGroupEventRepository();

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
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pumpAndSettle();

    expect(find.text('그룹에 일정을 공유할까요?'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('leader-share-dialog-dont-ask-again')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('leader-share-accept-button')));
    await tester.pumpAndSettle();

    for (var i = 0;
        i < 30 &&
            (repository.createdEvents.isEmpty ||
                groupEventRepository.createdEvents.isEmpty);
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(groupEventRepository.createdEvents, hasLength(1));

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('planflow:group_auto_share:v1:user-1:group-1'),
      isTrue,
    );
  });

  testWidgets(
      'ConfirmScreen does not ask again once the leader has already decided',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_auto_share:v1:user-1:group-1': true,
    });
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'user-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final repository = _FakeEventRepository();
    final groupEventRepository = _FakeGroupEventRepository();

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
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pumpAndSettle();

    expect(find.text('그룹에 일정을 공유할까요?'), findsNothing);

    for (var i = 0;
        i < 30 &&
            (repository.createdEvents.isEmpty ||
                groupEventRepository.createdEvents.isEmpty);
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(groupEventRepository.createdEvents, hasLength(1));
  });

  testWidgets(
      'ConfirmScreen defaults the group picker to the most recently shared groups',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_last_shared_ids:v1:user-1': <String>['group-2'],
    });
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'user-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
          GroupModel(
            id: 'group-2',
            createdBy: 'leader-2',
            name: '동아리',
            createdAt: DateTime.utc(2026, 6, 12),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
          'group-2': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-2',
              groupId: 'group-2',
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
          eventRepository: _FakeEventRepository(),
          groupContextProvider: contextProvider,
          groupEventRepository: _FakeGroupEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // provider.selectedGroup 기본값(리더 그룹인 group-1)이 아니라, 마지막으로
    // 공유했던 group-2가 저장 범위 카드에 반영돼야 한다.
    expect(find.text('개인 + 동아리'), findsOneWidget);
    expect(find.text('개인 + 우리 팀'), findsNothing);
  });

  testWidgets(
      'ConfirmScreen saves both personal and group event when 개인 + 그룹 is selected',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
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
    final eventRepository = _FakeEventRepository();
    final groupEventRepository = _FakeGroupEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: eventRepository,
          groupContextProvider: contextProvider,
          groupEventRepository: groupEventRepository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsOneWidget);

    await tester.tap(find.text('개인 + 우리 팀'));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(eventRepository.createdEvents, hasLength(1));
    expect(groupEventRepository.createdEvents, hasLength(1));
    expect(
      groupEventRepository.createdEvents.single.personalEventId,
      eventRepository.createdEvents.single.id,
    );
  });

  testWidgets(
      'ConfirmScreen without a selected group hides save-scope card and saves personal only',
      (tester) async {
    final eventRepository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(),
          backend: _FakeConfirmBackend(),
          eventRepository: eventRepository,
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: _DeniedPermissionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsNothing);

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(eventRepository.createdEvents, hasLength(1));
  });

  testWidgets(
      'ConfirmScreen falls back to manual save after ad denial without re-gating',
      (tester) async {
    final gate = _DeniedScheduleParseAdGateDelegate();
    ScheduleParseAdGate.instance.delegateForTest = gate;
    final parsed = _parsedSchedule(
      title: '',
      rawText: '내일 오전 10시에 성남으로 출발',
    )..['parse_pending'] = true;
    final repository = _FakeEventRepository();

    Widget buildConfirm() => _testApp(
          ConfirmScreen(
            userId: 'user-1',
            parsedSchedule: parsed,
            backend: _FakeConfirmBackend(),
            eventRepository: repository,
            notificationService: _FakeNotificationService(),
            homeWidgetService: _FakeHomeWidgetService(),
            locationLookupService: _EmptyLocationLookupService(),
            permissionService: _DeniedPermissionService(),
          ),
        );

    await tester.pumpWidget(buildConfirm());
    await tester.pumpAndSettle();

    expect(gate.calls, 1);
    expect(parsed['parse_pending'], isFalse);
    expect(parsed['manual_text_confirmed'], isTrue);
    expect(parsed['parse_failed'], isTrue);
    expect(find.byKey(const ValueKey('retry-ai-parse')), findsNothing);

    // Re-entering the same draft must not show the ad gate again.
    await tester.pumpWidget(buildConfirm());
    await tester.pumpAndSettle();
    expect(gate.calls, 1);

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repository.createdEvents, hasLength(1));
  });

  testWidgets(
      'ConfirmScreen does not consume entitlement when the ad gate grants an '
      'adFailedFreePass entry', (tester) async {
    // ScheduleParseAdGate가 광고 실패+free_pass 정책으로 진입을 허용한
    // 경우(H1 리뷰 지적) — 화면이 grant.source를 확인하지 않고 무조건
    // consume()을 호출하면 안 된다.
    ScheduleParseAdGate.instance.delegateForTest = _FreePassAdGateDelegate();
    final entitlementDelegate = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest =
        entitlementDelegate;

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '초기 제목',
            rawText: '내일 오전 9시에 대전출발',
          )..['parse_pending'] = true,
          gptService: _DeferredGptService(
            Future.value(<String, dynamic>{
              'title': 'AI 제목',
              'location': 'AI 장소',
              'memo': 'AI 메모',
              'start_at':
                  DateTime.now().add(const Duration(days: 1)).toIso8601String(),
              'end_at': null,
              'supplies': <String>[],
              'is_critical': false,
              'pre_actions': <Map<String, dynamic>>[],
              'parse_failed': false,
            }),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(entitlementDelegate.consumeCallCount, 0);
  });

  testWidgets(
      'ConfirmScreen consumes a granted entitlement only after AI parse succeeds',
      (tester) async {
    ScheduleParseAdGate.instance.delegateForTest = _DailyFreeAdGateDelegate();
    final entitlementDelegate = _CountingEntitlementDelegate();
    ScheduleParseEntitlementService.instance.delegateForTest =
        entitlementDelegate;
    await AdRewardState.instance.grant(
      requestId: 'schedule-parse-reward',
      feature: 'schedule_parse',
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '초기 제목',
            rawText: '내일 오전 9시에 대전출발',
          )..['parse_pending'] = true,
          gptService: _DeferredGptService(
            Future.value(<String, dynamic>{
              'title': 'AI 제목',
              'location': 'AI 장소',
              'memo': 'AI 메모',
              'start_at':
                  DateTime.now().add(const Duration(days: 1)).toIso8601String(),
              'end_at': null,
              'supplies': <String>[],
              'is_critical': false,
              'pre_actions': <Map<String, dynamic>>[],
              'parse_failed': false,
            }),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(entitlementDelegate.consumeCallCount, 1);
    expect(
      await AdRewardState.instance.consumeActiveRequestId(
        feature: 'schedule_parse',
      ),
      isNull,
    );
  });

  testWidgets(
      'ConfirmScreen keeps the result pending when entitlement consume fails',
      (tester) async {
    ScheduleParseAdGate.instance.delegateForTest = _DailyFreeAdGateDelegate();
    final entitlementDelegate = _CountingEntitlementDelegate(failConsume: true);
    ScheduleParseEntitlementService.instance.delegateForTest =
        entitlementDelegate;

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '원본 제목',
            rawText: '내일 오전 9시에 원본 제목',
          )..['parse_pending'] = true,
          gptService: _DeferredGptService(
            Future.value(<String, dynamic>{
              'title': 'AI 제목',
              'location': 'AI 장소',
              'memo': 'AI 메모',
              'start_at':
                  DateTime.now().add(const Duration(days: 1)).toIso8601String(),
              'end_at': null,
              'supplies': <String>[],
              'is_critical': false,
              'pre_actions': <Map<String, dynamic>>[],
              'parse_failed': false,
            }),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(entitlementDelegate.consumeCallCount, 1);
    expect(find.text('AI 정리는 완료됐지만 사용량 반영에 실패했어요. 잠시 후 다시 시도해 주세요.'),
        findsOneWidget);
    expect(find.text('AI 제목'), findsNothing);
    expect(find.byKey(const ValueKey('retry-ai-parse')), findsOneWidget);
  });

  testWidgets(
      'ConfirmScreen discards an unbound schedule reward before a new gate',
      (tester) async {
    final gate = _DailyFreeAdGateDelegate();
    ScheduleParseAdGate.instance.delegateForTest = gate;
    ScheduleParseEntitlementService.instance.delegateForTest =
        _CountingEntitlementDelegate();
    await AdRewardState.instance.grant(
      requestId: 'orphan-reward',
      feature: 'schedule_parse',
    );

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '원본 제목',
            rawText: '내일 오전 9시에 원본 제목',
          )..['parse_pending'] = true,
          gptService: _DeferredGptService(
            Future.value(<String, dynamic>{
              'title': 'AI 제목',
              'location': '',
              'memo': null,
              'start_at':
                  DateTime.now().add(const Duration(days: 1)).toIso8601String(),
              'end_at': null,
              'supplies': <String>[],
              'is_critical': false,
              'pre_actions': <Map<String, dynamic>>[],
              'parse_failed': false,
            }),
          ),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(gate.calls, 1);
  });
}

Widget _testApp(
  Widget child, {
  GuideCoordinator? guideCoordinator,
  bool showGuideCoachmark = true,
}) {
  final router = GoRouter(
    initialLocation: AppRoutes.confirm,
    routes: [
      GoRoute(
        path: AppRoutes.confirm,
        builder: (_, __) => guideCoordinator == null
            ? child
            : GuideScope(
                coordinator: guideCoordinator,
                child: showGuideCoachmark
                    ? Stack(children: [
                        child,
                        Positioned.fill(
                          child: RealUiGuideCoachmark(
                              coordinator: guideCoordinator, onSkip: () {}),
                        ),
                      ])
                    : child,
              ),
      ),
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

Widget _voiceStackTestApp(Widget confirmScreen) {
  final router = GoRouter(
    initialLocation: AppRoutes.voice,
    routes: [
      GoRoute(
        path: AppRoutes.voice,
        builder: (context, __) => Scaffold(
          body: Column(
            children: [
              const Text('음성 입력'),
              TextButton(
                onPressed: () => context.push(AppRoutes.confirm),
                child: const Text('확인 화면 열기'),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.confirm,
        builder: (_, __) => confirmScreen,
      ),
      GoRoute(
        path: AppRoutes.calendar,
        builder: (_, __) => const Scaffold(body: Text('일정')),
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

Finder _textFieldWithLabel(String label) {
  return find.ancestor(
    of: find.text(label),
    matching: find.byType(TextFormField),
  );
}

Map<String, dynamic> _parsedSchedule({
  bool isCritical = false,
  DateTime? startAt,
  DateTime? endAt,
  List<String> supplies = const <String>[],
  String? title,
  String? location,
  String? rawText,
  String? memo = '테스트 일정',
  String? recurrenceRule,
}) {
  return {
    'title': title ?? '성남 출발',
    'start_at': (startAt ?? DateTime.now().add(const Duration(hours: 3)))
        .toIso8601String(),
    'end_at': endAt?.toIso8601String(),
    'location': location ?? '성남',
    'memo': memo,
    'supplies': supplies,
    'is_critical': isCritical,
    'recurrence_rule': recurrenceRule,
    'pre_actions': <Map<String, dynamic>>[],
    'raw_text': rawText ?? '내일 오전 10시에 성남으로 출발',
  };
}

class _DeferredGptService extends GptService {
  _DeferredGptService(this._resultFuture);

  final Future<Map<String, dynamic>> _resultFuture;

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    return _resultFuture;
  }
}

class _SequenceGptService extends GptService {
  int calls = 0;
  final Completer<Map<String, dynamic>> _retryCompleter =
      Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    calls += 1;
    if (calls == 1) {
      return <String, dynamic>{'parse_failed': true};
    }
    return _retryCompleter.future;
  }

  void completeRetry() {
    final retryStartAt = DateTime.now().add(const Duration(days: 1));
    _retryCompleter.complete(<String, dynamic>{
      'title': '재시도 제목',
      'location': '재시도 장소',
      'memo': null,
      'start_at': retryStartAt.toIso8601String(),
      'end_at': null,
      'supplies': <String>[],
      'is_critical': false,
      'pre_actions': <Map<String, dynamic>>[],
      'parse_failed': false,
    });
  }
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

class _SingleLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return const <LocationLookupResult>[
      LocationLookupResult(
        name: '원주세브란스기독병원',
        address: '강원특별자치도 원주시 일산로 20',
        latitude: 37.3495,
        longitude: 127.9458,
      ),
    ];
  }
}

class _DelayedSingleLocationLookupService extends _SingleLocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    return super.search(query, origin: origin);
  }
}

class _RestaurantLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return const <LocationLookupResult>[
      LocationLookupResult(
        name: '원주뚝배기짬뽕 본점[중식]',
        address: '강원특별자치도 원주시 어느길 1',
        latitude: 37.342,
        longitude: 127.92,
      ),
    ];
  }
}

class _GangneungHospitalLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    if (!query.contains('강릉아산병원')) {
      return const <LocationLookupResult>[];
    }
    return const <LocationLookupResult>[
      LocationLookupResult(
        name: '강릉아산병원',
        address: '강원특별자치도 강릉시 사천면 방동길 38',
        latitude: 37.8182,
        longitude: 128.8572,
      ),
    ];
  }
}

class _FakeConfirmBackend extends ConfirmScreenBackend {
  final reminderPayloads = <Map<String, dynamic>>[];

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async {
    return const <String>[];
  }

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    reminderPayloads.addAll(payloads);
  }

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _FakeEventRepository extends EventRepository {
  final createdEvents = <EventModel>[];

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return createdEvents.where((event) {
      if (excludedEventId != null && event.id == excludedEventId) {
        return false;
      }
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
      return startAt.toUtc().isBefore(rangeEnd.toUtc()) &&
          rangeStart.toUtc().isBefore(endAt.toUtc());
    }).toList(growable: false);
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
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
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return createdEvents.where((event) => event.id == eventId).firstOrNull;
  }

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
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    return membersByGroupId[groupId] ?? const <GroupMemberModel>[];
  }

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
  ) async {
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    final saved = event.copyWith(
      id: 'group-event-${createdEvents.length + 1}',
    );
    createdEvents.add(saved);
    return saved;
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    throw UnimplementedError();
  }
}

class _ThrowingEventRepository extends _FakeEventRepository {
  @override
  Future<EventModel> createEvent(EventModel event) async {
    throw StateError('A signed-in user is required for event writes.');
  }
}

class _FakeNotificationService extends NotificationService {
  _FakeNotificationService({this.eventReminderResult});

  final NotificationScheduleResult? eventReminderResult;
  final eventReminderTitles = <String>[];
  final criticalAlarmTitles = <String>[];
  final criticalAlarmNotifyAts = <DateTime>[];

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
  }) async {
    await scheduleEventReminderWithResult(
      id: id,
      title: title,
      body: body,
      notifyAt: notifyAt,
      payload: payload,
      includeDepartureAction: includeDepartureAction,
    );
  }

  @override
  Future<NotificationScheduleResult> scheduleEventReminderWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async {
    eventReminderTitles.add(title);
    return eventReminderResult ??
        NotificationScheduleResult(
          status: NotificationScheduleStatus.scheduled,
          notifyAt: notifyAt,
        );
  }

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    criticalAlarmTitles.add(title);
    criticalAlarmNotifyAts.add(notifyAt);
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
    criticalAlarmTitles.add(title);
    criticalAlarmNotifyAts.add(notifyAt);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
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
    List<HomeWidgetWeekDayData> nextWeekDays = const <HomeWidgetWeekDayData>[],
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    return true;
  }

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
  }) async {
    return true;
  }
}

class _DeniedPermissionService extends AppPermissionService {
  @override
  Future<bool> checkLocationPermission() async => false;

  @override
  Future<bool> requestLocationPermission() async => false;

  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async {
    return null;
  }

  @override
  Future<bool> openAppSettings() async => true;
}

class _ExactAlarmMissingPermissionService extends _DeniedPermissionService {
  int openAlarmSettingsCalls = 0;
  bool exactAlarmGranted = false;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: true,
      locationGranted: true,
      calendarGranted: true,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: true,
        exactAlarmsEnabled: exactAlarmGranted,
        fullScreenIntentStatus: PermissionCheckState.granted,
      ),
      batteryOptimizationIgnored: true,
    );
  }

  @override
  Future<bool> openAlarmSettings() async {
    openAlarmSettingsCalls += 1;
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async => true;
}

class _AlarmReadyPermissionService extends _DeniedPermissionService {
  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return const AppPermissionSnapshot(
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
  }
}

class _DeniedScheduleParseAdGateDelegate
    implements ScheduleParseAdGateDelegate {
  int calls = 0;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  }) async {
    calls += 1;
    onDenied?.call(ScheduleParseGateDenialReason.userCanceled);
  }
}

/// [ScheduleParseAdGate] delegate that always simulates the "광고 실패 +
/// rewardAdFailurePolicy=free_pass" 진입 승인 분기(consume()을 호출하면
/// 안 되는 grant.source).
class _FreePassAdGateDelegate implements ScheduleParseAdGateDelegate {
  @override
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  }) async {
    onEnterAllowed(
      ScheduleParseEntryGrant(
        sessionId: ScheduleParseSessionIdGenerator.next(),
        source: ScheduleParseEntitlementSource.adFailedFreePass,
        dailyRemainingAtGate: 0,
      ),
    );
  }
}

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

/// [ScheduleParseEntitlementService]의 consume() 호출 횟수를 세는 fake.
class _CountingEntitlementDelegate implements ScheduleParseEntitlementDelegate {
  _CountingEntitlementDelegate({this.failConsume = false});

  final bool failConsume;
  int consumeCallCount = 0;

  @override
  Future<ScheduleParseEntitlementPeek?> peek() async =>
      const ScheduleParseEntitlementPeek(dailyRemaining: 0, requiresAd: true);

  @override
  Future<ScheduleParseConsumeResult?> consume(String sessionId) async {
    consumeCallCount += 1;
    if (failConsume) {
      return null;
    }
    return const ScheduleParseConsumeResult(
      source: 'daily_free',
      dailyRemaining: 0,
    );
  }
}

/// Registers only the real ConfirmScreen save-stage regression. The native
/// adapter imports this function instead of the whole ConfirmScreen suite.
void registerConfirmScreenGuideSaveStageTests({bool nativeOsSaveTap = false}) {
  group('ConfirmScreen save stage with the real guide host', () {
    setUp(_installConfirmScreenTestEnvironment);
    tearDown(_tearDownConfirmScreenTestEnvironment);

    Widget screen(
      Map<String, dynamic> parsed, {
      GptService? gptService,
      EventRepository? eventRepository,
      AppPermissionService? permissionService,
    }) =>
        ConfirmScreen(
          userId: 'u',
          parsedSchedule: parsed,
          gptService: gptService,
          backend: _FakeConfirmBackend(),
          eventRepository: eventRepository ?? _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
          locationLookupService: _EmptyLocationLookupService(),
          permissionService: permissionService ?? _DeniedPermissionService(),
        );

    testWidgets('shows the check-first banner as soon as the save screen opens',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator =
          await save_stage_fixture.bootGuideAtCorrectAndSave();
      await tester.pumpWidget(
          _testApp(screen(_parsedSchedule()), guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);

      // 화면에 들어오자마자 날짜·시간·장소 확인과 스크롤 안내가 보여야 한다.
      expect(guideConfirmReady.value, isTrue, reason: 'parse ready');
      expect(guideConfirmUserScrolled.value, isFalse, reason: 'not scrolled');
      expect(find.text('2/7 · 일정 확인'), findsOneWidget);
      expect(guideSaveStage.value, GuideSaveStage.important);
      // 스크롤 전에는 스포트라이트/딤을 켜지 않고, 안내가 대신 스크롤하지 않는다.
      expect(find.byType(GuidedCoachmarkOverlay), findsNothing);
      expect(_guideDimPainted(tester), isFalse);
      expect(_confirmScrollOffset(tester), 0);

      // 스크롤 후에는 첫 단계(중요한 일정) 강조로 바뀐다.
      await _scrollUntilAnchorVisible(tester, 'confirm.critical');
      await _pumpGuideFrames(tester);

      expect(find.text('2/7 · 일정 확인'), findsNothing);
      expect(_guideOverlayTarget(tester), 'confirm.critical');
      expect(find.text('2/7 · 중요한 일정'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('enters at important and walks important -> strong -> save',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave();
      // A stale stage from a previous run must not leak into this entry.
      guideSaveStage.value = GuideSaveStage.save;
      guideSaveStageActive.value = false;

      await tester.pumpWidget(
          _testApp(screen(_parsedSchedule()), guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);

      expect(guideSaveStage.value, GuideSaveStage.important,
          reason: 'entering correctAndSave must restart at important');
      // The guide never scrolls the list for the user, so nothing may be
      // spotlighted before the user scrolls down by hand.
      expect(find.byType(GuidedCoachmarkOverlay), findsNothing,
          reason: 'no spotlight before the user scrolls the list');
      expect(find.text('2/7 · 중요한 일정'), findsNothing);
      expect(_guideDimPainted(tester), isFalse);
      expect(_confirmScrollOffset(tester), 0,
          reason: 'the guide must not scroll the list for the user');

      await _scrollUntilAnchorVisible(tester, 'confirm.critical');
      await _pumpGuideFrames(tester);

      expect(_guideOverlayTarget(tester), 'confirm.critical');
      expect(find.text('2/7 · 중요한 일정'), findsOneWidget);
      _expectGuideHoleOn(tester, 'confirm.critical');

      await tester.ensureVisible(find.text('중요한 일정으로 표시'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('중요한 일정으로 표시'));
      await _pumpGuideFrames(tester);

      expect(tester.takeException(), isNull);
      expect(guideSaveStage.value, GuideSaveStage.strong);
      expect(_guideOverlayTarget(tester), 'confirm.strong');
      expect(find.text('2/7 · 강한 알람'), findsOneWidget);
      _expectGuideHoleOn(tester, 'confirm.strong');

      await tester.ensureVisible(find.text('강한 알람'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('강한 알람'));
      await _pumpGuideFrames(tester);

      expect(tester.takeException(), isNull);
      expect(guideSaveStage.value, GuideSaveStage.save);
      expect(_guideOverlayTarget(tester), 'confirm.save');
      expect(find.text('2/7 · 저장하기'), findsOneWidget);
      _expectGuideHoleOn(tester, 'confirm.save');

      final topKey = realUiGuideAnchorRegistry.keyFor('confirm.save.top');
      final bottomKey = realUiGuideAnchorRegistry.keyFor('confirm.save');
      expect(topKey, isNotNull);
      expect(bottomKey, isNotNull);
      expect(identical(topKey, bottomKey), isFalse,
          reason: 'top and bottom save buttons must not share one id');
      final overlayRoot = tester
          .element(find.byType(GuidedCoachmarkOverlay))
          .findRenderObject() as RenderBox;
      expect(
          realUiGuideAnchorRegistry.rectFor('confirm.save', root: overlayRoot),
          isNot(realUiGuideAnchorRegistry.rectFor('confirm.save.top',
              root: overlayRoot)));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('preset important skips to strong without unchecking it',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave();
      guideSaveStage.value = GuideSaveStage.important;
      guideSaveStageActive.value = false;

      await tester.pumpWidget(_testApp(
          screen(_parsedSchedule(isCritical: true)),
          guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);

      await _scrollUntilAnchorVisible(tester, 'confirm.strong');
      await _pumpGuideFrames(tester);

      expect(guideSaveStage.value, GuideSaveStage.strong,
          reason: 'an already enabled switch is skipped, never toggled off');
      expect(_guideOverlayTarget(tester), 'confirm.strong');
      final checkbox = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, '중요한 일정으로 표시'));
      expect(checkbox.value, isTrue, reason: 'parsed values stay untouched');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('preset important and strong skip to save', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave();
      guideSaveStage.value = GuideSaveStage.important;
      guideSaveStageActive.value = false;
      final parsed = _parsedSchedule(isCritical: true);
      parsed['use_strong_alarm'] = true;

      await tester
          .pumpWidget(_testApp(screen(parsed), guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);

      await _scrollUntilAnchorVisible(tester, 'confirm.save');
      await _pumpGuideFrames(tester);

      expect(guideSaveStage.value, GuideSaveStage.save);
      expect(_guideOverlayTarget(tester), 'confirm.save');
      _expectGuideHoleOn(tester, 'confirm.save');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets(
        'keeps the guide hidden while the AI parse is pending and reveals it '
        'only after the user scrolls the list down', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final parseCompleter = Completer<Map<String, dynamic>>();
      // A live guide session authorizes its own parse through the guide
      // quota lane, exactly like the production flow.
      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave(
          grantPermits: true);
      SupabaseClientAccess.overrideForRun(() => 'u');
      save_stage_fixture.bindGuideRuntime(coordinator, uid: 'u');

      final parsed = _parsedSchedule()..['parse_pending'] = true;
      await tester.pumpWidget(_testApp(
          screen(parsed,
              gptService: _DeferredGptService(parseCompleter.future)),
          guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);

      // The AI parse is still running: the editor is blurred, so no guide
      // banner, dim layer or hole may cover it.
      expect(find.text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.'),
          findsAtLeastNWidgets(1));
      expect(find.byType(GuidedCoachmarkOverlay), findsNothing,
          reason: 'the spotlight must not cover the blurred editor');
      expect(find.text('2/7 · 중요한 일정'), findsNothing);
      expect(_guideDimPainted(tester), isFalse);

      // The parse finishes. The guide still stays away and never scrolls the
      // list for the user.
      parseCompleter.complete(<String, dynamic>{
        'title': 'AI 제목',
        'location': '성남',
        'memo': null,
        'start_at':
            DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      });
      await _pumpGuideFrames(tester);

      expect(find.text('AI가 입력 내용을 정리하고 있습니다. 잠시 기다려 주세요.'), findsNothing);
      expect(find.byType(GuidedCoachmarkOverlay), findsNothing,
          reason:
              'the guide must not reveal the target before the user scrolls');
      expect(find.text('2/7 · 중요한 일정'), findsNothing);
      expect(_guideDimPainted(tester), isFalse);
      expect(_confirmScrollOffset(tester), 0,
          reason: 'the guide must never scroll the list for the user');

      // The user scrolls the list down by hand: now the real sequence runs.
      await _scrollUntilAnchorVisible(tester, 'confirm.critical');
      await _pumpGuideFrames(tester);

      expect(_guideOverlayTarget(tester), 'confirm.critical');
      expect(find.text('2/7 · 중요한 일정'), findsOneWidget);
      _expectGuideHoleOn(tester, 'confirm.critical');

      await tester.tap(find.text('중요한 일정으로 표시'));
      await _pumpGuideFrames(tester);

      expect(tester.takeException(), isNull);
      expect(guideSaveStage.value, GuideSaveStage.strong);
      expect(_guideOverlayTarget(tester), 'confirm.strong');
      expect(find.text('2/7 · 강한 알람'), findsOneWidget);

      await tester.tap(find.text('강한 알람'));
      await _pumpGuideFrames(tester);

      expect(tester.takeException(), isNull);
      expect(guideSaveStage.value, GuideSaveStage.save);
      expect(_guideOverlayTarget(tester), 'confirm.save');
      expect(find.text('2/7 · 저장하기'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    testWidgets(
        'isolated QA save creates real repository response and reaches savedDetail without coordinates',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave(
          createdEventId: null);
      final repository = _FakeEventRepository();
      SupabaseClientAccess.overrideForRun(() => 'u');
      guideSaveStage.value = GuideSaveStage.important;
      guideSaveStageActive.value = false;
      final parsed = _parsedSchedule()
        ..['location_lat'] = null
        ..['location_lng'] = null;
      await tester.pumpWidget(_testApp(
          screen(parsed,
              eventRepository: repository,
              permissionService: _AlarmReadyPermissionService()),
          guideCoordinator: coordinator,
          showGuideCoachmark: false));
      await _pumpGuideFrames(tester);
      await tester.enterText(
          find.byKey(const Key('event-editor-location-field')), 'Somewhere');
      await tester.pump();
      guideSaveStage.value = GuideSaveStage.save;
      guideSaveStageActive.value = true;
      await _pumpGuideFrames(tester);
      await _scrollUntilAnchorVisible(tester, 'confirm.save');
      await _pumpGuideFrames(tester);

      expect(guideSaveStage.value, GuideSaveStage.save);
      await tester
          .ensureVisible(find.widgetWithText(FilledButton, '일정 저장').last);
      await tester.pump();
      final saveFinder = find.widgetWithText(FilledButton, '일정 저장').last;
      if (nativeOsSaveTap) {
        // Native proof requires a real Android input tap, never onPressed.
        // ignore: avoid_print
        print('QA_SAVE_READY_FOR_OS_TAP');
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (repository.createdEvents.isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        });
      } else {
        await tester.tap(saveFinder);
        for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
      await _pumpGuideFrames(tester);

      expect(repository.createdEvents, hasLength(1));
      final persisted = repository.createdEvents.single;
      expect(persisted.id, 'event-1');
      expect(persisted.location, isNotEmpty);
      expect(persisted.locationLat, isNull);
      expect(persisted.locationLng, isNull);
      expect(coordinator.state.value.createdEventId, 'event-1');
      expect(coordinator.state.value.step, GuideStep.savedDetail);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, skip: !const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA'));

    testWidgets(
        'isolated QA save actual tap passes through live guide coachmark without coordinates',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave(
          createdEventId: null);
      final repository = _FakeEventRepository();
      SupabaseClientAccess.overrideForRun(() => 'u');
      guideSaveStage.value = GuideSaveStage.important;
      guideSaveStageActive.value = false;
      final parsed = _parsedSchedule()
        ..['location_lat'] = null
        ..['location_lng'] = null;
      await tester.pumpWidget(_testApp(
          screen(parsed,
              eventRepository: repository,
              permissionService: _AlarmReadyPermissionService()),
          guideCoordinator: coordinator));
      await _pumpGuideFrames(tester);
      await tester.enterText(
          find.byKey(const Key('event-editor-location-field')), 'Somewhere');
      await tester.pump();
      guideSaveStage.value = GuideSaveStage.save;
      guideSaveStageActive.value = true;
      await _pumpGuideFrames(tester);
      await _scrollUntilAnchorVisible(tester, 'confirm.save');
      await _pumpGuideFrames(tester);

      expect(coordinator.state.value.step, GuideStep.correctAndSave);
      expect(find.byType(GuidedCoachmarkOverlay), findsOneWidget);
      expect(_guideOverlayTarget(tester), 'confirm.save');
      _expectGuideHoleOn(tester, 'confirm.save');
      final saveFinder = find.widgetWithText(FilledButton, '일정 저장').last;
      await tester.ensureVisible(saveFinder);
      await tester.pump();
      expect(tester.widget<FilledButton>(saveFinder).onPressed, isNotNull);
      await tester.tap(saveFinder);
      for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _pumpGuideFrames(tester);

      expect(repository.createdEvents, hasLength(1));
      expect(repository.createdEvents.single.location, 'Somewhere');
      expect(repository.createdEvents.single.locationLat, isNull);
      expect(repository.createdEvents.single.locationLng, isNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, skip: !const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA'));
    // Companion: the same unresolved-coordinate save must stay blocked unless
    // the isolated QA build is compiled in.
    testWidgets('non-QA build still blocks a guide save without coordinates',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final coordinator = await save_stage_fixture.bootGuideAtCorrectAndSave(
          createdEventId: null);
      final repository = _FakeEventRepository();
      SupabaseClientAccess.overrideForRun(() => 'u');
      guideSaveStage.value = GuideSaveStage.important;
      guideSaveStageActive.value = false;
      final parsed = _parsedSchedule()
        ..['location_lat'] = null
        ..['location_lng'] = null;
      await tester.pumpWidget(_testApp(
          screen(parsed,
              eventRepository: repository,
              permissionService: _AlarmReadyPermissionService()),
          guideCoordinator: coordinator,
          showGuideCoachmark: false));
      await _pumpGuideFrames(tester);
      await tester.enterText(
          find.byKey(const Key('event-editor-location-field')), 'Somewhere');
      await tester.pump();
      guideSaveStage.value = GuideSaveStage.save;
      guideSaveStageActive.value = true;
      await _pumpGuideFrames(tester);
      await _scrollUntilAnchorVisible(tester, 'confirm.save');
      await _pumpGuideFrames(tester);

      await tester
          .ensureVisible(find.widgetWithText(FilledButton, '일정 저장').last);
      await tester.tap(find.widgetWithText(FilledButton, '일정 저장').last);
      await _pumpGuideFrames(tester);

      expect(repository.createdEvents, isEmpty);
      expect(coordinator.state.value.createdEventId, isNull);
      expect(coordinator.state.value.step, GuideStep.correctAndSave);
      expect(
          tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .whereType<String>()
              .any((t) => t.contains('좌표')),
          isTrue,
          reason: 'the production build must say why it cannot save');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, skip: const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA'));
  });
}

Future<void> _pumpGuideFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _guideOverlayTarget(WidgetTester tester) => tester
    .widget<GuidedCoachmarkOverlay>(find.byType(GuidedCoachmarkOverlay))
    .targetId;

void _expectGuideHoleOn(WidgetTester tester, String anchorId) {
  final clips = find.descendant(
      of: find.byType(GuidedCoachmarkOverlay), matching: find.byType(ClipPath));
  expect(clips, findsOneWidget,
      reason: 'target=$anchorId anchor=${_anchorRect(tester, anchorId)} '
          'offset=${_confirmScrollOffset(tester)} '
          'ready=${guideConfirmReady.value} scrolled=${guideConfirmUserScrolled.value}');
  final clipper = tester.widget<ClipPath>(clips).clipper;
  expect(clipper, isNotNull);
  final overlayRoot =
      tester.element(find.byType(GuidedCoachmarkOverlay)).findRenderObject();
  expect(overlayRoot, isA<RenderBox>());
  final root = overlayRoot as RenderBox;
  final rect = realUiGuideAnchorRegistry.rectFor(anchorId, root: root);
  expect(rect, isNotNull, reason: 'anchor $anchorId must be registered');
  expect(rect!.isEmpty, isFalse);
  final path = clipper!.getClip(root.size);
  expect(path.contains(rect.center), isFalse,
      reason: 'the cut-out must sit on $anchorId');
  expect(path.contains(const Offset(4, 4)), isTrue,
      reason: 'the rest of the screen must stay dimmed');
}

/// The real list the user scrolls on the save screen.
Finder _confirmScrollable() => find
    .descendant(
        of: find.byType(ConfirmScreen),
        matching: find.byType(SingleChildScrollView))
    .first;

/// Scrolls the list down the way a user does: a real drag with several move
/// events. Programmatic scrolling (ensureVisible/animateTo) must not reveal
/// the guide target, so the guide stays hidden until the user drags.
Future<void> _userScrollDown(WidgetTester tester,
    {double distance = 120, int steps = 8}) async {
  final scrollable = _confirmScrollable();
  final start = tester.getTopLeft(scrollable) + const Offset(24, 28);
  final gesture = await tester.startGesture(start);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, -distance / steps));
    await tester.pump(const Duration(milliseconds: 32));
  }
  // Let the pointer rest before lifting it so the gesture does not turn into
  // a fling that would scroll past the real target.
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}

Rect? _anchorRect(WidgetTester tester, String anchorId) {
  final viewport = tester.renderObject<RenderBox>(_confirmScrollable());
  return realUiGuideAnchorRegistry.rectFor(anchorId, root: viewport);
}

/// Scrolls with real user drags until the anchor really sits in the viewport.
Future<void> _scrollUntilAnchorVisible(
    WidgetTester tester, String anchorId) async {
  final viewport = tester.renderObject<RenderBox>(_confirmScrollable());
  for (var attempt = 0; attempt < 16; attempt++) {
    final rect = _anchorRect(tester, anchorId);
    // Only stop once the anchor is really inside the list viewport and clear
    // of the guide banner; a registered but off-screen anchor keeps dragging.
    final visible = rect != null &&
        rect.height > 0 &&
        rect.top >= 150 &&
        rect.bottom <= viewport.size.height - 8;
    if (visible) return;
    await _userScrollDown(tester, distance: rect == null ? 260 : 90, steps: 4);
  }
}

/// The dim layer is only painted when the overlay really has a hole, so its
/// presence proves that a cut-out was produced.
bool _guideDimPainted(WidgetTester tester) => find
    .byWidgetPredicate((widget) =>
        widget is ColoredBox && widget.color == const Color(0x55000000))
    .evaluate()
    .isNotEmpty;

/// The current scroll offset of the real list.
double _confirmScrollOffset(WidgetTester tester) =>
    tester
        .widget<SingleChildScrollView>(_confirmScrollable())
        .controller
        ?.offset ??
    0;
