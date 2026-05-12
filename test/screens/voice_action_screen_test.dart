import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/voice_action_screen.dart';
import 'package:planflow/services/home_widget_service.dart';
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
    expect(find.text('치과 방문'), findsOneWidget);

    await tester.tap(find.text('수정하기').first);
    await tester.pumpAndSettle();

    expect(find.text('편집 화면: event-1'), findsOneWidget);
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

    await tester.tap(find.text('수정하기').first);
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
    expect(find.text('목요일 오전 회의'), findsOneWidget);
    final firstTitle = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (widget) =>
              widget.data == '서울성남 아이스크림 전달' || widget.data == '목요일 오전 회의',
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
    expect(find.text('목요일 오전 회의'), findsOneWidget);
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
    expect(find.text('목요일 오전 회의'), findsOneWidget);
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
    expect(find.text('아이스크림 전달'), findsOneWidget);
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
            line.contains('displayedCount=2') &&
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

    final router = GoRouter(
      initialLocation: AppRoutes.voiceAction,
      routes: [
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => VoiceActionScreen(
            rawText: '한강 피크닉 삭제해줘',
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

    await tester.tap(find.text('삭제하기').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();

    expect(repository.deletedEventIds, ['event-1']);
    expect(find.text('일정 탭'), findsOneWidget);
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
    expect(find.text('아이스크림 전달'), findsOneWidget);
    expect(find.text('삭제하기'), findsOneWidget);
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
            forceSyncCalendars: ({required String reason, required bool force}) async {
              syncCalls += 1;
            },
            userIdOverride: 'user-1',
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('대상 일정'), findsNothing);
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
            forceSyncCalendars: ({required String reason, required bool force}) async {
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
    expect(find.text('아이스크림 전달'), findsOneWidget);
    expect(find.text('앱 DB에서 일정을 못 불러왔어요'), findsNothing);
    expect(find.text('저장된 일정이 앱 DB에서 보이지 않아요'), findsNothing);
  });
}

EventModel _event({
  required String id,
  required String title,
  DateTime? startAt,
  String? location,
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt ?? DateTime(2026, 5, 5, 10),
    location: location ?? (title.contains('한강') ? '한강' : null),
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required List<EventModel> events})
      : _events = List<EventModel>.of(events);

  final List<EventModel> _events;
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
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _NoopSideEffectService extends ManualEventSideEffectService {
  const _NoopSideEffectService();

  @override
  Future<void> cleanupAfterDelete(String eventId) async {}
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
