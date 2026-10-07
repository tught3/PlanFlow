import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/event_edit_route_payload.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/screens/voice/voice_action_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';

int _alignedFutureFixtureYear() {
  for (var year = DateTime.now().year + 1; ; year++) {
    if (DateTime(year, 1, 1).weekday == DateTime.thursday &&
        !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) {
      return year;
    }
  }
}

final int _voiceFixtureYear = _alignedFutureFixtureYear();

void main() {
  // 자동 저장 테스트 공통 하니스: 수정 액션 + 캘린더 이동 목적지.
  Widget buildEditAutoApplyHarness({
    required _FakeEventRepository repository,
    required String rawText,
    _FakeGroupEventRepository? groupEventRepository,
    ManualEventSideEffectService? sideEffectService,
    Future<DateTime?> Function(String userId, String eventId)?
        reminderNotifyAtReader,
  }) {
    return MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: AppRoutes.voiceAction,
        routes: [
          GoRoute(
            path: AppRoutes.voiceAction,
            builder: (context, state) => VoiceActionScreen(
              rawText: rawText,
              action: VoiceScheduleAction.edit,
              eventRepository: repository,
              groupEventRepository:
                  groupEventRepository ?? _FakeGroupEventRepository(const []),
              userIdOverride: 'user-1',
              sideEffectService:
                  sideEffectService ?? const _NoopSideEffectService(),
              homeWidgetService: _NoopHomeWidgetService(),
              locationLookupService: _FakeLocationLookupService.empty(),
              reminderNotifyAtReader: reminderNotifyAtReader ??
                  (userId, eventId) => _defaultKnownReminderReader(repository),
            ),
          ),
          GoRoute(
            path: AppRoutes.calendar,
            builder: (context, state) => const Text(
              '일정 탭',
              textDirection: TextDirection.ltr,
            ),
          ),
        ],
      ),
    );
  }

  EventModel minutePrecisionFutureEvent() {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).add(const Duration(days: 3));
    return _event(
      id: 'event-1',
      title: '팀 회의',
      startAt: start,
      endAt: start.add(const Duration(hours: 1)),
    );
  }

  testWidgets('"다음 주로 바꿔줘" 단일 후보는 자동 저장돼 +7일 UTC 시작/종료가 저장된다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    expect(
      repository.updatedEvents.single.startAt,
      planflowLocalDateTimeToUtc(
        planflowLocal(original.startAt!).add(const Duration(days: 7)),
      ),
    );
    expect(
      repository.updatedEvents.single.endAt,
      planflowLocalDateTimeToUtc(
        planflowLocal(original.endAt!).add(const Duration(days: 7)),
      ),
    );
  });

  testWidgets('"그다음주"는 다다음주가 아니라 +7일로 자동 저장된다(이전 +14 오판 정정)', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 그다음주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    expect(
      repository.updatedEvents.single.startAt,
      planflowLocalDateTimeToUtc(
        planflowLocal(original.startAt!).add(const Duration(days: 7)),
      ),
    );
  });

  testWidgets('"다다음주"는 +14일로 자동 저장된다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다다음주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    expect(
      repository.updatedEvents.single.startAt,
      planflowLocalDateTimeToUtc(
        planflowLocal(original.startAt!).add(const Duration(days: 14)),
      ),
    );
  });

  testWidgets('STT 띄어쓰기가 섞인 "그 다음 주"도 +7일로 자동 저장된다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 그 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    expect(
      repository.updatedEvents.single.startAt,
      planflowLocalDateTimeToUtc(
        planflowLocal(original.startAt!).add(const Duration(days: 7)),
      ),
    );
  });

  testWidgets('자동 저장은 강한 알람·준비물 메타데이터를 유지하고 길이를 보존해 리마인더 기준을 옮긴다',
      (tester) async {
    final originalStart = planflowLocal(minutePrecisionFutureEvent().startAt!);
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀 회의',
          startAt: originalStart,
          endAt: originalStart.add(const Duration(hours: 1)),
          useStrongAlarm: true,
          supplies: const ['물', '텐트'],
          suppliesChecked: const ['물'],
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    expect(saved.useStrongAlarm, isTrue);
    expect(saved.supplies, ['물', '텐트']);
    expect(saved.suppliesChecked, ['물']);
    expect(saved.id, 'event-1');
    // 시작-종료 길이가 보존되므로(시작 30분 전 리마인더 등) 기존 알람 오프셋이
    // 새 시작 시각 기준으로 재계산된다(후속 작업이 previousStartAt으로 재동기화).
    expect(
      planflowLocal(saved.endAt!).difference(planflowLocal(saved.startAt!)),
      const Duration(hours: 1),
    );
  });

  testWidgets('자동 저장(+7일)은 기존 30분 전 리마인더 오프셋을 새 시작에 그대로 적용한다', (tester) async {
    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.markSupabaseInitializationFailed);

    final originalStart = planflowLocal(minutePrecisionFutureEvent().startAt!);
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀 회의',
          startAt: originalStart,
          endAt: originalStart.add(const Duration(hours: 1)),
          useStrongAlarm: true,
          supplies: const ['물'],
          suppliesChecked: const ['물'],
        ),
      ],
    );
    final sideEffectService = _ReminderRecordingSideEffectService();
    // 기존 리마인더: 이전 시작 30분 전 notify_at(같은 시점 도메인).
    final oldNotifyAt = originalStart.subtract(const Duration(minutes: 30));

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
        sideEffectService: sideEffectService,
        reminderNotifyAtReader: (userId, eventId) async => oldNotifyAt,
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    expect(saved.useStrongAlarm, isTrue);
    expect(saved.supplies, ['물']);
    expect(saved.suppliesChecked, ['물']);
    expect(
      planflowLocal(saved.endAt!).difference(planflowLocal(saved.startAt!)),
      const Duration(hours: 1),
    );
    // 후속 syncAfterSave는 백그라운드에서 실행되므로 기록을 기다린다.
    var waited = 0;
    while (sideEffectService.lastReminderOffset == null && waited < 80) {
      await tester.pump(const Duration(milliseconds: 25));
      waited++;
    }
    // 이전 시작-이전 notify_at 역산(30분)이 그대로 전달된다. 새 시작으로
    // 역산하면 +7일(10080분)이 섞여 기본값(60분)으로 왜곡된다.
    expect(
      sideEffectService.lastReminderOffset,
      const Duration(minutes: 30),
    );
    expect(
      sideEffectService.lastCriticalAlarmOffset,
      const Duration(minutes: 30),
    );
    // 실제 리마인더 payload도 새 시작(+7일)의 30분 전으로 계산된다.
    expect(sideEffectService.reminderPayloads, hasLength(1));
    expect(sideEffectService.reminderPayloads.single['type'], 'push');
    expect(
      DateTime.parse(
        sideEffectService.reminderPayloads.single['notify_at'].toString(),
      ).isAtSameMomentAs(
        saved.startAt!.subtract(const Duration(minutes: 30)),
      ),
      isTrue,
    );
  });

  testWidgets('명시 날짜(N월 N일) 단일 후보는 자동 저장돼 요청한 날짜가 그대로 저장된다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);
    // 연도를 하드코딩하지 않는다: 요청 날짜는 현재 기준 미래(20일 뒤)로
    // 계산하고 파서가 다음 등장 연도로 해석한다.
    final targetDay = DateTime.now().add(const Duration(days: 20));
    final originalStartLocal = planflowLocal(original.startAt!);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 ${targetDay.month}월 ${targetDay.day}일로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    // 자동 저장 성공: 편집 화면을 열지 않고 캘린더로 이동하며, 저장소 payload에는
    // 요청한 날짜(시각은 기존 시작 시각 유지)가 들어간다.
    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    expect(
      saved.startAt,
      planflowLocalDateTimeToUtc(
        DateTime(
          targetDay.year,
          targetDay.month,
          targetDay.day,
          originalStartLocal.hour,
          originalStartLocal.minute,
        ),
      ),
    );
    // 종료 시각도 같이 옮겨져 일정 길이(1시간)가 보존된다.
    expect(
      planflowLocal(saved.endAt!).difference(planflowLocal(saved.startAt!)),
      const Duration(hours: 1),
    );
  });

  testWidgets('명시 날짜 자동 저장도 기존 30분 전 리마인더 오프셋을 유지한다', (tester) async {
    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.markSupabaseInitializationFailed);

    final original = minutePrecisionFutureEvent();
    final originalStartLocal = planflowLocal(original.startAt!);
    final repository = _FakeEventRepository(events: [original]);
    final sideEffectService = _ReminderRecordingSideEffectService();
    final targetDay = DateTime.now().add(const Duration(days: 20));

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 ${targetDay.month}월 ${targetDay.day}일로 바꿔줘',
        sideEffectService: sideEffectService,
        reminderNotifyAtReader: (userId, eventId) async =>
            originalStartLocal.subtract(const Duration(minutes: 30)),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, hasLength(1));
    var waited = 0;
    while (sideEffectService.lastReminderOffset == null && waited < 80) {
      await tester.pump(const Duration(milliseconds: 25));
      waited++;
    }
    expect(
      sideEffectService.lastReminderOffset,
      const Duration(minutes: 30),
    );
    expect(
      DateTime.parse(
        sideEffectService.reminderPayloads.single['notify_at'].toString(),
      ).isAtSameMomentAs(
        repository.updatedEvents.single.startAt!
            .subtract(const Duration(minutes: 30)),
      ),
      isTrue,
    );
  });

  testWidgets('알림이 꺼진(행 없음) 일정의 날짜 자동 저장은 알림을 재생성하지 않는다', (tester) async {
    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.markSupabaseInitializationFailed);

    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);
    final sideEffectService = _ReminderRecordingSideEffectService();

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
        sideEffectService: sideEffectService,
        // 알림 행이 없음 = 꺼짐(편집 화면 row==null → offset null 규칙과 동일).
        reminderNotifyAtReader: (userId, eventId) async => null,
      ),
    );
    await tester.pumpAndSettle();

    // 날짜 이동 자체는 저장되되,
    expect(repository.updatedEvents, hasLength(1));
    var waited = 0;
    while (sideEffectService.syncAfterSaveCalls == 0 && waited < 80) {
      await tester.pump(const Duration(milliseconds: 25));
      waited++;
    }
    // 알림은 계속 꺼져 있다: 기본 60분으로 재생성하지 않는다.
    expect(sideEffectService.syncAfterSaveCalls, 1);
    expect(sideEffectService.lastReminderOffset, isNull);
    expect(sideEffectService.lastCriticalAlarmOffset, isNull);
    expect(sideEffectService.reminderPayloads, isEmpty);
  });

  testWidgets('리마인더 상태를 읽지 못하면 날짜 자동 저장 자체를 하지 않는다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
        // 읽기 오류 = 불명: 기본값으로 몰래 재예약하지 않고 자동 저장 중단.
        reminderNotifyAtReader: (userId, eventId) async =>
            throw StateError('reminders unavailable'),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('강한 알림(critical) 일정은 system_alarm 30분 오프셋을 유지해 자동 저장된다',
      (tester) async {
    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.markSupabaseInitializationFailed);

    final originalStart = planflowLocal(minutePrecisionFutureEvent().startAt!);
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀 회의',
          startAt: originalStart,
          endAt: originalStart.add(const Duration(hours: 1)),
          isCritical: true,
          useStrongAlarm: true,
        ),
      ],
    );
    final sideEffectService = _ReminderRecordingSideEffectService();

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
        sideEffectService: sideEffectService,
        // critical은 system_alarm 행 기준: 이전 시작 30분 전.
        reminderNotifyAtReader: (userId, eventId) async =>
            originalStart.subtract(const Duration(minutes: 30)),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    var waited = 0;
    while (sideEffectService.syncAfterSaveCalls == 0 && waited < 80) {
      await tester.pump(const Duration(milliseconds: 25));
      waited++;
    }
    expect(
        sideEffectService.lastCriticalAlarmOffset, const Duration(minutes: 30));
    expect(sideEffectService.lastReminderOffset, const Duration(minutes: 30));
    // 실제 payload는 system_alarm 한 건, 새 시작(+7일)의 30분 전.
    expect(sideEffectService.reminderPayloads, hasLength(1));
    expect(sideEffectService.reminderPayloads.single['type'], 'system_alarm');
    expect(
      DateTime.parse(
        sideEffectService.reminderPayloads.single['notify_at'].toString(),
      ).isAtSameMomentAs(
        saved.startAt!.subtract(const Duration(minutes: 30)),
      ),
      isTrue,
    );
  });

  testWidgets('편집 화면 extra는 DTO로 초안·원본·선택 회차를 함께 전달한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12, 10),
          endAt: DateTime(_voiceFixtureYear, 5, 12, 11),
        ),
      ],
    );
    EventEditRoutePayload? captured;
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '에버랜드 일정 6월 3일로 옮겨줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupEventRepository: _FakeGroupEventRepository(const []),
            userIdOverride: 'user-1',
            // 리마인더 불명 → 자동 저장 중단 → 수동 편집 경로 검증.
            reminderNotifyAtReader: (userId, eventId) async =>
                throw StateError('reminders unavailable'),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            captured = state.extra as EventEditRoutePayload;
            return const SizedBox();
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    // 초안(draft)은 요청한 날짜(시각은 기존 유지)로 옮겨져 있다.
    final draftStart = planflowLocal(captured!.draft.startAt!);
    expect(draftStart.year, _voiceFixtureYear);
    expect(draftStart.month, 6);
    expect(draftStart.day, 3);
    expect(draftStart.hour, 10);
    // 원본(original)은 이동 전 저장 행 그대로.
    final originalStart = planflowLocal(captured!.original.startAt!);
    expect(originalStart.month, 5);
    expect(originalStart.day, 12);
    expect(originalStart.hour, 10);
    // 선택 회차(이동 전 시작)는 원본 행 시작과 같지만 별도 필드로 전달된다.
    expect(
      captured!.originalOccurrenceStartAt!
          .isAtSameMomentAs(captured!.original.startAt!),
      isTrue,
    );
  });

  testWidgets('시간만 바꾸는 발화도 파싱이 명확하면 자동 저장된다', (tester) async {
    // 기존 시작 시각과 요청 시각(오후 3시)이 우연히 같아지는 플레이크를 막기
    // 위해 고정 픽스처(09:30)를 쓴다.
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀 회의',
          startAt: DateTime(_voiceFixtureYear, 5, 12, 9, 30),
          endAt: DateTime(_voiceFixtureYear, 5, 12, 10, 30),
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 오후 3시로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    // 날짜는 그대로 두고 시각만 15:00으로 옮긴다.
    expect(
      saved.startAt,
      planflowLocalDateTimeToUtc(DateTime(_voiceFixtureYear, 5, 12, 15)),
    );
    expect(
      planflowLocal(saved.endAt!).difference(planflowLocal(saved.startAt!)),
      const Duration(hours: 1),
    );
  });

  testWidgets('요일 지정(금요일)도 모호함이 없으면 자동 저장된다', (tester) async {
    // 2026-05-12(화) 고정 픽스처: 편집 화면 미리채움 테스트와 동일 조건이라
    // '금요일'이 이벤트 기준 주의 금요일(05-15)로 확정 해석됨을 보장한다.
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12, 10),
          endAt: DateTime(_voiceFixtureYear, 5, 12, 11),
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '화요일 에버랜드 일정을 금요일로 옮겨줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    final saved = repository.updatedEvents.single;
    expect(
      saved.startAt,
      planflowLocalDateTimeToUtc(DateTime(_voiceFixtureYear, 5, 15, 10)),
    );
    expect(
      planflowLocal(saved.endAt!).difference(planflowLocal(saved.startAt!)),
      const Duration(hours: 1),
    );
  });

  testWidgets('후보가 여러 개면 자동 저장하지 않는다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(
      events: [
        original,
        _event(
          id: 'event-2',
          title: '팀 회의 자료 정리',
          startAt: original.startAt!.add(const Duration(days: 1)),
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
  });

  testWidgets('반복 일정은 자동 저장하지 않고 수동 흐름을 유지한다', (tester) async {
    final originalStart = planflowLocal(minutePrecisionFutureEvent().startAt!);
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀 회의',
          startAt: originalStart,
          recurrenceRule: 'FREQ=WEEKLY',
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('자동 저장 전 겹침 경고에서 중단하면 저장하지 않는다', (tester) async {
    final original = minutePrecisionFutureEvent();
    // 자동 저장 대상(드래프트)은 +7일 뒤로 옮겨진 시작 시각을 가지므로,
    // 경고 대상 겹침 일정도 같은 새 시작 시각(같은 시간창)이어야 한다.
    final newStartLocal =
        planflowLocal(original.startAt!).add(const Duration(days: 7));
    final repository = _OverlappingFakeEventRepository(
      events: [original],
      overlappingEvents: [
        _event(
          id: 'event-9',
          title: '겹치는 기존 일정',
          startAt: newStartLocal,
          endAt: newStartLocal.add(const Duration(hours: 1)),
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정이 겹쳐요'), findsOneWidget);
    await tester.tap(find.text('중단'));
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('명시 날짜 자동 저장 전 겹침 경고에서 중단하면 제안 날짜 미리보기를 유지한다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final originalStartLocal = planflowLocal(original.startAt!);
    final targetDay = DateTime.now().add(const Duration(days: 20));
    final newStartLocal = DateTime(
      targetDay.year,
      targetDay.month,
      targetDay.day,
      originalStartLocal.hour,
      originalStartLocal.minute,
    );
    final repository = _OverlappingFakeEventRepository(
      events: [original],
      overlappingEvents: [
        _event(
          id: 'event-9',
          title: '겹치는 기존 일정',
          startAt: newStartLocal,
          endAt: newStartLocal.add(const Duration(hours: 1)),
        ),
      ],
    );

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 ${targetDay.month}월 ${targetDay.day}일로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('일정이 겹쳐요'), findsOneWidget);
    await tester.tap(find.text('중단'));
    await tester.pumpAndSettle();

    // 취소하면 저장하지 않고, 제안한 명시 날짜가 담긴 카드를 유지해 수동
    // 저장/편집 경로를 그대로 쓰게 한다.
    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('바로 저장'), findsOneWidget);
    expect(
      find.textContaining('${targetDay.month}월 ${targetDay.day}일'),
      findsOneWidget,
    );
  });

  testWidgets('자동 저장이 저장소 오류로 실패하면 이동하지 않고 카드를 유지한다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FailingSaveFakeEventRepository(events: [original]);

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('팀 회의'), findsOneWidget);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('명시 날짜 자동 저장이 저장소 오류로 실패하면 카드를 유지한다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FailingSaveFakeEventRepository(events: [original]);
    final targetDay = DateTime.now().add(const Duration(days: 20));

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        rawText: '팀 회의 ${targetDay.month}월 ${targetDay.day}일로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('팀 회의'), findsOneWidget);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('그룹과 공유 중인 일정은 자동 저장하지 않는다', (tester) async {
    final original = minutePrecisionFutureEvent();
    final repository = _FakeEventRepository(events: [original]);
    final groupEventRepository = _FakeGroupEventRepository([
      _groupEvent(id: 'group-event-1', groupId: 'group-1', title: '공유 복사본'),
    ])
      ..groupShareLinkCheckReturnsShare = true;

    await tester.pumpWidget(
      buildEditAutoApplyHarness(
        repository: repository,
        groupEventRepository: groupEventRepository,
        rawText: '팀 회의 다음 주로 바꿔줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsNothing);
    expect(find.text('바로 저장'), findsOneWidget);
  });

  testWidgets('관리 선택 화면의 추가 버튼은 일정 확인 화면으로 바로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '5월 5일 한강 피크닉 10시에 추가해줘',
            action: VoiceScheduleAction.choose,
            eventRepository: _FakeEventRepository(events: const []),
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('추가'));
    await tester.pumpAndSettle();

    expect(find.text('일정 확인 화면'), findsOneWidget);
  });

  testWidgets('관리 선택 화면의 수정/조회 버튼은 후보 영역을 즉시 갱신한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '한강 피크닉'),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 어떻게 할까',
            action: VoiceScheduleAction.choose,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('수정하기'), findsOneWidget);

    await tester.tap(find.text('조회'));
    await tester.pumpAndSettle();

    expect(find.text('단순 조회 결과'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('상세 보기'), 120);
    expect(find.text('상세 보기'), findsOneWidget);
  });

  testWidgets('오늘 일정 조회는 오늘 일정만 요약해서 보여준다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'today-1',
          title: '공임나라 방문',
          startAt: DateTime(now.year, now.month, now.day, 11),
          location: '원주',
        ),
        _event(
          id: 'tomorrow-1',
          title: '내일 미팅',
          startAt: DateTime(now.year, now.month, now.day + 1, 9),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 일정 알려줘',
            action: VoiceScheduleAction.query,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 요약'), findsOneWidget);
    expect(find.textContaining('오늘 일정은 1개입니다'), findsOneWidget);
    expect(find.text('공임나라 방문'), findsOneWidget);
    expect(find.textContaining('오전'), findsWidgets);
    expect(find.textContaining('11시'), findsWidgets);
    expect(find.text('내일 미팅'), findsNothing);
  });

  testWidgets('제목 검색은 정확 일치 후보만 우선 보여주고 약한 유사 후보는 숨긴다', (
    tester,
  ) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'exact',
          title: '김창민 만나기',
          startAt: DateTime(_voiceFixtureYear, 7, 19, 9),
        ),
        _event(
          id: 'weak-1',
          title: '정윤태 만나기',
          startAt: DateTime(_voiceFixtureYear, 4, 16, 11),
        ),
        _event(
          id: 'weak-2',
          title: '강릉아산병원 약제팀장 만나기',
          startAt: DateTime(_voiceFixtureYear, 5, 28, 10),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '김창민 만나기라는 일정 찾아봐',
            action: VoiceScheduleAction.query,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('검색어: 김창민 만나기라'), findsNothing);
    expect(find.textContaining('검색어: 김창민 만나기'), findsOneWidget);
    expect(find.text('김창민 만나기'), findsOneWidget);
    expect(find.text('정윤태 만나기'), findsNothing);
    expect(find.text('강릉아산병원 약제팀장 만나기'), findsNothing);
  });

  testWidgets('이번 주 금요일 조회는 주간이 아니라 금요일 하루만 보여준다', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final friday = weekStart.add(const Duration(days: DateTime.friday - 1));
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'monday-1',
          title: '월요일 미팅',
          startAt: weekStart.add(const Duration(hours: 9)),
        ),
        _event(
          id: 'friday-1',
          title: '금요일 방문',
          startAt: friday.add(const Duration(hours: 11)),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '이번주금요일 일정 알려줘',
            action: VoiceScheduleAction.query,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('이번 주 금요일 일정 요약'), findsOneWidget);
    expect(find.textContaining('이번 주 금요일 일정은 1개입니다'), findsOneWidget);
    expect(find.text('금요일 방문'), findsOneWidget);
    expect(find.text('월요일 미팅'), findsNothing);
  });

  testWidgets('오늘 일정 조회 결과가 없으면 자연스러운 안내를 보여준다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'tomorrow-1',
          title: '내일 미팅',
          startAt: DateTime(now.year, now.month, now.day + 1, 9),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 일정 알려줘',
            action: VoiceScheduleAction.query,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => const Text(
            '음성 입력',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('오늘 일정은 아직 없어요'), findsOneWidget);
    expect(find.text('내일 미팅'), findsNothing);
  });

  testWidgets('음성 수정 명령은 후보 일정을 편집 화면으로 연결한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '한강 피크닉'),
        _event(id: 'event-2', title: '치과 방문'),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 수정해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => Text(
            '편집 화면: ${state.pathParameters['eventId']}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('한강 피크닉'), findsOneWidget);
    expect(find.text('치과 방문'), findsNothing);

    await tester.tap(
      find
          .ancestor(
            of: find.text('한강 피크닉'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('편집 화면: event-1'), findsOneWidget);
  });

  testWidgets('수정 후보 검색은 날짜 숫자만 비슷한 다른 일정을 제외한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀장 동행방문',
          startAt: DateTime(_voiceFixtureYear, 5, 13, 10),
        ),
        _event(
          id: 'event-2',
          title: '켄스파크 15일 구독갱신',
          startAt: DateTime(_voiceFixtureYear, 4, 14, 14),
        ),
        _event(
          id: 'event-3',
          title: '방문록 미리 준비',
          startAt: DateTime(_voiceFixtureYear, 5, 21, 15),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '$_voiceFixtureYear년 5월 13일 팀장 동행방문 일정 이번 주 수요일로 변경',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('팀장 동행방문'), findsOneWidget);
    expect(find.text('켄스파크 15일 구독갱신'), findsNothing);
    expect(find.text('방문록 미리 준비'), findsNothing);
  });

  testWidgets('수정 후보 검색은 날짜와 내용 유사도가 함께 맞아야 표시한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀장 동행방문',
          startAt: DateTime(_voiceFixtureYear, 5, 14, 10),
        ),
        _event(
          id: 'event-2',
          title: '구독갱신',
          memo: '결제 확인',
          startAt: DateTime(_voiceFixtureYear, 5, 13, 10),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '5월 13일 팀장 동행방문 일정 수정',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('팀장 동행방문'), findsNothing);
    expect(find.text('구독갱신'), findsNothing);
    expect(find.textContaining('조건에 맞는 일정을 찾지 못했어요'), findsOneWidget);
  });

  testWidgets('수정 바로 저장 성공 후 일정 탭으로 이동한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime.now().add(const Duration(days: 1)),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 모레 오전 9시로 변경',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets('중요 표시 수정은 바로 저장 시 isCritical을 반영한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime.now().add(const Duration(days: 1)),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 중요하게 표시해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('중요 일정'), findsOneWidget);
    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.isCritical, isTrue);
  });

  testWidgets('장소 추가 수정 명령은 시간 변경 없이 편집 화면에 장소만 채운다', (tester) async {
    final originalStart = DateTime.now().add(const Duration(days: 1));
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '교보생명 시험',
          startAt: originalStart,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 오전 10시에 교보생명 시험 일정에 원주 교보생명빌딩으로 장소 추가',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            permissionService: _NoLocationPermissionService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.title}|${event.startAt?.toIso8601String()}|${event.location}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('바로 저장'), findsNothing);
    final firstLocationButton = find.descendant(
      of: find.byKey(const ValueKey('voice-action-candidate-event-1')),
      matching: find.widgetWithText(FilledButton, '장소 입력'),
    );
    await tester.ensureVisible(firstLocationButton);
    await tester.tap(firstLocationButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        '편집 시작: 교보생명 시험|'
        '${originalStart.toIso8601String()}|원주 교보생명빌딩',
      ),
      findsOneWidget,
    );
    expect(repository.updatedEvents, isEmpty);
  });

  testWidgets('일정에 장소 추가 검색어는 일정 식별어와 새 장소를 분리한다', (tester) async {
    final originalStart = DateTime.now().add(const Duration(days: 1));
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '실매출 확인',
          startAt: originalStart,
        ),
        _event(
          id: 'event-2',
          title: '원주 세브란스 기독병원 방문',
          startAt: originalStart,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 오후 1시에 실매출 확인 일정에 원주 세브란스 기독병원 장소 추가해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            locationLookupService: _FakeLocationLookupService.empty(),
            permissionService: _NoLocationPermissionService(),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.title}|${event.startAt?.toIso8601String()}|${event.location}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('실매출 확인'), findsWidgets);
    expect(find.text('원주 세브란스 기독병원 방문'), findsNothing);
    final separatedLocationButton = find.descendant(
      of: find.byKey(const ValueKey('voice-action-candidate-event-1')),
      matching: find.widgetWithText(FilledButton, '장소 입력'),
    );
    await tester.ensureVisible(separatedLocationButton);
    await tester.tap(separatedLocationButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        '편집 시작: 실매출 확인|'
        '${originalStart.toIso8601String()}|원주 세브란스 기독병원',
      ),
      findsOneWidget,
    );
  });

  testWidgets('음성 수정 명령의 새 날짜는 편집 화면에 미리 반영된다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12, 10),
          location: '용인',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '화요일 에버랜드 일정을 금요일로 옮겨줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.startAt?.toIso8601String()}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('-05-15T01:00:00.000'), findsOneWidget);
  });

  testWidgets('음성 수정 시 표기 없는 1~11시는 오후로 기본 해석된다(f3f2b3a1 정책)', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12,
              10), // banned-ok: 기존 통과 테스트(625줄)와 동일한 고정 픽스처 재사용, now() 기반 클램프/만료 로직과 무관
          location: '용인',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '에버랜드 일정을 3시로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.startAt?.toIso8601String()}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // 무표기 3시 -> 오후 3시(KST 15:00) -> UTC 06:00
    expect(find.textContaining('-05-12T06:00:00.000'), findsOneWidget);
  });

  testWidgets('음성 수정 시 표기 없는 12시는 정오로 유지된다(자정 아님)', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12,
              10), // banned-ok: 기존 통과 테스트(625줄)와 동일한 고정 픽스처 재사용, now() 기반 클램프/만료 로직과 무관
          location: '용인',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '에버랜드 일정을 12시로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.startAt?.toIso8601String()}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // 무표기 12시 -> 정오(KST 12:00) 유지 -> UTC 03:00
    expect(find.textContaining('-05-12T03:00:00.000'), findsOneWidget);
  });

  testWidgets('음성 수정 시 오전 3시는 표기가 있으므로 변경 없이 유지된다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12,
              10), // banned-ok: 기존 통과 테스트(625줄)와 동일한 고정 픽스처 재사용, now() 기반 클램프/만료 로직과 무관
          location: '용인',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '에버랜드 일정을 오전 3시로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.startAt?.toIso8601String()}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // 오전 3시(표기 있음, 정책 무관) -> KST 03:00 -> UTC 전날 18:00
    expect(find.textContaining('-05-11T18:00:00.000'), findsOneWidget);
  });

  testWidgets('음성 수정 시 새벽 12시는 기존 정책대로 자정으로 유지된다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '에버랜드',
          startAt: DateTime(_voiceFixtureYear, 5, 12,
              10), // banned-ok: 기존 통과 테스트(625줄)와 동일한 고정 픽스처 재사용, now() 기반 클램프/만료 로직과 무관
          location: '용인',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '에버랜드 일정을 새벽 12시로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              '편집 시작: ${event.startAt?.toIso8601String()}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .ancestor(
            of: find.text('에버랜드'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // 새벽 12시(표기 있음, 기존 자정 유지 로직) -> KST 00:00 -> UTC 전날 15:00
    expect(find.textContaining('-05-11T15:00:00.000'), findsOneWidget);
  });

  testWidgets('음성 수정 후보 검색은 조사 오류와 새 시간 표현을 걷어내고 대상을 찾는다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '서울성남 아이스크림 전달',
          location: '서울성남',
        ),
        _event(id: 'event-2', title: '목요일 오전 회의'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 서울에서 성남에서 아이스크림 전달일정 이번주 목요일 오전9시로 변경',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('서울성남에서 아이스크림 전달일정'), findsOneWidget);
    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('서울성남 아이스크림 전달'), findsOneWidget);
    expect(find.text('목요일 오전 회의'), findsNothing);
    final firstTitle = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (widget) => widget.data == '서울성남 아이스크림 전달',
        );
    expect(firstTitle.data, '서울성남 아이스크림 전달');
  });

  testWidgets('음성 수정 후보 검색은 문장 장식과 새 일정값을 제외하고 대상 일정을 찾는다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '아이스크림 전달',
          location: '강릉아산',
        ),
        _event(id: 'event-2', title: '목요일 오전 회의'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 강릉 아산에서 아이스크림 전달이라고 되어 있는 일정 이번 주 목요일로 바꿔 줘 오전 9시로',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsOneWidget);
    expect(find.text('목요일 오전 회의'), findsNothing);
    final firstTitle = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (widget) => widget.data == '아이스크림 전달' || widget.data == '목요일 오전 회의',
        );
    expect(firstTitle.data, '아이스크림 전달');
  });

  testWidgets('음성 수정 후보 검색은 한 음절 STT 오인식도 후보 문맥으로 보정한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '아이스크림 전달',
          location: '강릉아산',
        ),
        _event(id: 'event-2', title: '목요일 오전 회의'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 강릉하산에서 아이스크림 전달 일정 이번 주 목요일 오전 9시로 변경',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsOneWidget);
    expect(find.text('목요일 오전 회의'), findsNothing);
    final firstTitle = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (widget) => widget.data == '아이스크림 전달' || widget.data == '목요일 오전 회의',
        );
    expect(firstTitle.data, '아이스크림 전달');
  });

  testWidgets('내일 팀장님 동행방문 다음 주 수요일로 연기는 수정 후보를 표시한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '팀장님 동행방문',
          location: '본사',
          startAt: DateTime(_voiceFixtureYear, 5, 13, 11),
        ),
        _event(
          id: 'event-2',
          title: '아이스크림 전달',
          location: '강릉아산',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 팀장님 동행방문 다음 주 수요일로 연기',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('팀장님 동행방문'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsNothing);
    final firstTitle = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (widget) => widget.data == '팀장님 동행방문' || widget.data == '아이스크림 전달',
        );
    expect(firstTitle.data, '팀장님 동행방문');
  });

  testWidgets('수정 명령이 정확히 매칭되지 않아도 대상 후보를 비워두지 않는다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '아이스크림 전달',
          location: '강릉아산',
          startAt: DateTime.now().add(const Duration(days: 1)),
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '잘못 알아들은 문장 이번 주 목요일 오전 9시로 바꿔 줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsOneWidget);
    expect(find.textContaining('조건에 맞는 일정을 찾지 못했어요'), findsNothing);
  });

  testWidgets('오늘 삭제 후보는 날짜 힌트 범위 내 항목을 take 제한 없이 보여준다', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    final repository = _FakeEventRepository(
      events: [
        for (var index = 0; index < 7; index += 1)
          _event(
            id: 'today-$index',
            title: '오늘일정$index',
            startAt: today.add(Duration(hours: index + 7)),
          ),
        for (var index = 0; index < 3; index += 1)
          _event(
            id: 'tomorrow-$index',
            title: '내일일정$index',
            startAt: today
                .add(const Duration(days: 1))
                .add(Duration(hours: index + 7)),
          ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 회의 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    debugPrint = previousDebugPrint;

    expect(
      logs.any((line) => line.contains('displayedCount=7')),
      isTrue,
    );
    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('오늘일정0'), findsWidgets);
    expect(find.text('내일일정0'), findsNothing);
    expect(find.text('내일일정1'), findsNothing);
  });

  testWidgets('날짜 힌트가 있지만 범위 외 관련 없는 일정은 제한된 수만 표시한다', (tester) async {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final repository = _FakeEventRepository(
      events: [
        for (var index = 0; index < 5; index += 1)
          _event(
            id: 'future-$index',
            title: '다음일정$index',
            startAt: tomorrow.add(Duration(hours: index + 8)),
          ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('다음일정0'), findsWidgets);
    expect(find.text('다음일정1'), findsWidgets);
    expect(find.text('다음일정2'), findsWidgets);
    expect(find.text('다음일정3'), findsNothing);
    expect(find.text('다음일정4'), findsNothing);
  });

  testWidgets('수정 후보 fallback은 다가오는 일정과 최근 일정을 우선으로 보여준다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-past',
          title: '지난 회의',
          startAt: now.subtract(const Duration(days: 2)),
        ),
        _event(
          id: 'event-future',
          title: '내일 회의',
          startAt: now.add(const Duration(days: 1)),
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '아무 말이나 했지만 일정을 바꿔 줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('내일 회의'), findsOneWidget);
    expect(find.text('지난 회의'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('내일 회의')).dy <
          tester.getTopLeft(find.text('지난 회의')).dy,
      isTrue,
    );
  });

  testWidgets('후보 조회 로그는 필요한 카운트와 대상 검색어를 남긴다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime.now().add(const Duration(days: 1)),
        ),
        _event(
          id: 'event-2',
          title: '치과 방문',
          startAt: DateTime.now().add(const Duration(days: 2)),
        ),
      ],
    );
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 수정해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    debugPrint = previousDebugPrint;

    expect(
      logs.any(
        (line) =>
            line.contains('VoiceActionScreen candidate load: action=edit') &&
            line.contains('userId=있음') &&
            line.contains('totalEventCount=2') &&
            line.contains('filteredCount=2') &&
            line.contains('displayedCount=1') &&
            line.contains('targetQuery='),
      ),
      isTrue,
    );
  });

  testWidgets('음성 삭제 명령은 확인 후 일정을 삭제하고 일정 탭으로 이동한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '한강 피크닉'),
        _event(id: 'event-2', title: '치과 방문'),
      ],
    );
    final sideEffects = _RecordingSideEffectService();

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 삭제해줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            sideEffectService: sideEffects,
            homeWidgetService: _NoopHomeWidgetService(),
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('voice-delete-inline-button-0-event-1')),
    );
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('voice-confirm-delete-event-1')));
    await tester.pumpAndSettle();

    expect(repository.deletedEventIds, ['event-1']);
    expect(sideEffects.cleanedUpEventIds, ['event-1']);
    expect(sideEffects.cleanedUpUserIds, ['user-1']);
    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets('삭제 후보는 여러 개를 선택해 선택된 일정만 한 번에 삭제한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '한강 피크닉'),
        _event(id: 'event-2', title: '치과 방문'),
        _event(id: 'event-3', title: '마트 장보기'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '일정 삭제해줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('선택된 일정 0개'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-actions')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-button-0-event-1')),
        findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    final firstCheckbox = find.descendant(
      of: find.byKey(const ValueKey('voice-delete-candidate-0-event-1')),
      matching: find.byType(Checkbox),
    );
    final secondCheckbox = find.descendant(
      of: find.byKey(const ValueKey('voice-delete-candidate-1-event-2')),
      matching: find.byType(Checkbox),
    );

    await tester.ensureVisible(firstCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(firstCheckbox);
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pumpAndSettle();

    expect(find.text('선택된 일정 2개'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('voice-delete-selected-inline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('voice-confirm-selected-delete')),
    );
    await tester.pumpAndSettle();

    expect(repository.deletedEventIds, ['event-1', 'event-2']);
    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets('삭제 후보 2개 진단이 보이면 후보 카드와 개별 삭제 버튼도 렌더링된다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '한강 피크닉'),
        _event(id: 'event-2', title: '치과 방문'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '일정 삭제해줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-target-events-section')),
        findsOneWidget);
    expect(find.textContaining('2개 후보'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-candidate-list')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-actions')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-button-0-event-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-button-1-event-2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-inline-instruction')),
        findsOneWidget);
    expect(find.text('선택된 일정 0개'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-candidate-0-event-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-candidate-1-event-2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-button-0-event-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-button-1-event-2')),
        findsOneWidget);
    expect(find.text('저장된 일정이 앱 DB에서 보이지 않아요'), findsNothing);
  });

  testWidgets('복원된 음성 삭제 화면은 앱 재개 시 후보를 다시 불러온다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '원주 기도 강원내과회'),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 오전 10시 원주기도 강원내과회 일정 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(repository.listEventsCallCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(repository.listEventsCallCount, 2);
    expect(find.byKey(const ValueKey('voice-delete-candidate-list')),
        findsOneWidget);
  });

  testWidgets('오늘 아이스크림 전달 삭제 명령은 대상 후보를 표시한다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '아이스크림 전달',
          startAt: DateTime(now.year, now.month, now.day, 10),
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 아이스크림 전달 일정 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsWidgets);
    expect(find.widgetWithText(FilledButton, '삭제'), findsOneWidget);
  });

  testWidgets('오늘 삭제 명령은 지난 오늘 일정을 미래 후보보다 우선 표시한다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        for (var i = 0; i < 5; i += 1)
          _event(
            id: 'future-$i',
            title: '미래 일정 $i',
            startAt: DateTime(now.year, now.month, now.day + i + 1, 9),
          ),
        _event(
          id: 'today-past',
          title: '약재과 방문 프리셋 텍스 문의',
          startAt: DateTime(now.year, now.month, now.day, 8),
          location: '원주 세브란스',
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 약재과 방문하여 프리셋 텍스 문의하기라는 일정 삭제시켜 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('약재과 방문 프리셋 텍스 문의'), findsWidgets);
    expect(find.text('미래 일정 4'), findsNothing);
  });

  testWidgets('날짜 힌트가 없고 매칭도 없으면 폴백 후보는 3개만 보여준다', (tester) async {
    final now = DateTime.now();
    final repository = _FakeEventRepository(
      events: [
        for (var i = 0; i < 5; i += 1)
          _event(
            id: 'event-$i',
            title: '후보 일정 $i',
            startAt: DateTime(now.year, now.month, now.day + i + 1, 9),
          ),
      ],
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '잘못 들은 일정 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('후보 일정 0'), findsWidgets);
    expect(find.text('후보 일정 1'), findsWidgets);
    expect(find.text('후보 일정 2'), findsWidgets);
    expect(find.text('후보 일정 3'), findsNothing);
  });

  testWidgets('저장된 일정이 앱 DB에서 0건이면 복구 카드를 보여준다', (tester) async {
    var syncCalls = 0;
    final repository = _FakeEventRepository(events: const []);
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 아이스크림 전달 일정 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            forceSyncCalendars: (
                {required String reason, required bool force}) async {
              syncCalls += 1;
            },
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-target-events-section')),
        findsOneWidget);
    expect(syncCalls, 1);
    expect(repository.listEventsCallCount, 2);
    expect(find.text('앱 DB에서 일정을 못 불러왔어요'), findsOneWidget);
    expect(find.text('저장된 일정이 앱 DB에서 보이지 않아요'), findsOneWidget);
    expect(find.textContaining('action=delete'), findsOneWidget);
    expect(find.textContaining('userId=있음'), findsOneWidget);
    expect(find.textContaining('totalEventCount=0'), findsOneWidget);
    expect(find.textContaining('filteredCount=0'), findsOneWidget);
    expect(find.textContaining('displayedCount=0'), findsOneWidget);
    expect(find.textContaining('targetQuery='), findsOneWidget);
    expect(find.text('새 일정으로 추가'), findsOneWidget);
    expect(find.text('다시 말하기'), findsOneWidget);
    expect(find.text('일정 탭 보기'), findsOneWidget);
    expect(find.text('동기화 후 다시 찾기'), findsOneWidget);
  });

  testWidgets('0건으로 시작해도 강제 동기화 후 후보가 생기면 바로 다시 보여준다', (tester) async {
    var syncCalls = 0;
    final repository = _FakeEventRepository(events: const []);
    final restoredEvent = _event(
      id: 'event-restored',
      title: '아이스크림 전달',
      startAt: DateTime(_voiceFixtureYear, 5, 13, 11),
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '오늘 아이스크림 전달 일정 삭제해 줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            forceSyncCalendars: (
                {required String reason, required bool force}) async {
              syncCalls += 1;
              repository._events.add(restoredEvent);
            },
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(syncCalls, 1);
    expect(repository.listEventsCallCount, 2);
    expect(find.text('대상 일정'), findsOneWidget);
    expect(find.text('아이스크림 전달'), findsWidgets);
    expect(find.text('앱 DB에서 일정을 못 불러왔어요'), findsNothing);
    expect(find.text('저장된 일정이 앱 DB에서 보이지 않아요'), findsNothing);
  });

  testWidgets('같은 음성 액션 화면에서 문장이 바뀌면 상태를 비우고 후보를 다시 불러온다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(id: 'event-1', title: '첫 번째 삭제 후보'),
      ],
    );
    var rawText = '첫 번째 삭제 후보 삭제해줘';

    Widget buildScreen() {
      return MaterialApp(
        home: VoiceActionScreen(
          rawText: rawText,
          action: VoiceScheduleAction.delete,
          eventRepository: repository,
          sideEffectService: const _NoopSideEffectService(),
          homeWidgetService: _NoopHomeWidgetService(),
          userIdOverride: 'user-1',
        ),
      );
    }

    await tester.pumpWidget(buildScreen());
    await tester.pumpAndSettle();

    expect(repository.listEventsCallCount, 1);
    expect(find.byKey(const ValueKey('voice-delete-candidate-0-event-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-candidate-list')),
        findsOneWidget);

    repository._events
      ..clear()
      ..add(_event(id: 'event-2', title: '두 번째 삭제 후보'));
    rawText = '두 번째 삭제 후보 삭제해줘';
    await tester.pumpWidget(buildScreen());
    await tester.pumpAndSettle();

    expect(repository.listEventsCallCount, 2);
    expect(find.byKey(const ValueKey('voice-delete-candidate-0-event-2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-delete-candidate-0-event-1')),
        findsNothing);
    expect(find.byKey(const ValueKey('voice-delete-candidate-list')),
        findsOneWidget);
  });
  testWidgets('voice location edit resolves map coordinates before edit screen',
      (tester) async {
    final originalStart = DateTime.now().add(const Duration(days: 1));
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '실매출 확인',
          startAt: originalStart,
        ),
      ],
    );
    final lookupService = _FakeLocationLookupService(
      results: const <LocationLookupResult>[
        LocationLookupResult(
          name: '원주세브란스기독병원',
          address: '강원 원주시 일산로 20',
          latitude: 37.3492,
          longitude: 127.9463,
          provider: LocationLookupProvider.tmap,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '내일 오후 1시에 실매출 확인 일정에 원주세브란스기독병원 장소 추가해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            locationLookupService: lookupService,
            permissionService: _NoLocationPermissionService(),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              'edit:${event.title}|${event.location}|${event.locationLat}|${event.locationLng}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('실매출 확인'), findsWidgets);
    final resolvedLocationButton = find.descendant(
      of: find.byKey(const ValueKey('voice-action-candidate-event-1')),
      matching: find.widgetWithText(FilledButton, '장소 입력'),
    );
    await tester.ensureVisible(resolvedLocationButton);
    await tester.tap(resolvedLocationButton);
    await tester.pumpAndSettle();

    expect(lookupService.queries, ['원주세브란스기독병원']);
    expect(
      find.textContaining(
        'edit:실매출 확인|원주세브란스기독병원|37.3492|127.9463',
      ),
      findsOneWidget,
    );
    expect(repository.updatedEvents, isEmpty);
  });

  testWidgets('voice location edit asks before replacing an existing location',
      (tester) async {
    final originalStart = DateTime.now().add(const Duration(days: 1));
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '강릉 만남',
          startAt: originalStart,
          location: '강릉역',
        ),
      ],
    );
    final lookupService = _FakeLocationLookupService(
      results: const <LocationLookupResult>[
        LocationLookupResult(
          name: '강릉 건도리횟집',
          address: '강원 강릉시',
          latitude: 37.755,
          longitude: 128.9,
          provider: LocationLookupProvider.tmap,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '이번 주 금요일 6시에 있는 일정에 강릉 건도리 횟집 장소 추가',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            locationLookupService: lookupService,
            permissionService: _NoLocationPermissionService(),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = (state.extra as EventEditRoutePayload).draft;
            return Text(
              'edit:${event.title}|${event.location}|${event.locationLat}|${event.locationLng}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    final replaceLocationButton = find.descendant(
      of: find.byKey(const ValueKey('voice-action-candidate-event-1')),
      matching: find.widgetWithText(FilledButton, '장소 입력'),
    );
    await tester.ensureVisible(replaceLocationButton);
    await tester.tap(replaceLocationButton);
    await tester.pumpAndSettle();

    expect(find.text('장소를 바꿀까요?'), findsOneWidget);
    expect(find.textContaining('강릉역'), findsWidgets);
    expect(lookupService.queries, isEmpty);

    await tester.tap(find.text('교체하기'));
    for (var i = 0; i < 20 && lookupService.queries.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(lookupService.queries, ['강릉 건도리 횟집']);
    expect(
      find.textContaining('edit:강릉 만남|강릉 건도리횟집|37.755|128.9'),
      findsOneWidget,
    );
  });

  testWidgets('그룹 일정도 수정 후보 목록에 함께 나타난다', (tester) async {
    final repository = _FakeEventRepository(events: const []);
    final groupRepository = _FakeGroupRepository([
      _group(id: 'group-1'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository([
      _groupEvent(
        id: 'group-event-1',
        groupId: 'group-1',
        title: '여름워크숍',
      ),
    ]);
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '여름워크숍 일정 확인',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupRepository: groupRepository,
            groupEventRepository: groupEventRepository,
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('여름워크숍'), findsOneWidget);
  });

  testWidgets('날짜 변경과 개인전환이 동시에 섞인 발화는 그룹 일정을 날짜변경이 아닌 개인전환으로 라우팅한다 (핵심 회귀)',
      (tester) async {
    final repository = _FakeEventRepository(events: const []);
    final groupRepository = _FakeGroupRepository([
      _group(id: 'group-1'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository([
      _groupEvent(
        id: 'group-event-1',
        groupId: 'group-1',
        title: '여름워크숍',
      ),
    ]);
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            // 날짜 신호("이번 주 금요일")와 개인전환 신호("개인 일정으로 바꿔줘")가
            // 한 발화에 동시에 존재하는 회귀 시나리오.
            rawText: '여름워크숍 이 팀 일정 개인 일정으로 바꿔줘 이번 주 금요일',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupRepository: groupRepository,
            groupEventRepository: groupEventRepository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // 날짜 변경 카드가 아니라 "개인 일정으로 전환" 카드로 라우팅돼야 한다.
    expect(find.text('개인 일정으로 전환'), findsWidgets);
    expect(find.text('직접 편집'), findsNothing);

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    // 개인 전환 경로(취소 + 개인 일정 생성)를 탔는지 확인 — 날짜변경 경로인
    // updateEvent/updateGroupEvent가 아니라 cancelGroupEvent + createEvent가
    // 호출돼야 한다.
    expect(groupEventRepository.cancelledIds, ['group-event-1']);
    expect(groupEventRepository.updatedEvents, isEmpty);
    expect(repository.createdEvents, hasLength(1));
    expect(repository.createdEvents.single.title, '여름워크숍');
    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets(
      '그룹 일정 수정(전환 아님)은 바로 저장 시 updateGroupEvent로 라우팅되고 개인 저장소는 호출되지 않는다',
      (tester) async {
    final repository = _FakeEventRepository(events: const []);
    final groupRepository = _FakeGroupRepository([
      _group(id: 'group-1'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository([
      _groupEvent(
        id: 'group-event-1',
        groupId: 'group-1',
        title: '여름워크숍',
        location: '본사',
      ),
    ]);
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '여름워크숍 일정 장소 강남역으로 변경',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupRepository: groupRepository,
            groupEventRepository: groupEventRepository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(groupEventRepository.updatedEvents, hasLength(1));
    expect(groupEventRepository.updatedEvents.single.location, '강남역');
    expect(repository.updatedEvents, isEmpty);
    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets('그룹 일정 삭제는 cancelGroupEvent로 라우팅되고 개인 deleteEvent는 호출되지 않는다',
      (tester) async {
    final repository = _FakeEventRepository(events: const []);
    final groupRepository = _FakeGroupRepository([
      _group(id: 'group-1'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository([
      _groupEvent(
        id: 'group-event-1',
        groupId: 'group-1',
        title: '여름워크숍',
      ),
    ]);
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '여름워크숍 삭제해줘',
            action: VoiceScheduleAction.delete,
            eventRepository: repository,
            groupRepository: groupRepository,
            groupEventRepository: groupEventRepository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('voice-delete-button-0-group-event-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('voice-confirm-delete-group-event-1')),
    );
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledIds, ['group-event-1']);
    expect(repository.deletedEventIds, isEmpty);
    expect(find.text('일정 탭'), findsOneWidget);
  });

  testWidgets('개인 전환 중 그룹 취소가 실패하면 개인 일정이 생성되지 않는다 (원자성)', (tester) async {
    final repository = _FakeEventRepository(events: const []);
    final groupRepository = _FakeGroupRepository([
      _group(id: 'group-1'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository(
      [
        _groupEvent(
          id: 'group-event-1',
          groupId: 'group-1',
          title: '여름워크숍',
        ),
      ],
      cancelShouldFail: true,
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '여름워크숍 이 팀 일정 개인 일정으로 바꿔줘 이번 주 금요일',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupRepository: groupRepository,
            groupEventRepository: groupEventRepository,
            userIdOverride: 'user-1',
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    // 취소가 실패했으므로 개인 일정 생성 시도 자체가 없어야 한다(원자성).
    expect(repository.createdEvents, isEmpty);
    // 실패했으므로 캘린더 탭으로 이동하지 않는다.
    expect(find.text('일정 탭'), findsNothing);
  });

  testWidgets(
      '반복 개인 일정을 바로 저장하면 범위 선택 모달이 뜨고, "이 일정만"은 원본을 건드리지 않고 분리된 이벤트만 만든다',
      (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime(_voiceFixtureYear, 5, 8, 10), // 금요일
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=FR',
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 중요하게 표시해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(find.text('반복 일정 수정'), findsOneWidget);
    expect(repository.updatedEvents, isEmpty);
    expect(repository.createdEvents, isEmpty);

    await tester.tap(find.text('이 일정만'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, isEmpty);
    expect(repository.createdEvents, hasLength(1));
    final created = repository.createdEvents.single;
    expect(created.parentEventId, 'event-1');
    expect(created.recurrenceRule, isNull);
    expect(created.isCritical, isTrue);
    // 원본 회차 날짜를 overriddenOccurrenceDate로 기록해야 캘린더/위젯이
    // 원본 회차를 정확히 찾아 숨긴다(2026-07-27). 이 픽스처는 날짜를 바꾸지
    // 않는 수정이라 startAt과 같아야 정상이다.
    expect(created.overriddenOccurrenceDate, created.startAt);
  });

  testWidgets('반복 개인 일정 수정에서 "전체 반복 일정"을 고르면 원본 계열을 그대로 덮어쓴다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime(_voiceFixtureYear, 5, 8, 10),
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=FR',
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 중요하게 표시해줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 반복 일정'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.createdEvents, isEmpty);
    expect(repository.updatedEvents, hasLength(1));
    final updated = repository.updatedEvents.single;
    expect(updated.id, 'event-1');
    expect(updated.recurrenceRule, 'FREQ=WEEKLY;BYDAY=FR');
    expect(updated.isCritical, isTrue);
  });

  testWidgets('중요·반복 일정 후보 카드는 종류를 나타내는 배지를 보여준다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime.now().add(const Duration(days: 1)),
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=FR',
          isCritical: true,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 장소 알려줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('중요'), findsOneWidget);
    expect(find.text('반복'), findsOneWidget);
  });

  testWidgets('"N일간 연속 일정으로 바꿔줘"는 종료일을 시작일+N-1일로 설정한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime(_voiceFixtureYear, 8, 3, 10),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 3일간 연속 일정으로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('연속 일정(~8/5(수))'), findsOneWidget);

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    final updated = repository.updatedEvents.single;
    expect(updated.isMultiDay, isTrue);
    final endLocal = updated.endAt!.toLocal();
    expect(endLocal.month, 8);
    expect(endLocal.day, 5);
  });

  testWidgets('"…까지 연속으로 바꿔줘"는 명시된 날짜를 종료일로 사용한다', (tester) async {
    final repository = _FakeEventRepository(
      events: [
        _event(
          id: 'event-1',
          title: '한강 피크닉',
          startAt: DateTime(_voiceFixtureYear, 8, 3, 10),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 일정 8월 5일까지 연속으로 바꿔줘',
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            userIdOverride: 'user-1',
            sideEffectService: const _NoopSideEffectService(),
            homeWidgetService: _NoopHomeWidgetService(),
            locationLookupService: _FakeLocationLookupService.empty(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('바로 저장'));
    await tester.pumpAndSettle();

    expect(find.text('일정 탭'), findsOneWidget);
    expect(repository.updatedEvents, hasLength(1));
    final updated = repository.updatedEvents.single;
    expect(updated.isMultiDay, isTrue);
    final endLocal = updated.endAt!.toLocal();
    expect(endLocal.month, 8);
    expect(endLocal.day, 5);
  });
}

EventModel _event({
  required String id,
  required String title,
  DateTime? startAt,
  DateTime? endAt,
  String? location,
  String? memo,
  String? recurrenceRule,
  bool isCritical = false,
  bool useStrongAlarm = false,
  List<String> supplies = const <String>[],
  List<String> suppliesChecked = const <String>[],
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt ?? DateTime(_voiceFixtureYear, 5, 5, 10),
    endAt: endAt,
    location: location ?? (title.contains('한강') ? '한강' : null),
    memo: memo,
    supplies: supplies,
    suppliesChecked: suppliesChecked,
    recurrenceRule: recurrenceRule,
    isCritical: isCritical,
    useStrongAlarm: useStrongAlarm,
  );
}

/// 기본 리마인더 reader: 첫 후보 기준 "시작 60분 전 notify_at이 저장됨"
/// (확정 가능) 상태를 시뮬레이션한다. 자동 저장 양성 테스트가 Supabase
/// 초기화/인증 우회 없이 알림 정책을 확정할 수 있게 한다. 끔(null)/오류/
/// 30분 시나리오는 개별 테스트가 자체 reader로 덮어쓴다.
Future<DateTime?> _defaultKnownReminderReader(
  _FakeEventRepository repository,
) async {
  final events = repository._events;
  final startAt = events.isEmpty ? null : events.first.startAt;
  return (startAt ?? DateTime.now()).subtract(const Duration(minutes: 60));
}

class _OverlappingFakeEventRepository extends _FakeEventRepository {
  _OverlappingFakeEventRepository({
    required super.events,
    required this.overlappingEvents,
  });

  final List<EventModel> overlappingEvents;

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return List<EventModel>.of(overlappingEvents);
  }
}

class _FailingSaveFakeEventRepository extends _FakeEventRepository {
  _FailingSaveFakeEventRepository({required super.events});

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    throw StateError('update failed');
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required List<EventModel> events})
      : _events = List<EventModel>.of(events);

  final List<EventModel> _events;
  final List<EventModel> updatedEvents = <EventModel>[];
  final List<EventModel> createdEvents = <EventModel>[];
  final List<String> deletedEventIds = <String>[];
  int listEventsCallCount = 0;

  @override
  Future<EventModel> createEvent(EventModel event) async {
    createdEvents.add(event);
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedEventIds.add(eventId);
    _events.removeWhere((event) => event.id == eventId);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in _events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listEventsCallCount += 1;
    return List<EventModel>.of(_events);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvents.add(event);
    return event;
  }
}

GroupModel _group({required String id}) {
  return GroupModel(
    id: id,
    createdBy: 'user-1',
    name: '테스트 그룹',
  );
}

GroupEventModel _groupEvent({
  required String id,
  required String groupId,
  required String title,
  DateTime? startAt,
  DateTime? endAt,
  String? location,
}) {
  final start = startAt ?? DateTime.now().add(const Duration(days: 1));
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: start,
    endAt: endAt ?? start.add(const Duration(hours: 1)),
    createdBy: 'user-1',
    location: location,
  );
}

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository(this.groups);

  final List<GroupModel> groups;

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
    return const <GroupMemberModel>[];
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
  _FakeGroupEventRepository(this.events, {this.cancelShouldFail = false});

  final List<GroupEventModel> events;
  final List<GroupEventModel> updatedEvents = <GroupEventModel>[];
  final List<String> cancelledIds = <String>[];
  // 테스트에서 "권한 없는 사용자" 등 취소 실패 케이스를 재현하기 위한 플래그.
  final bool cancelShouldFail;

  // 자동 저장 게이트의 그룹 공유 링크 확인용. 기본은 공유 없음(빈 목록).
  bool groupShareLinkCheckReturnsShare = false;

  @override
  Future<List<GroupEventModel>> getGroupEventsByPersonalEventId(
    String personalEventId,
  ) async {
    if (!groupShareLinkCheckReturnsShare || events.isEmpty) {
      return const <GroupEventModel>[];
    }
    return <GroupEventModel>[events.first];
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return events.where((event) => event.groupId == groupId).toList();
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    updatedEvents.add(event);
    final index = events.indexWhere((candidate) => candidate.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    if (cancelShouldFail) {
      throw StateError('활성 일정만 취소할 수 있습니다.');
    }
    cancelledIds.add(eventId);
    final index = events.indexWhere((candidate) => candidate.id == eventId);
    if (index < 0) {
      throw StateError('일정을 찾지 못했어요.');
    }
    final cancelled = events[index].copyWith(
      status: 'cancelled',
      cancelledAt: DateTime.now().toUtc(),
      cancelledBy: 'tester',
    );
    events[index] = cancelled;
    return cancelled;
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return events.firstWhere((candidate) => candidate.id == eventId);
  }
}

class _FakeLocationLookupService extends LocationLookupService {
  _FakeLocationLookupService({required this.results});

  _FakeLocationLookupService.empty() : results = const <LocationLookupResult>[];

  final List<LocationLookupResult> results;
  final List<String> queries = <String>[];

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    queries.add(query);
    return results;
  }
}

class _NoLocationPermissionService extends AppPermissionService {
  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async {
    return null;
  }
}

class _NoopSideEffectService extends ManualEventSideEffectService {
  const _NoopSideEffectService();

  @override
  Future<ManualEventSideEffectResult> syncAfterSave({
    required EventModel event,
    required String userId,
    bool clearPreActions = true,
    Duration? reminderOffset =
        ManualEventSideEffectService.defaultReminderOffset,
    Duration? criticalAlarmOffset,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    int travelMinutes = 30,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
    bool isFirstExternalEventOfDay = true,
  }) async {
    return const ManualEventSideEffectResult(
      remindersSynced: false,
      notificationsSynced: false,
      preActionsCleared: false,
    );
  }

  @override
  Future<void> cleanupAfterDelete(
    String eventId, {
    String? userId,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
  }) async {}
}

/// syncAfterSave에 전달된 리마인더 오프셋과 실제 저장 payload를 기록한다.
class _ReminderRecordingSideEffectService extends ManualEventSideEffectService {
  final reminderPayloads = <Map<String, dynamic>>[];
  Duration? lastReminderOffset;
  Duration? lastCriticalAlarmOffset;
  int syncAfterSaveCalls = 0;

  @override
  Future<ManualEventSideEffectResult> syncAfterSave({
    required EventModel event,
    required String userId,
    bool clearPreActions = true,
    Duration? reminderOffset =
        ManualEventSideEffectService.defaultReminderOffset,
    Duration? criticalAlarmOffset,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    int travelMinutes = 30,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
    bool isFirstExternalEventOfDay = true,
  }) async {
    syncAfterSaveCalls++;
    lastReminderOffset = reminderOffset;
    lastCriticalAlarmOffset = criticalAlarmOffset;
    reminderPayloads.addAll(
      buildReminderPayloads(
        event: event,
        userId: userId,
        reminderOffset: reminderOffset,
        criticalAlarmOffset: criticalAlarmOffset,
      ),
    );
    return const ManualEventSideEffectResult(
      remindersSynced: false,
      notificationsSynced: false,
      preActionsCleared: false,
    );
  }
}

class _RecordingSideEffectService extends ManualEventSideEffectService {
  final cleanedUpEventIds = <String>[];
  final cleanedUpUserIds = <String?>[];

  @override
  Future<void> cleanupAfterDelete(
    String eventId, {
    String? userId,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
  }) async {
    cleanedUpEventIds.add(eventId);
    cleanedUpUserIds.add(userId);
  }
}

class _NoopHomeWidgetService extends HomeWidgetService {
  @override
  Future<bool> updateNextEventData(
    HomeWidgetNextEventData data, {
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
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
