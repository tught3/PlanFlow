import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/briefing/briefing_launch_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({
    required this.resolved,
    required this.syncResult,
    required this.currentUserId,
  });

  final Completer<bool> resolved;
  final bool syncResult;
  final String? currentUserId;
  int syncCalls = 0;

  @override
  bool get isSignedIn => currentUserId != null && currentUserId!.isNotEmpty;

  @override
  String? get userId => currentUserId;

  @override
  Future<bool> waitForInitialSessionResolution({
    Duration timeout = const Duration(seconds: 4),
  }) {
    return resolved.future;
  }

  @override
  Future<bool> syncCurrentSession() async {
    syncCalls += 1;
    return syncResult;
  }
}

class _FakeBriefingSchedulerService extends BriefingSchedulerService {
  int executeCalls = 0;
  String? receivedUserId;
  bool? receivedManualTrigger;

  @override
  Future<BriefingExecutionResult> executeBriefing({
    required bool isMorning,
    String? userId,
    bool isManualTrigger = false,
    void Function(List<EventModel> events)? onEventsResolved,
  }) async {
    executeCalls += 1;
    receivedUserId = userId;
    receivedManualTrigger = isManualTrigger;
    onEventsResolved?.call(const <EventModel>[]);
    return const BriefingExecutionResult(
      delivered: true,
      usedFallback: false,
      message: '모닝 브리핑을 재생했습니다.',
    );
  }
}

/// 일정 조회 자체가 예외로 실패하는 상황을 재현하는 fake — onEventsResolved를
/// 아예 호출하지 않고(네트워크 오류 등으로 목록을 못 얻은 상태) delivered:false
/// 결과만 반환한다.
class _FailingFakeBriefingSchedulerService extends BriefingSchedulerService {
  @override
  Future<BriefingExecutionResult> executeBriefing({
    required bool isMorning,
    String? userId,
    bool isManualTrigger = false,
    void Function(List<EventModel> events)? onEventsResolved,
  }) async {
    return const BriefingExecutionResult(
      delivered: false,
      usedFallback: false,
      message: '브리핑 실행에 실패했습니다. 로그인 상태와 일정 조회를 확인해 주세요.',
      failureReason: 'execute_failed',
    );
  }
}

/// executeBriefing이 TTS 재생 완료까지(resultCompleter가 완료될 때까지)
/// 끝나지 않는 상황을 재현하는 fake — onEventsResolved는 즉시 호출한다.
class _SlowFakeBriefingSchedulerService extends BriefingSchedulerService {
  _SlowFakeBriefingSchedulerService({required this.events});

  final List<EventModel> events;
  final Completer<BriefingExecutionResult> resultCompleter =
      Completer<BriefingExecutionResult>();

  @override
  Future<BriefingExecutionResult> executeBriefing({
    required bool isMorning,
    String? userId,
    bool isManualTrigger = false,
    void Function(List<EventModel> events)? onEventsResolved,
  }) async {
    onEventsResolved?.call(events);
    return resultCompleter.future;
  }
}

