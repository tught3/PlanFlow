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
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';
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

/// cancelActiveListen()이 끝없이 대기하는 STT — 종료 흐름의 타임아웃 동작을
/// 검증하기 위한 전용 fake.
class _HangingCancelSttService extends _FakeSttService {
  @override
  Future<void> cancelActiveListen() {
    cancelCalls += 1;
    return Completer<void>().future; // 절대 완료되지 않음
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

/// [VoiceConversationEntitlementService]의 consume() 호출 횟수/인자를
/// 검증하기 위한 fake delegate.
class _FakeEntitlementDelegate implements VoiceConversationEntitlementDelegate {
  int consumeCalls = 0;
  final List<String> consumedSessionIds = <String>[];
  VoiceConversationConsumeResult? consumeResult;

  @override
  Future<VoiceConversationEntitlementPeek?> peek() async => null;

  @override
  Future<VoiceConversationConsumeResult?> consume(String sessionId) async {
    consumeCalls += 1;
    consumedSessionIds.add(sessionId);
    return consumeResult;
  }
}

/// [VoiceConversationAdGate]의 self-gate 호출 여부/인자를 검증하기 위한
/// fake delegate. [grantToProvide]가 있으면 즉시 진입을 승인하고, null이면
/// 진입을 거부(onEnterAllowed 미호출)한다.
class _FakeAdGateDelegate implements VoiceConversationAdGateDelegate {
  _FakeAdGateDelegate({this.grantToProvide});

  int tryEnterCalls = 0;
  String? lastUserId;
  final VoiceConversationEntryGrant? grantToProvide;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    final grant = grantToProvide;
    if (grant != null) {
      onEnterAllowed(grant);
    }
  }
}

/// [_FakeAdGateDelegate]와 달리 승인이 즉시(동기적으로) 끝나지 않고
/// [delay]만큼 지연된 뒤에야 완료되는 fake. self-gate가 아직 진행 중인
/// 레이스 윈도우 동안 사용자가 수동으로 텍스트를 제출하는 상황을 재현하기
/// 위해 쓴다(HIGH: self-gate 대기 중 수동입력 시 소비 영구 누락 회귀 테스트).
class _DelayedAdGateDelegate implements VoiceConversationAdGateDelegate {
  _DelayedAdGateDelegate({
    required this.grantToProvide,
    required this.delay,
  });

  int tryEnterCalls = 0;
  String? lastUserId;
  final VoiceConversationEntryGrant grantToProvide;
  final Duration delay;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    await Future<void>.delayed(delay);
    onEnterAllowed(grantToProvide);
  }
}

/// [_DelayedAdGateDelegate]와 반대로, [delay] 후 **거부**로 끝나는 fake
/// (onEnterAllowed를 아예 호출하지 않음). self-gate가 지연 후 거부로 끝나는
/// 동안 그 대기 창 안에서 사용자가 수동 제출한 명령이 처리되지 않아야 함을
/// 재현하기 위해 쓴다(리뷰어가 위젯테스트로 재현한 거부 케이스 레이스 회귀).
class _DelayedDeniedAdGateDelegate implements VoiceConversationAdGateDelegate {
  _DelayedDeniedAdGateDelegate({required this.delay});

  int tryEnterCalls = 0;
  String? lastUserId;
  final Duration delay;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    await Future<void>.delayed(delay);
    // onEnterAllowed를 호출하지 않음 = 거부.
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

