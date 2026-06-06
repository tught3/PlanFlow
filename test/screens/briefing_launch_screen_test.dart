import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  }) async {
    executeCalls += 1;
    receivedUserId = userId;
    receivedManualTrigger = isManualTrigger;
    return const BriefingExecutionResult(
      delivered: true,
      usedFallback: false,
      message: '모닝 브리핑을 재생했습니다.',
    );
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
}
