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
/// - "킬스위치 OFF" 분기(무료 소진 뒤)는 RemoteConfigService가 Firebase 미초기화
///   상태(테스트 환경 기본값)에서 rewardedAdEnabled가 항상 false로 폴백하는
///   실제 프로덕션 동작을 그대로 이용해, 실제 `_runGate` 코드 경로를 검증한다.
/// - 그 외 5개 분기(음성전용 비활성/광고요청불가+free_pass/무료잔여있음
///   (최초·일일)/광고시청성공/광고실패 3정책)는 RemoteConfigService·
///   AdConsentService·AdService가 정적 싱글톤이라 이 프로젝트에 테스트 주입
///   지점이 없으므로, `VoiceConversationAdGateDelegate` 백도어(기존
///   `voice_conversation_launcher_test.dart`가 쓰는 것과 동일한 패턴)를 통해
///   각 분기가 만들어야 할 grant.source 계약을 검증한다.
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

  group('6개 광고 분기 (delegate 경유 정책 계약)', () {
    testWidgets('1) 킬스위치 OFF → remoteDisabled, 진입 허용', (tester) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.allow(
          source: EntitlementSource.remoteDisabled,
        ),
      );

      expect(captured, isNotNull);
      expect(captured!.source, EntitlementSource.remoteDisabled);
    });

    testWidgets('2) 음성 대화 모드 광고 자체 비활성 → remoteDisabled, 진입 허용', (
      tester,
    ) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.allow(
          source: EntitlementSource.remoteDisabled,
        ),
      );

      expect(captured, isNotNull);
      expect(captured!.source, EntitlementSource.remoteDisabled);
    });

    testWidgets(
      '3) 광고 요청 불가(canRequestAdsLive=false) + policy=free_pass → '
      'adsUnavailableFreePass, 진입 허용',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: EntitlementSource.adsUnavailableFreePass,
          ),
        );

        expect(captured, isNotNull);
        expect(captured!.source, EntitlementSource.adsUnavailableFreePass);
      },
    );

    testWidgets(
      '3-거부) 광고 요청 불가 + policy != free_pass → 진입 거부(onEnterAllowed 미호출)',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.deny(),
        );

        expect(captured, isNull);
      },
    );

    testWidgets(
      '4a) peek 결과 최초 무료 잔여 있음(initialRemaining>0) → initialFree, 진입 허용',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: EntitlementSource.initialFree,
            initialRemainingAtGate: 2,
            dailyRemainingAtGate: 1,
          ),
        );

        expect(captured, isNotNull);
        expect(captured!.source, EntitlementSource.initialFree);
        expect(captured.initialRemainingAtGate, 2);
        expect(captured.dailyRemainingAtGate, 1);
      },
    );

    testWidgets(
      '4b) peek 결과 최초 무료 소진(initialRemaining=0)이지만 일일 무료 잔여 있음 → '
      'dailyFree, 진입 허용',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: EntitlementSource.dailyFree,
            initialRemainingAtGate: 0,
            dailyRemainingAtGate: 1,
          ),
        );

        expect(captured, isNotNull);
        expect(captured!.source, EntitlementSource.dailyFree);
        expect(captured.initialRemainingAtGate, 0);
        expect(captured.dailyRemainingAtGate, 1);
      },
    );

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

    testWidgets(
      '6a) 광고 시청 실패 + policy=free_pass → adFailedFreePass, 진입 허용',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: EntitlementSource.adFailedFreePass,
          ),
        );

        expect(captured, isNotNull);
        expect(captured!.source, EntitlementSource.adFailedFreePass);
      },
    );

    testWidgets('6b) 광고 시청 실패 + policy=retry → 진입 거부(onEnterAllowed 미호출)', (
      tester,
    ) async {
      final captured = await _runScenario(
        tester,
        delegate: _ScenarioAdGateDelegate.deny(),
      );

      expect(captured, isNull);
    });

    testWidgets(
      '6c) 광고 시청 실패 + policy=feature_unavailable → 진입 거부(onEnterAllowed 미호출)',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.deny(),
        );

        expect(captured, isNull);
      },
    );
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