  testWidgets(
    'AI 일정 대화는 홈 버튼(push) 진입 경로에서도 취소-재시도 후 정상적으로 홈으로 돌아간다',
    (tester) async {
      // 버그 재현 경로(①): 홈 화면이 Navigator.push 대신 GoRouter의
      // context.push(AppRoutes.voiceConversation)로 대화 화면에 진입하는
      // 상황을 재현한다. 수정 전에는 이 진입 방식과 무관하게
      // _exitConversation()의 context.go(home)이 GoRouter 스택 밖의
      // 화면을 pop하지 못해 뒤로가기가 무반응이었다.
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.home,
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      context.push(AppRoutes.voiceConversation),
                  child: const Text('홈 화면'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(const <EventModel>[]),
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

      expect(find.text('홈 화면'), findsOneWidget);

      // 홈 버튼과 동일한 방식(context.push)으로 대화 화면에 진입한다.
      await tester.tap(find.text('홈 화면'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(find.text('홈 화면'), findsNothing);

      // 첫 번째 뒤로가기: '계속 대화하기'로 취소해도 대화 화면이 유지되고,
      // 플래그가 고착되지 않아 다음 뒤로가기 시도도 확인 시트를 다시 띄운다.
      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

      await tester.tap(find.text('계속 대화하기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화'), findsOneWidget);

      // 두 번째 뒤로가기: 확인 시트가 다시 뜨고, '나가기'를 누르면
      // push로 진입한 대화 화면이 사라지고 실제로 홈 화면으로 돌아간다.
      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

      await tester.tap(find.text('나가기'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsNothing);
      expect(find.text('홈 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 STT 취소가 지연돼도 타임아웃 후 대화 세션을 끝까지 종료한다',
    (tester) async {
      // _stopVoiceBeforeNavigation()의 cancelActiveListen() 호출이
      // 끝없이 대기하는 상황(실패 시나리오)을 흉내낸다. 타임아웃이 없으면
      // _exitConversation()이 영원히 끝나지 않아 _isExitingConversation이
      // 고착돼 다음 뒤로가기도 무반응이 된다.
      final stt = _HangingCancelSttService();
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

      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('나가기'));
      await tester.pump();

      // 타임아웃(4초) 전에는 STT 취소를 기다리느라 아직 대화 화면에 있다.
      expect(find.text('홈 화면'), findsNothing);

      // 타임아웃을 넘겨서 펌프하면 취소 완료를 기다리지 않고 종료가
      // 이어져 홈 화면으로 이동한다.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('홈 화면'), findsOneWidget);
      expect(stt.cancelCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('AI 일정 대화는 장소 변경을 편집 화면 없이 바로 저장한다', (tester) async {
    final stt = _FakeSttService();
    var pickerCalls = 0;
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

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();
    stt.completeSuccess('그 일정에 강릉 건도리횟집 장소추가');
    for (var i = 0; i < 20 && repository.updatedEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('편집 화면'), findsNothing);
    expect(pickerCalls, 1);
    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.location, '강릉 건도리횟집');
    expect(repository.updatedEvents.single.locationLat, 37.7519);
    expect(repository.updatedEvents.single.locationLng, 128.8761);
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

  testWidgets('AI 일정 대화는 그룹 일정 수정을 GroupEventRepository로 라우팅한다', (tester) async {
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

  testWidgets('AI 일정 대화는 팀 일정 개인 전환 권한 실패 시 개인 일정을 만들지 않는다',
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

  testWidgets(
    'AI 일정 대화는 편집 화면 이동 후 pop으로 복귀하면 멈췄던 마이크를 자동 재개한다',
    (tester) async {
      final event = EventModel(
        id: 'event-resume',
        userId: 'user-1',
        title: '이동할 일정',
        startAt: DateTime(2026, 5, 7, 9).toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        endAt: DateTime(2026, 5, 7, 10).toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
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

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      final listenCallsBefore = stt.listenCalls;
      expect(listenCallsBefore, 1);

      stt.completeSuccess('1번 일정 그 다음날로 변경해줘');
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, greaterThan(listenCallsBefore));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 정지 버튼으로 멈춘 뒤 편집 화면을 다녀와도 마이크를 자동 재개하지 않는다',
    (tester) async {
      final event = EventModel(
        id: 'event-no-resume',
        userId: 'user-1',
        title: '이동할 일정',
        startAt: DateTime(2026, 5, 7, 9).toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        endAt: DateTime(2026, 5, 7, 10).toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
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

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      expect(find.text('음성 입력 정지'), findsOneWidget);

      await tester.tap(find.text('음성 입력 정지'));
      await tester.pumpAndSettle();

      final listenCallsBefore = stt.listenCalls;

      await tester.enterText(
        find.byType(TextField),
        '1번 일정 그 다음날로 변경해줘',
      );
      await tester.tap(find.text('전송'));
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, listenCallsBefore);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 카드 액션시트로 편집 화면을 다녀와도 마이크를 자동 재개하지 않는다',
    (tester) async {
      final event = EventModel(
        id: 'event-edit-sheet',
        userId: 'user-1',
        title: '금요일 상담',
        startAt: DateTime(2026, 5, 29, 18).toUtc(), // banned-ok: initialText('5월 29일 일정 다 보여 줘')와 매칭시키는 더미 일정(클램프 로직 미개입)
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
              initialText: '5월 29일 일정 다 보여 줘',
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
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

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      final listenCallsBefore = stt.listenCalls;
      expect(listenCallsBefore, 1);

      await tester.tap(find.text('금요일 상담'));
      await tester.pumpAndSettle();

      expect(find.text('이 일정으로 무엇을 할까요?'), findsOneWidget);

      await tester.tap(find.text('수정하기'));
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, listenCallsBefore);
      expect(tester.takeException(), isNull);
    },
  );

  group('AI일정대화 엔타이틀먼트 소비 시점', () {
    tearDown(() {
      VoiceConversationEntitlementService.instance.delegateForTest = null;
      VoiceConversationAdGate.instance.delegateForTest = null;
      authProvider.setUser(null);
    });

    testWidgets('grant가 있으면 첫 명령이 처리되기 시작할 때 정확히 1회 소비한다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'initial_free',
          initialRemaining: 2,
          dailyRemaining: 3,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-initial-text',
        source: EntitlementSource.initialFree,
        initialRemainingAtGate: 3,
        dailyRemainingAtGate: 3,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(
          entryGrant: grant,
          initialText: '오늘 일정 알려줘',
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeDelegate.consumeCalls, 1);
      expect(fakeDelegate.consumedSessionIds, <String>['session-initial-text']);
    });

    testWidgets('같은 세션에서 여러 번 명령해도 엔타이틀먼트는 1회만 소비한다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'daily_free',
          initialRemaining: 0,
          dailyRemaining: 4,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-repeat',
        source: EntitlementSource.dailyFree,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 5,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(entryGrant: grant),
      );
      await tester.pumpAndSettle();

      for (var i = 0; i < 10; i += 1) {
        await tester.enterText(find.byType(TextField), '오늘 일정 알려줘 $i');
        await tester.tap(find.text('전송'));
        await tester.pumpAndSettle();
      }

      expect(fakeDelegate.consumeCalls, 1);
      expect(fakeDelegate.consumedSessionIds, <String>['session-repeat']);
    });

    testWidgets('아무 명령도 보내지 않고 이탈하면 소비하지 않고 이탈 이벤트만 남긴다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate();
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-abandoned',
        source: EntitlementSource.initialFree,
        initialRemainingAtGate: 3,
        dailyRemainingAtGate: 3,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(entryGrant: grant),
      );
      await tester.pumpAndSettle();

      // 아무 명령도 제출하지 않고 위젯 트리를 교체(dispose)해 이탈을 흉내낸다.
      // AnalyticsService는 1차 배포에서 외부 SDK 없이 no-op(디버그 프린트만)
      // 처리되어 이벤트 발화 자체를 스파이할 테스트 훅이 없다(디버그 프린트
      // 가로채기는 flutter_test의 foundation debug 변수 불변식과 충돌해 사용
      // 불가 — 실측 확인함). 여기서는 dispose 시 소비가 발생하지 않았음만
      // 검증한다(_usageConsumedForSession 가드의 핵심 계약).
      expect(fakeDelegate.consumeCalls, 0);
    });

    testWidgets('entryGrant 없이 진입하면 화면이 스스로 게이트를 호출해 승인을 얻는다', (tester) async {
      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-self-gate',
        source: EntitlementSource.dailyFree,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 1,
      );
      final fakeAdGateDelegate = _FakeAdGateDelegate(grantToProvide: grant);
      VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
      authProvider.setUser('user-self-gate');

      final fakeEntitlementDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'daily_free',
          initialRemaining: 0,
          dailyRemaining: 0,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeEntitlementDelegate;

      await pumpConversation(
        tester,
        const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
      );
      await tester.pumpAndSettle();

      expect(fakeAdGateDelegate.tryEnterCalls, 1);
      expect(fakeAdGateDelegate.lastUserId, 'user-self-gate');
      expect(fakeEntitlementDelegate.consumeCalls, 1);
      expect(
        fakeEntitlementDelegate.consumedSessionIds,
        <String>['session-self-gate'],
      );
    });

    testWidgets('entryGrant 없고 로그인 정보도 없으면 self-gate를 시도하지 않고 fail-open으로 진행한다',
        (tester) async {
      final fakeAdGateDelegate = _FakeAdGateDelegate();
      VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;

      final fakeEntitlementDelegate = _FakeEntitlementDelegate();
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeEntitlementDelegate;

      await pumpConversation(
        tester,
        const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
      );
      await tester.pumpAndSettle();

      // 로그인 정보가 없어 게이트를 시도하지 않지만, 화면은 정상적으로
      // initialText를 처리한다(fail-open, 소비는 되지 않음).
      expect(fakeAdGateDelegate.tryEnterCalls, 0);
      expect(find.text('오늘 일정 알려줘'), findsOneWidget);
      expect(fakeEntitlementDelegate.consumeCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'self-gate가 지연되는 동안 수동 제출해도 제출은 정상 처리되고 소비는 정확히 1회만 일어난다',
      (tester) async {
        // HIGH 회귀: entryGrant가 null(딥링크 등)로 진입해 self-gate가
        // 비동기로 진행 중인데, 그 완료를 기다리지 않는 수동 제출 경로
        // (onSubmit)가 먼저 _submitText를 호출하면 _usageConsumedForSession이
        // grant 없이 선점돼 실제 소비(consume RPC)가 영구히 누락됐었다.
        const grant = VoiceConversationEntryGrant(
          sessionId: 'session-self-gate-race',
          source: EntitlementSource.dailyFree,
          initialRemainingAtGate: 0,
          dailyRemainingAtGate: 1,
        );
        final fakeAdGateDelegate = _DelayedAdGateDelegate(
          grantToProvide: grant,
          delay: const Duration(milliseconds: 300),
        );
        VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
        authProvider.setUser('user-self-gate-race');

        final fakeEntitlementDelegate = _FakeEntitlementDelegate()
          ..consumeResult = const VoiceConversationConsumeResult(
            source: 'daily_free',
            initialRemaining: 0,
            dailyRemaining: 0,
          );
        VoiceConversationEntitlementService.instance.delegateForTest =
            fakeEntitlementDelegate;

        await pumpConversation(
          tester,
          const VoiceConversationScreen(),
        );
        // initState의 addPostFrameCallback이 self-gate 호출을 시작하도록
        // 한 프레임 더 진행시킨다. 이 시점에는 self-gate가 지연 중이라 아직
        // 완료되지 않은 상태다.
        await tester.pump();
        expect(fakeAdGateDelegate.tryEnterCalls, 1);
        expect(fakeEntitlementDelegate.consumeCalls, 0);

        // self-gate가 끝나기 전에 사용자가 직접 텍스트를 입력해 전송 버튼을
        // 누른다(onSubmit → _submitText, self-gate 대기 없이 즉시 호출됨).
        await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
        await tester.tap(find.text('전송'));
        await tester.pump();

        // self-gate가 아직 지연 중이므로, 수정 전 코드였다면 이 시점에
        // grant 없이 소비 플래그만 선점되고 실제 consume은 다시 호출되지
        // 않았다. 수정 후에는 _submitText가 completer를 기다리므로 아직
        // 소비가 일어나지 않아야 한다.
        expect(fakeEntitlementDelegate.consumeCalls, 0);

        // self-gate 지연이 끝나도록 시간을 흘려보낸다.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();

        // 제출 자체는 정상 처리됐고(사용자 메시지가 대화에 남음), 소비는
        // 정확히 1회만 일어나야 한다(0회도 2회도 아님).
        expect(find.text('오늘 일정 알려줘'), findsOneWidget);
        expect(fakeEntitlementDelegate.consumeCalls, 1);
        expect(
          fakeEntitlementDelegate.consumedSessionIds,
          <String>['session-self-gate-race'],
        );
      },
    );

    testWidgets(
      'self-gate가 지연 후 거부로 끝나면 대기 중 제출된 명령은 처리되지 않는다',
      (tester) async {
        // BLOCKER 회귀: self-gate(딥링크 등 entryGrant 미보유 진입)가 아직
        // 완료 전인데 사용자가 수동으로 텍스트를 제출하면 _submitText가
        // completer를 기다린다. completer.complete()는 마이크로태스크로
        // 재개를 스케줄하고, context.go()로 인한 dispose는 그 다음 프레임에야
        // 일어나므로, 거부 완료 직후 재개되는 지점에서 mounted는 아직 true다.
        // 이 시점에 grant==null만 확인하지 않고 명시적 거부 판정
        // (_entryGateDenied)이 없으면, 재개된 코드가 명령을 그대로 처리해
        // 버려 게이트의 거부 결정이 무시된다.
        final fakeAdGateDelegate = _DelayedDeniedAdGateDelegate(
          delay: const Duration(milliseconds: 300),
        );
        VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
        authProvider.setUser('user-self-gate-denied');

        final fakeEntitlementDelegate = _FakeEntitlementDelegate();
        VoiceConversationEntitlementService.instance.delegateForTest =
            fakeEntitlementDelegate;

        // 화면 dispose(홈 이동) 타이밍과 무관하게 "명령이 실제로 처리됐는가"를
        // 판정하기 위해 debugPrint 로그를 가로챈다. _submitText가 명령을
        // 실제 처리하면 '_conversation.handle' 직후 'VoiceConversationScreen
        // result: action=...' 로그를 남기는데(라인 568~572 참조), 이는 위젯
        // 리빌드/네비게이션과 무관하게 처리 시점에 동기적으로 찍힌다 — 위젯
        // 트리가 그 뒤에 dispose돼도 이미 찍힌 로그는 사라지지 않으므로,
        // find.text 같은 위젯 기반 단언보다 신뢰도가 높은 판정 근거다.
        // (주의) debugPrint override는 addTearDown으로 복구하면 늦다 —
        // flutter_test의 foundation debug 변수 불변식 검사(_verifyInvariants)가
        // package:test의 addTearDown 큐보다 먼저 실행돼 "changed by the
        // test" 오류로 실패한다(실측 확인). 그래서 이 블록 안에서 캡처가
        // 끝나는 즉시 명시적으로 원복한다(try/finally).
        final debugLogs = <String>[];
        final originalDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) debugLogs.add(message);
        };

        final router = GoRouter(
          initialLocation: AppRoutes.voiceConversation,
          routes: [
            GoRoute(
              path: AppRoutes.voiceConversation,
              builder: (context, state) => const VoiceConversationScreen(),
            ),
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const Scaffold(
                body: Text('홈 화면'),
              ),
            ),
          ],
        );

        try {
          await tester.pumpWidget(
            MaterialApp.router(
              theme: buildPlanFlowTheme(),
              routerConfig: router,
            ),
          );
          // initState의 addPostFrameCallback이 self-gate 호출을 시작하도록
          // 한 프레임 더 진행시킨다. 이 시점에는 self-gate가 지연 중이라 아직
          // 완료(거부 확정)되지 않은 상태다.
          await tester.pump();
          expect(fakeAdGateDelegate.tryEnterCalls, 1);
          expect(fakeEntitlementDelegate.consumeCalls, 0);

          // self-gate가 거부로 끝나기 전에 사용자가 직접 텍스트를 입력해
          // 전송 버튼을 누른다(onSubmit → _submitText, self-gate 대기 없이
          // 즉시 호출됨. 함수 내부에서 completer를 기다리게 됨). self-gate가
          // 아직 미완료이므로 _submitText는 completer await에서 멈춰 있고,
          // 입력창은 아직 비워지지 않은 채(제출 미처리) 그대로다 — 이 시점의
          // find.text('오늘 일정 알려줘')는 (아직 지워지지 않은) TextField
          // 자체의 값과 일치해 findsOneWidget이 나오므로 판정에 쓰지 않는다.
          await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
          await tester.tap(find.text('전송'));
          await tester.pump();

          expect(fakeEntitlementDelegate.consumeCalls, 0);

          // self-gate 지연이 끝나 거부가 확정된다. completer가 complete()되고
          // (마이크로태스크로 _submitText 재개), 곧이어 context.go(home)이
          // 호출된다.
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();

          // 거부가 확정된 뒤에도 대기 중이던 제출은 처리되지 않아야 한다:
          // 소비가 0회이고, 화면은 홈으로 이동해(대화 화면 트리 자체가 사라져)
          // 있어야 한다. VoiceConversationScreen이 dispose됐으므로 그 안의
          // TextField/메시지 버블도 함께 사라져, 이 시점의 find.text 결과는
          // 더 이상 TextField 잔여값이 아니라 실제 메시지 목록 여부를 뜻한다.
          expect(fakeEntitlementDelegate.consumeCalls, 0);
          expect(find.byType(VoiceConversationScreen), findsNothing);
          expect(find.text('오늘 일정 알려줘'), findsNothing);
          expect(find.text('홈 화면'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // 핵심 판정: 거부된 제출이 실제 처리 단계(_conversation.handle)까지
          // 도달하지 않았어야 한다. 도달했다면 이 로그가 남는다(수정 전
          // 코드에서 실측 재현: action=showEvents 로그가 남으며 게이트의 거부
          // 결정이 무시됨).
          expect(
            debugLogs.any(
              (log) => log.startsWith('VoiceConversationScreen result:'),
            ),
            isFalse,
            reason: '거부된 self-gate 대기 중 제출이 실제 명령 처리 단계까지 도달하면 안 된다',
          );
        } finally {
          debugPrint = originalDebugPrint;
        }
      },
    );
  });
}
