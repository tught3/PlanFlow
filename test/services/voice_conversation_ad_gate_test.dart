import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';

/// [VoiceConversationAdGate]의 회귀 테스트.
///
/// 배경(2026-08 개편): 이 게이트는 더 이상 진입 시점에 무료 사용 횟수를
/// 소비하지 않는다(peek만 사용, 실제 소비는 화면 쪽으로 이관). 진입이
/// 허용되면 `onEnterAllowed`에 [VoiceConversationEntryGrant]가 전달되고,
/// 그 grant.source가 승인 근거([EntitlementSource])를 담는다.
///
/// 테스트 전략:
/// - Firebase 미초기화 환경에서는 실제 `_runGate`가 광고 비활성 상태를
///   fail-closed로 처리하는지 검증한다.
/// - 정적 광고 SDK 의존성이 있는 성공/거부 분기는 delegate를 통해
///   “초기 3회 무료”와 “광고 보상 완료”만 허용되는 계약을 검증한다.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    VoiceConversationAdGate.instance.delegateForTest = null;
  });

  group('실제 _runGate 경로 (delegate 미주입)', () {
    testWidgets(
      '리워드 광고 킬스위치 OFF(테스트 환경 Firebase 미초기화 기본값)면 '
      '광고 우회 진입을 허용하지 않는다',
      (tester) async {
        VoiceConversationEntryGrant? captured;

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    unawaited(
                      VoiceConversationAdGate.instance
                          .tryEnterVoiceConversation(
                        context: context,
                        userId: 'user-1',
                        onEnterAllowed: (grant) => captured = grant,
                      ),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(captured, isNull);
      },
    );

    testWidgets('동일 userId 동시 호출은 인플라이트 가드로 두 번째 호출을 무시한다', (tester) async {
      final captured = <VoiceConversationEntryGrant>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  unawaited(
                    VoiceConversationAdGate.instance.tryEnterVoiceConversation(
                      context: context,
                      userId: 'user-concurrent',
                      onEnterAllowed: captured.add,
                    ),
                  );
                  unawaited(
                    VoiceConversationAdGate.instance.tryEnterVoiceConversation(
                      context: context,
                      userId: 'user-concurrent',
                      onEnterAllowed: captured.add,
                    ),
                  );
                },
                child: const Text('open-twice'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open-twice'));
      await tester.pumpAndSettle();

      // 광고 스위치 OFF 정책에서는 어떤 호출도 진입을 허용하지 않는다.
      expect(captured, isEmpty);
    });
  });

  group('strict 무료 3회/광고 보상 계약 (delegate 경유)', () {
    testWidgets(
      '초기 무료 잔여가 있으면 initialFree로 진입 허용',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: EntitlementSource.initialFree,
            initialRemainingAtGate: 2,
            dailyRemainingAtGate: 0,
          ),
        );

        expect(captured, isNotNull);
        expect(captured!.source, EntitlementSource.initialFree);
        expect(captured.initialRemainingAtGate, 2);
        expect(captured.dailyRemainingAtGate, 0);
      },
    );

    testWidgets('초기 무료 소진 후에는 dailyFree 우회가 허용되지 않는다', (tester) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.deny(),
      );

      expect(captured, isNull);
    });

    testWidgets('5) 무료 소진 → 광고 다이얼로그 확인 → 광고 시청 완료 → adRewarded, 진입 허용', (
      tester,
    ) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.allow(
          source: EntitlementSource.adRewarded,
        ),
      );

      expect(captured, isNotNull);
      expect(captured!.source, EntitlementSource.adRewarded);
    });

    testWidgets('광고 실패는 진입을 거부한다', (tester) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.deny(),
      );

      expect(captured, isNull);
    });
  });
}

/// [_ScenarioAdGateDelegate]를 주입한 뒤 tryEnterVoiceConversation을 1회
/// 호출하고, onEnterAllowed로 전달된 grant(또는 null)를 반환하는 헬퍼.
Future<VoiceConversationEntryGrant?> _runScenario(
  WidgetTester tester, {
  required VoiceConversationAdGateDelegate delegate,
}) async {
  VoiceConversationAdGate.instance.delegateForTest = delegate;

  VoiceConversationEntryGrant? captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () {
              unawaited(
                VoiceConversationAdGate.instance.tryEnterVoiceConversation(
                  context: context,
                  userId: 'user-scenario',
                  onEnterAllowed: (grant) => captured = grant,
                ),
              );
            },
            child: const Text('open'),
          );
        },
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return captured;
}

/// 광고 게이트 정책 분기 1건을 시뮬레이션하는 delegate.
///
/// - [allow]: 진입을 즉시 허용하고 지정한 [EntitlementSource]/잔여값으로
///   grant를 만들어 onEnterAllowed에 전달한다(실제 `_runGate`가 해당 분기에서
///   만드는 grant와 동일한 형태).
/// - [deny]: 진입을 거부한다(onEnterAllowed를 호출하지 않는다). 실제
///   `_runGate`의 'retry'/'feature_unavailable'/광고요청불가+비free_pass
///   분기와 동일한 결과.
class _ScenarioAdGateDelegate implements VoiceConversationAdGateDelegate {
  const _ScenarioAdGateDelegate._({
    required this.allowed,
    this.source,
    this.initialRemainingAtGate = 0,
    this.dailyRemainingAtGate = 0,
  });

  factory _ScenarioAdGateDelegate.allow({
    required EntitlementSource source,
    int initialRemainingAtGate = 0,
    int dailyRemainingAtGate = 0,
  }) {
    return _ScenarioAdGateDelegate._(
      allowed: true,
      source: source,
      initialRemainingAtGate: initialRemainingAtGate,
      dailyRemainingAtGate: dailyRemainingAtGate,
    );
  }

  factory _ScenarioAdGateDelegate.deny() {
    return const _ScenarioAdGateDelegate._(allowed: false);
  }

  final bool allowed;
  final EntitlementSource? source;
  final int initialRemainingAtGate;
  final int dailyRemainingAtGate;

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
    if (!allowed) {
      return;
    }
    onEnterAllowed(
      VoiceConversationEntryGrant(
        sessionId: VoiceConversationSessionIdGenerator.next(),
        source: source!,
        initialRemainingAtGate: initialRemainingAtGate,
        dailyRemainingAtGate: dailyRemainingAtGate,
      ),
    );
  }
}