void main() {
  testWidgets('브리핑 알림 진입은 세션 복구 전 executeBriefing을 실행하지 않는다', (tester) async {
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>(),
      syncResult: true,
      currentUserId: 'user-1',
    );
    final scheduler = _FakeBriefingSchedulerService();

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('로그인 세션을 확인하고 있어요.'), findsOneWidget);
    expect(scheduler.executeCalls, 0);

    auth.resolved.complete(true);
    await tester.pumpAndSettle();

    expect(scheduler.executeCalls, 1);
    expect(scheduler.receivedUserId, 'user-1');
    expect(scheduler.receivedManualTrigger, isTrue);
    expect(find.text('모닝 브리핑을 재생했습니다.'), findsOneWidget);
  });

  testWidgets('세션 복구 실패 시 일정 없음 대신 재로그인 필요 상태를 보여준다', (tester) async {
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>()..complete(true),
      syncResult: false,
      currentUserId: null,
    );
    final scheduler = _FakeBriefingSchedulerService();

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(scheduler.executeCalls, 0);
    expect(
      find.text('로그인 세션을 다시 확인해야 브리핑을 실행할 수 있습니다.'),
      findsOneWidget,
    );
  });

  testWidgets(
      '음성 재생이 끝나기 전에도(로딩 문구만 있는 게 아니라) 읽어줄 일정 목록을 바로 보여준다',
      (tester) async {
    // 회귀: executeBriefing이 TTS 재생 완료까지 반환되지 않아, 재생되는
    // 동안 화면에 "브리핑을 준비하고 있어요" 로딩 문구만 뜨고 실제 읽어줄
    // 일정 목록은 전혀 안 보였다.
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>()..complete(true),
      syncResult: true,
      currentUserId: 'user-1',
    );
    final scheduler = _SlowFakeBriefingSchedulerService(
      events: <EventModel>[
        EventModel(
          id: 'e1',
          userId: 'user-1',
          title: '아침 회의',
          startAt: DateTime.utc(2026, 1, 1, 0),
          endAt: DateTime.utc(2026, 1, 1, 1),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 아직 executeBriefing이 완료되지 않았지만(=TTS 재생 중인 상태를
    // 시뮬레이션), 일정 목록은 이미 화면에 보여야 한다.
    expect(find.text('아침 회의'), findsOneWidget);
    expect(find.textContaining('읽어드리고 있어요'), findsOneWidget);

    scheduler.resultCompleter.complete(
      BriefingExecutionResult(
        delivered: true,
        usedFallback: false,
        message: '모닝 브리핑을 재생했습니다.',
        events: scheduler.events,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('모닝 브리핑을 재생했습니다.'), findsOneWidget);
    expect(find.text('아침 회의'), findsOneWidget);
  });

  testWidgets(
      '브리핑 목록의 시각은 raw UTC가 아니라 KST(planflowLocal)로 표시된다',
      (tester) async {
    // 신뢰성 회귀: 음성 브리핑은 planflowLocal(KST)로 시각을 말하는데 목록은
    // raw startAt.hour(UTC)를 그대로 써서, 예컨대 UTC 00:00(=KST 09:00) 일정이
    // 목록에는 12:00으로 나오고 음성은 9시라고 말하는 불일치가 있었다.
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>()..complete(true),
      syncResult: true,
      currentUserId: 'user-1',
    );
    final scheduler = _SlowFakeBriefingSchedulerService(
      events: <EventModel>[
        EventModel(
          id: 'e1',
          userId: 'user-1',
          title: '아침 회의',
          startAt: DateTime.utc(2026, 1, 1, 0), // UTC 00:00 → KST 09:00
          endAt: DateTime.utc(2026, 1, 1, 1),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // KST 09:00으로 표시(12/24h 포맷 무관하게 "9:00" 포함), 절대 UTC 00:00을
    // 12h로 표기한 "12:00"이 아니어야 한다.
    expect(find.textContaining('9:00'), findsOneWidget);
    expect(find.textContaining('12:00'), findsNothing);
  });

  testWidgets('일정 조회가 실패하면 목록 섹션이 통째로 사라지지 않고 실패 안내를 보여준다',
      (tester) async {
    // 회귀: 조회 예외로 onEventsResolved가 한 번도 호출되지 않으면
    // resolvedEvents==null && result.delivered==false가 되어, 예전엔 목록
    // 섹션(빈 상태 안내 포함)이 통째로 렌더되지 않았다. 사용자는 이걸
    // "일정이 없는데 안내가 안 떴다"고 체감했다 — 실제로는 조회 실패였다.
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>()..complete(true),
      syncResult: true,
      currentUserId: 'user-1',
    );
    final scheduler = _FailingFakeBriefingSchedulerService();

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('브리핑 실행에 실패했습니다. 로그인 상태와 일정 조회를 확인해 주세요.'),
        findsOneWidget);
    expect(find.text('오늘 일정을 불러오지 못했어요. 다시 시도해 주세요.'), findsOneWidget);
    // 실패인데 "없어요"라고 오해시키면 안 된다.
    expect(find.text('오늘 일정이 없어요'), findsNothing);
  });

  testWidgets('일정이 진짜 0건이면 "일정이 없어요"를 보여준다', (tester) async {
    final auth = _FakeAuthProvider(
      resolved: Completer<bool>()..complete(true),
      syncResult: true,
      currentUserId: 'user-1',
    );
    final scheduler = _FakeBriefingSchedulerService();

    await tester.pumpWidget(
      MaterialApp(
        home: BriefingLaunchScreen(
          isMorning: true,
          authProviderOverride: auth,
          briefingSchedulerService: scheduler,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정이 없어요'), findsOneWidget);
  });
}
