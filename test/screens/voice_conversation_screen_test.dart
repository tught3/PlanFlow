import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSttService extends SttService {
  Completer<SttListenResult>? _completer;
  ValueChanged<String>? _onPartialResult;
  ValueChanged<SttNativeStatusEvent>? _onStatus;
  int cancelCalls = 0;
  int stopCalls = 0;
  int listenCalls = 0;

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) {
    listenCalls += 1;
    _onPartialResult = onPartialResult;
    _onStatus = onStatus;
    _completer = Completer<SttListenResult>();
    return _completer!.future;
  }

  void emitStatus(SttNativeStatus status) {
    _onStatus?.call(SttNativeStatusEvent(status: status));
  }

  void emitPartial(String text) {
    _onPartialResult?.call(text);
  }

  void completeSuccess(String text) {
    _completer?.complete(SttListenResult.success(text));
  }

  void completeFailure(String message) {
    _completer?.complete(
      SttListenResult.failure(
        failure: SttListenFailure.silence,
        message: message,
      ),
    );
  }

  @override
  Future<void> cancelActiveListen() async {
    cancelCalls += 1;
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('Cancelled.');
    }
  }

  @override
  Future<void> stopActiveListen() async {
    stopCalls += 1;
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('Stopped.');
    }
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.events);

  final List<EventModel> events;
  final List<String> deletedIds = <String>[];
  final List<EventModel> updatedEvents = <EventModel>[];
  final List<EventModel> createdEvents = <EventModel>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => events;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    createdEvents.add(event);
    return event;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvents.add(event);
    final index = events.indexWhere((candidate) => candidate.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
  }
}

class _SlowSecondListEventRepository extends EventRepository {
  _SlowSecondListEventRepository();

  final Completer<List<EventModel>> secondListCompleter =
      Completer<List<EventModel>>();
  int _listCallCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    _listCallCount += 1;
    if (_listCallCount == 1) {
      return Future<List<EventModel>>.value(const <EventModel>[]);
    }
    return secondListCompleter.future;
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
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
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

class _FakeLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return <LocationLookupResult>[
      LocationLookupResult(
        name: query,
        address: query,
        latitude: 37.7519,
        longitude: 128.8761,
      ),
    ];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 전송 경로의 GptService().parseSchedule()이 ApiUsageGuard.tryConsume →
    // SharedPreferences.getInstance()를 await한다. mock이 없으면 pending되어
    // pumpAndSettle이 타임아웃되므로, 빈 mock과 가드 싱글톤 초기화를 둔다.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

