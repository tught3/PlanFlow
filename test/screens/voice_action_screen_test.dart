import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/voice_action_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';

void main() {
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
          startAt: DateTime(2026, 5, 13, 10),
        ),
        _event(
          id: 'event-2',
          title: '켄스파크 15일 구독갱신',
          startAt: DateTime(2026, 4, 14, 14),
        ),
        _event(
          id: 'event-3',
          title: '방문록 미리 준비',
          startAt: DateTime(2026, 5, 21, 15),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '5월 13일 팀장 동행방문 일정 이번 주 수요일로 변경',
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
          startAt: DateTime(2026, 5, 14, 10),
        ),
        _event(
          id: 'event-2',
          title: '구독갱신',
          memo: '결제 확인',
          startAt: DateTime(2026, 5, 13, 10),
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
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            final event = state.extra as EventModel;
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
            final event = state.extra as EventModel;
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
          startAt: DateTime(2026, 5, 12, 10),
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
            final event = state.extra as EventModel;
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

    expect(find.textContaining('2026-05-15T01:00:00.000'), findsOneWidget);
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
          startAt: DateTime(2026, 5, 13, 11),
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
      startAt: DateTime(2026, 5, 13, 11),
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
            final event = state.extra as EventModel;
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
            final event = state.extra as EventModel;
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
}

EventModel _event({
  required String id,
  required String title,
  DateTime? startAt,
  String? location,
  String? memo,
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt ?? DateTime(2026, 5, 5, 10),
    location: location ?? (title.contains('한강') ? '한강' : null),
    memo: memo,
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required List<EventModel> events})
      : _events = List<EventModel>.of(events);

  final List<EventModel> _events;
  final List<EventModel> updatedEvents = <EventModel>[];
  final List<String> deletedEventIds = <String>[];
  int listEventsCallCount = 0;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

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

class _FakeLocationLookupService extends LocationLookupService {
  _FakeLocationLookupService({required this.results});

  _FakeLocationLookupService.empty() : results = const <LocationLookupResult>[];

  final List<LocationLookupResult> results;
  final List<String> queries = <String>[];

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
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
