import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/region_settings.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  setUp(() {
    PlanFlowRegionController.instance.reset();
  });

  testWidgets(
    'ConfirmScreen shows a smart preparation card from both add buttons',
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
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('설명 · 준비물'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('스마트 준비 알람 1'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(TextButton, '추가'));
      await tester.tap(find.widgetWithText(TextButton, '추가'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('스마트 준비 알람 2'), findsOneWidget);
    },
  );

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
      for (
        var i = 0;
        i < 30 &&
            (notifications.criticalAlarmTitles.isEmpty ||
                backend.reminderPayloads
                    .where((row) => row['type'] == 'system_alarm')
                    .isEmpty);
        i += 1
      ) {
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
        Duration.zero,
      );
    },
  );

  testWidgets('ConfirmScreen surfaces local reminder scheduling failures', (
    tester,
  ) async {
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
    for (
      var i = 0;
      i < 40 &&
          find.text('일정은 저장했지만 알림 권한이 꺼져 있어 알람을 예약하지 못했어요.').evaluate().isEmpty;
      i += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(notifications.eventReminderTitles, contains('성남 출발'));
    expect(find.text('일정은 저장했지만 알림 권한이 꺼져 있어 알람을 예약하지 못했어요.'), findsOneWidget);
  });

  testWidgets('ConfirmScreen saves parsed participants and targets', (
    tester,
  ) async {
    final repository = _FakeEventRepository();

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            participants: const <String>['팀장님'],
            targets: const <String>['김대리'],
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

    expect(find.text('참석자 · 대상'), findsOneWidget);
    expect(find.text('팀장님'), findsOneWidget);
    expect(find.text('김대리'), findsOneWidget);

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.createdEvents, hasLength(1));
    expect(repository.createdEvents.single.participants, <String>['팀장님']);
    expect(repository.createdEvents.single.targets, <String>['김대리']);
  });

  testWidgets('ConfirmScreen preserves parsed recurrence when saving', (
    tester,
  ) async {
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

  testWidgets('ConfirmScreen save leaves voice stack for calendar tab', (
    tester,
  ) async {
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
    'ConfirmScreen shows login guidance when save session is missing',
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
    },
  );

  testWidgets('ConfirmScreen warns before saving overlapping events', (
    tester,
  ) async {
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

  testWidgets(
    'ConfirmScreen opens location picker even when location is empty',
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
      for (
        var i = 0;
        i < 20 && find.text('지도에서 장소 선택').evaluate().isEmpty;
        i += 1
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('지도에서 장소 선택'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('location-search-field')),
        findsOneWidget,
      );
      expect(find.text('검색'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('ConfirmScreen auto-resolves parsed voice location coordinates', (
    tester,
  ) async {
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

  testWidgets('ConfirmScreen keeps empty details section collapsed', (
    tester,
  ) async {
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

  testWidgets('ConfirmScreen keeps details collapsed for memo-only parses', (
    tester,
  ) async {
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

  testWidgets('ConfirmScreen waits for location coordinates before saving', (
    tester,
  ) async {
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

    expect(repository.createdEvents, isEmpty);

    await tester.pump(const Duration(milliseconds: 300));

    final saved = repository.createdEvents.single;
    expect(saved.location, '원주세브란스기독병원');
    expect(saved.locationLat, 37.3495);
    expect(saved.locationLng, 127.9458);
  });

  testWidgets('ConfirmScreen does not auto-resolve personal place aliases', (
    tester,
  ) async {
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
    expect(tester.widget<TextFormField>(locationField).controller?.text, '원주집');

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    await tester.pump(const Duration(milliseconds: 200));

    final saved = repository.createdEvents.single;
    expect(saved.location, '원주집');
    expect(saved.locationLat, isNull);
    expect(saved.locationLng, isNull);
  });

  testWidgets(
    'ConfirmScreen keeps user-edited fields while hydrating and does not seed memo from raw text',
    (tester) async {
      final parseCompleter = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        _testApp(
          ConfirmScreen(
            userId: 'user-1',
            parsedSchedule:
                _parsedSchedule(
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

      await tester.ensureVisible(find.text('설명 · 준비물'));
      await tester.tap(find.text('설명 · 준비물'));
      await tester.pump(const Duration(milliseconds: 250));

      final titleField = _textFieldWithLabel('제목');
      final locationField = _textFieldWithLabel('장소');
      final memoField = _textFieldWithLabel('설명');

      expect(tester.widget<TextFormField>(memoField).controller?.text, isEmpty);

      await tester.enterText(titleField, '사용자 제목');
      await tester.enterText(memoField, '사용자 메모');
      await tester.pump();

      parseCompleter.complete(<String, dynamic>{
        'title': 'AI 제목',
        'location': 'AI 장소',
        'memo': 'AI 메모',
        'start_at': DateTime(2026, 5, 11, 9).toIso8601String(),
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      });
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        tester.widget<TextFormField>(titleField).controller?.text,
        '사용자 제목',
      );
      expect(
        tester.widget<TextFormField>(locationField).controller?.text,
        'AI 장소',
      );
      expect(
        tester.widget<TextFormField>(memoField).controller?.text,
        '사용자 메모',
      );
      expect(find.text('AI 제목'), findsNothing);
      expect(find.text('AI 메모'), findsNothing);
    },
  );

  testWidgets('ConfirmScreen stores Korean wall time as UTC once', (
    tester,
  ) async {
    final repository = _FakeEventRepository();
    // 2030년 고정 날짜 사용: _safeStartAt의 "과거 1일 이전이면 now로 교체" 로직에 걸리지 않도록
    // KST(Asia/Seoul) 10:00 → UTC 01:00 변환 검증
    final start = DateTime(2030, 6, 13, 10);
    final end = DateTime(2030, 6, 14, 9);

    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(startAt: start, endAt: end),
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
    expect(saved.startAt, DateTime.utc(2030, 6, 13, 1));
    expect(planflowLocal(saved.startAt!), start);
    expect(planflowLocal(saved.endAt!), end);
    expect(saved.isMultiDay, isTrue);
  });

  testWidgets('ConfirmScreen lets users choose PM for ambiguous evening time', (
    tester,
  ) async {
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

    expect(find.text('오전/오후를 확인해 주세요'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '오후 7:40'));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('일정 저장'));
    await tester.tap(find.text('일정 저장'));
    for (var i = 0; i < 30 && repository.createdEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = repository.createdEvents.single;
    expect(planflowLocal(saved.startAt!), DateTime(2030, 6, 13, 19, 40));
  });

  testWidgets('ConfirmScreen shows supplies as compact editable rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(supplies: const <String>['물', '충전기']),
          backend: _FakeConfirmBackend(),
          eventRepository: _FakeEventRepository(),
          notificationService: _FakeNotificationService(),
          homeWidgetService: _FakeHomeWidgetService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('설명 · 준비물'));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('물'));

    expect(find.text('물'), findsOneWidget);
    expect(find.text('충전기'), findsOneWidget);
    expect(find.textContaining('체크리스트로'), findsNothing);
    expect(find.text('진행 중'), findsNothing);
  });
  testWidgets('ConfirmScreen asks purpose for ambiguous hospital place only', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        ConfirmScreen(
          userId: 'user-1',
          parsedSchedule: _parsedSchedule(
            title: '병원',
            location: '병원',
            rawText: '내일 오전 10시 병원',
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

    await tester.ensureVisible(find.text('일정 목적을 선택해 주세요'));

    expect(find.text('일정 목적을 선택해 주세요'), findsOneWidget);
    expect(find.text('진료/검사'), findsOneWidget);
    expect(find.text('업무/영업'), findsOneWidget);
    expect(find.text('병문안'), findsOneWidget);

    await tester.tap(find.text('병문안'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('꽃이나 선물 챙기기'), findsOneWidget);
    expect(find.text('병원 준비사항 확인'), findsNothing);
    expect(find.text('금식/복약 안내 확인'), findsNothing);
  });
}

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
      GoRoute(path: AppRoutes.confirm, builder: (_, __) => confirmScreen),
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
  List<String> participants = const <String>[],
  List<String> targets = const <String>[],
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
    'participants': participants,
    'targets': targets,
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
    await Future<void>.delayed(const Duration(milliseconds: 200));
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
    return createdEvents
        .where((event) {
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
        })
        .toList(growable: false);
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
      participants: event.participants,
      targets: event.targets,
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