  Future<void> pumpConversation(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(384, 823),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: child,
      ),
    );
  }

  testWidgets('AI 일정 대화는 STT partial을 입력창에 즉시 보여준다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);

    stt.emitPartial('이번주 금요일 일정');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '이번주 금요일 일정');
  });

  testWidgets('AI 일정 대화는 native ready 전에는 듣는 중으로 표시하지 않는다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);

    stt.emitStatus(SttNativeStatus.ready);
    await tester.pump();

    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsOneWidget);
  });

  testWidgets('AI 일정 대화는 STT 성공 후 사용자 말과 응답을 표시한다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    stt.completeSuccess('오늘 일정 알려줘');
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);
  });

  testWidgets('AI 일정 대화 input bar follows the keyboard inset', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    final before = tester.getBottomLeft(find.byType(TextField)).dy;

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    final after = tester.getBottomLeft(find.byType(TextField)).dy;

    expect(after, lessThan(before));
    addTearDown(
      () => tester.view.viewInsets = FakeViewPadding.zero,
    );
  });

  testWidgets('AI 일정 대화는 STT 실패 시 바로 재시도하고 실패 문구를 남기지 않는다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    stt.completeFailure('음성을 알아듣지 못했어요.');
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('음성을 알아듣지 못했어요.'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    expect(stt.listenCalls, greaterThanOrEqualTo(2));
    expect(find.text('음성을 알아듣지 못했어요.'), findsNothing);
  });

  testWidgets(
    'AI 일정 대화는 수동 수정 후 제출해도 늦은 STT partial이 입력창을 다시 채우지 않는다',
    (tester) async {
      final stt = _FakeSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      stt.emitPartial('첫번째 일정');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '첫번째 일정',
      );

      await tester.enterText(find.byType(TextField), '두번째 일정');
      await tester.pump();

      await tester.tap(find.text('전송'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      stt.emitPartial('늦게온 일정');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    },
  );

  testWidgets('AI 일정 대화는 initialText를 자동 제출한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 모바일 크기에서 기본 메시지와 입력바를 렌더링한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);
    expect(find.textContaining('일정을 이어서 말해도 돼요'), findsOneWidget);
    expect(find.text('계속 듣기'), findsNothing);
    expect(find.text('Supabase 설정을 확인하지 못했어요.'), findsOneWidget);
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(find.text('전송'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 initialText 결과 일정 카드를 렌더링한다', (tester) async {
    final friday = DateTime(2026, 5, 29, 18);
    final events = List<EventModel>.generate(
      4,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: _FakeEventRepository(events),
        initialText: '5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('5월 29일 일정 다 보여 줘'), findsOneWidget);
    expect(find.textContaining('일정 4개를 찾았어요'), findsOneWidget);
    expect(find.text('금요일 일정 1'), findsOneWidget);
    expect(find.text('금요일 일정 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드를 눌러 수정 모달을 열고 편집으로 이동한다', (tester) async {
    final event = EventModel(
      id: 'event-edit',
      userId: 'user-1',
      title: '금요일 상담',
      startAt: DateTime(2026, 5, 29, 18).toUtc(),
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: _FakeEventRepository(<EventModel>[event]),
            initialText: '5월 29일 일정 다 보여 줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => const Text(
            '편집 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('금요일 상담'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정으로 무엇을 할까요?'), findsOneWidget);
    expect(find.text('수정하기'), findsOneWidget);
    expect(find.text('삭제하기'), findsOneWidget);

    await tester.tap(find.text('수정하기'));
    await tester.pumpAndSettle();

    expect(find.text('편집 화면'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 다음날 이동 명령을 편집 초안으로 넘긴다', (tester) async {
    final event = EventModel(
      id: 'event-shift',
      userId: 'user-1',
      title: '이동할 일정',
      startAt: DateTime(2026, 5, 7, 9).toUtc(),
      endAt: DateTime(2026, 5, 7, 10).toUtc(),
    );
    EventModel? receivedDraft;
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: _FakeEventRepository(<EventModel>[event]),
            initialText: '5월 7일 일정 알려줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            receivedDraft = state.extra as EventModel?;
            return const Text(
              '편집 화면',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '1번 일정 그 다음날로 변경해줘',
    );
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(find.text('편집 화면'), findsOneWidget);
    expect(receivedDraft, isNotNull);
    expect(
      planflowLocal(receivedDraft!.startAt!),
      DateTime(2026, 5, 8, 9),
    );
    expect(
      planflowLocal(receivedDraft!.endAt!),
      DateTime(2026, 5, 8, 10),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드 삭제를 확인 후 실행한다', (tester) async {
    final event = EventModel(
      id: 'event-delete',
      userId: 'user-1',
      title: '삭제할 일정',
      startAt: DateTime(2026, 5, 29, 18).toUtc(),
    );
    final repository = _FakeEventRepository(<EventModel>[event]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제할 일정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제하기'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정을 삭제할까요?'), findsOneWidget);

    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-delete'));
    expect(find.text('삭제할 일정 일정을 삭제했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 삭제 확인 대기 중 붙은 이전 명령을 잘라낸다', (tester) async {
    final friday = DateTime(2026, 5, 29, 18);
    final events = List<EventModel>.generate(
      5,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );
    final repository = _FakeEventRepository(events);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(find.textContaining('금요일 일정 5 일정을 삭제할까요?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘 응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-4'));
    expect(find.text('응 삭제해줘'), findsOneWidget);
    expect(find.text('5번 일정 삭제해 줘 응 삭제해줘'), findsNothing);

    await tester.enterText(find.byType(TextField), '응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds.where((id) => id == 'event-4'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 뒤로가기 확인 후에만 대화 세션을 종료한다', (tester) async {
    // _exitConversation()은 context.pop() 대신 context.go(AppRoutes.home)으로 이동한다.
    // 따라서 /home 라우트가 필요하며, pop 결과를 기대하는 대신 홈 화면으로 이동하는지 확인한다.
    final stt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: _FakeEventRepository(const <EventModel>[]),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Scaffold(
            body: Text('홈 화면'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    // 뒤로가기 버튼을 누르면 확인 바텀시트가 뜬다
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

    // '계속 대화하기'를 누르면 대화 화면이 유지된다
    await tester.tap(find.text('계속 대화하기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);

    // 다시 뒤로가기 후 '나가기'를 누르면 홈 화면으로 이동한다
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();

    // _exitConversation이 context.go(AppRoutes.home)으로 이동하므로 홈 화면이 보인다
    expect(find.text('홈 화면'), findsOneWidget);
    expect(stt.cancelCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 듣는 중 정지 후 마이크로 다시 시작할 수 있다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);
    expect(find.text('음성 입력 정지'), findsOneWidget);

    await tester.tap(find.text('음성 입력 정지'));
    await tester.pumpAndSettle();

    // 정지 후 하단 컨트롤 바는 다시 시작 버튼 하나로 돌아온다.
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(stt.stopCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 전송 처리 중 문맥 분석 로더를 보여준다', (tester) async {
    final repository = _SlowSecondListEventRepository();
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.tap(find.text('전송'));
    await tester.pump();

    expect(find.text('AI 문맥 분석중이에요...'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    repository.secondListCompleter.complete(const <EventModel>[]);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 장소 변경을 지도 대신 편집 화면에 미리 채운다', (tester) async {
    final stt = _FakeSttService();
    var pickerCalls = 0;
    EventModel? editDraft;
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '방문 일정',
        startAt: DateTime(2026, 5, 22, 9).toUtc(),
      ),
    ]);
    Future<LocationLookupResult?> fakeLocationPicker({
      required BuildContext context,
      required String query,
      LocationLookupService? locationLookupService,
      AppPermissionService? appPermissionService,
      String? preferredMapProvider,
      bool? canUseInAppMapOverride,
    }) async {
      pickerCalls += 1;
      return LocationLookupResult(
        name: query,
        address: query,
        latitude: 37.7519,
        longitude: 128.8761,
      );
    }

    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: repository,
            locationLookupService: _FakeLocationLookupService(),
            permissionService: _NoLocationPermissionService(),
            locationPicker: fakeLocationPicker,
            initialText: '5월 22일 일정 보여줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            editDraft = state.extra as EventModel?;
            return const Text('편집 화면', textDirection: TextDirection.ltr);
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();
    stt.completeSuccess('그 일정에 강릉 건도리횟집 장소추가');
    for (var i = 0; i < 20 && editDraft == null; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    expect(find.text('편집 화면'), findsOneWidget);
    expect(pickerCalls, 0);
    expect(repository.updatedEvents, isEmpty);
    expect(editDraft?.location, '강릉 건도리횟집');
    expect(editDraft?.locationLat, isNotNull);
    expect(editDraft?.locationLng, isNotNull);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 중요한 일정 변경을 바로 저장한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '방문 일정',
        startAt: DateTime(2026, 5, 22, 9).toUtc(),
        isCritical: false,
      ),
    ]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '5월 22일 일정 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 중요한 일정으로 표시해줘');
    await tester.tap(find.text('전송'));
    for (var i = 0; i < 20 && repository.updatedEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.isCritical, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 그룹 일정을 후보 목록에 병합해 순번 매칭에 포함한다', (tester) async {
    final personalEvent = EventModel(
      id: 'personal-1',
      userId: 'user-1',
      title: '개인 방문 일정',
      startAt: DateTime(2026, 5, 22, 9).toUtc(),
    );
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: _FakeEventRepository(<EventModel>[personalEvent]),
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    // 개인 일정(9시)과 그룹 일정(14시)이 시간순으로 함께 후보 목록에 잡혀야 한다.
    expect(find.textContaining('일정 2개를 찾았어요'), findsOneWidget);
    expect(find.text('개인 방문 일정'), findsOneWidget);
    expect(find.text('팀 회의'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 그룹 일정 수정을 GroupEventRepository로 라우팅한다',
      (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 장소를 본관 3층으로 바꿔줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.updatedEvents.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 그룹 일정이 개인 리포지토리가 아니라 그룹 리포지토리로 저장돼야 한다.
    expect(personalRepository.updatedEvents, isEmpty);
    expect(groupEventRepository.updatedEvents, hasLength(1));
    expect(groupEventRepository.updatedEvents.single.location, '본관 3층');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정을 개인 일정으로 옮긴다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 개인 일정으로 바꿔줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.cancelledIds.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledIds, contains('group-event-1'));
    expect(personalRepository.createdEvents, hasLength(1));
    expect(personalRepository.createdEvents.single.title, '팀 회의');
    expect(personalRepository.createdEvents.single.source, 'manual');
    expect(personalRepository.createdEvents.single.startAt, groupEvent.startAt);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 개인 전환 권한 실패 시 개인 일정을 만들지 않는다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository(
      <GroupEventModel>[groupEvent],
      cancelShouldFail: true,
    );

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 개인 일정으로 바꿔줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(personalRepository.createdEvents, isEmpty);
    expect(find.textContaining('개인 일정으로 옮길 수 있어요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 삭제를 실제로 취소 처리한다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응 삭제해줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.cancelledIds.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledIds, contains('group-event-1'));
    expect(find.textContaining('아직 음성으로 삭제할 수 없어요'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 제목 변경을 GroupEventRepository로 라우팅한다',
      (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(2026, 5, 22, 14).toUtc(),
      endAt: DateTime(2026, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 제목을 주간 회의로 바꿔줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.updatedEvents.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(groupEventRepository.updatedEvents, hasLength(1));
    expect(groupEventRepository.updatedEvents.single.title, '주간 회의');
    expect(personalRepository.updatedEvents, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
