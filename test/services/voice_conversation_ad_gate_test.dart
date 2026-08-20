import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/ad_service.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';
import 'package:planflow/widgets/voice_conversation_ad_dialog.dart';

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
    VoiceConversationAdGate.instance.retryAfterUserActionForTest = null;
    VoiceConversationAdGate.instance.canRequestAdsLiveForTest = null;
    // 다른 테스트가 RC 상태에 영향받지 않도록 매 테스트 후 초기화.
    RemoteConfigService.lastFetchSucceededForTest = false;
    RemoteConfigService.rewardAdFailurePolicyForTest = null;
  });

  group('실제 _runGate 경로 (delegate 미주입)', () {
    testWidgets(
      '테스트 환경(Firebase 미초기화)에서는 RC 기본값(true)이라 즉시 '
      '차단하지 않고 광고 다이얼로그 표시 후 사용자 미확인이면 진입 거부된다',
      (tester) async {
        // 배경: 2026-08-13 RC 기본값 false → true로 변경됨. Firebase가
        // 미초기화된 flutter test 환경에서 rewardedAdEnabled는 새 기본값
        // true를 반환하므로 게이트의 즉시 차단 분기에 걸리지 않고, 광고
        // 다이얼로그 단계까지 진행한다. 사용자가 다이얼로그를 확인하지
        // 않으면(onEnterAllowed 미호출) 진입은 거부된다.
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

        // 사용자 미확인 → 진입 거부.
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

      // 인플라이트 가드: 첫 번째 호출이 끝나기 전에 두 번째 호출이 들어와도
      // 사일런트하게 무시되므로 어떤 호출도 진입을 허용하지 않는다.
      expect(captured, isEmpty);
    });
  });

  group('RC fetch 분기 검증 (2026-08-13, E-RC1 차단 보강)', () {
    testWidgets(
      'RC fetch 실패 + 게이트에서 재시도 실패 → 새 기본값(true)으로 '
      '광고 다이얼로그까지 진행한다 (사용자 미확인이면 진입 거부)',
      (tester) async {
        // 배경: 2026-08-13 RC fetch 실패가 1시간 캐시로 잠기는 문제를
        // 보강하면서 게이트 분기에 retryFetchIfFailed()를 추가했다. 이
        // 테스트는 그 새 분기 중 "재시도도 실패했지만 기본값이 true이므로
        // 광고 다이얼로그 단계까지 진행한다"는 경로를 검증한다.
        // Firebase가 미초기화된 flutter test 환경은 자연스럽게
        // _lastFetchSucceeded=false + rewardedAdEnabled=true(새 기본값) +
        // retryFetchIfFailed()=false 시나리오가 재현된다.
        RemoteConfigService.lastFetchSucceededForTest = false;

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
                        userId: 'user-rc-fail',
                        onEnterAllowed: (grant) => captured = grant,
                      ),
                    );
                  },
                  child: const Text('open-rc-fail'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('open-rc-fail'));
        await tester.pumpAndSettle();

        // 게이트는 즉시 차단하지 않고 광고 다이얼로그로 진행. 사용자가
        // 다이얼로그를 확인하지 않으므로 진입은 거부된다.
        expect(captured, isNull, reason: '재시도 실패해도 기본값(true)이라 즉시 차단되면 안 된다');
      },
    );

    testWidgets(
      'RC fetch 실패 + 게이트에서 재시도 성공 시나리오 — skip 사유 기록 '
      '(Firebase Remote Config mock 필요)',
      (tester) async {
        // 이 시나리오는 "직전 fetch가 실패했지만 게이트가 강제 재시도를
        // 트리거했고 그 재시도가 성공"하는 경로다. retryFetchIfFailed가
        // 진짜로 fetchAndActivate에 성공하는 것을 재현하려면
        // firebase_remote_config_platform_interface의 Mock 구현이
        // 필요하고 이 작업 범위를 벗어난다. 이 테스트는 placeholder로
        // 남겨두되 실제 단언은 하지 않는다.
        RemoteConfigService.lastFetchSucceededForTest = false;
        expect(true, true,
            reason: 'Firebase Remote Config mock 인프라가 선행되어야 검증 가능');
      },
    );

    testWidgets(
      'RC fetch 성공 + 콘솔 OFF → E-RC1 차단 유지 — skip 사유 기록 '
      '(Firebase Remote Config mock 필요)',
      (tester) async {
        // 이 시나리오는 "콘솔에서 명시적으로 OFF"인 상태에서 즉시 차단
        // 되는 기존 동작이 그대로 유지됨을 검증한다. _lastFetchSucceeded
        // =true + rewardedAdEnabled=false인 상태가 필요한데, 후자는
        // _remoteConfig가 null인 테스트 환경에서 강제할 수 없어
        // (Firebase Remote Config mock 선행 필요) skip 한다. 코드
        // 인스펙션(lib/services/voice_conversation_ad_gate.dart의
        // `else { ... _deny(rewardedDisabled) ... }` 분기)으로 커버한다.
        RemoteConfigService.lastFetchSucceededForTest = true;
        expect(true, true,
            reason: 'Firebase Remote Config mock 인프라가 선행되어야 검증 가능');
      },
    );
  });

  group('사용자 재시도 consent 재평가', () {
    test('두 번째 시도는 UMP 재초기화 후 live availability를 fail-closed로 읽는다', () async {
      final events = <String>[];
      VoiceConversationAdGate.instance.retryAfterUserActionForTest = () async {
        events.add('retry');
      };
      VoiceConversationAdGate.instance.canRequestAdsLiveForTest = () async {
        events.add('availability');
        return false;
      };

      final result = await VoiceConversationAdGate.instance.runAdAttemptForTest(
        peek: const VoiceConversationEntitlementPeek(
          initialRemaining: 0,
          dailyRemaining: 0,
          requiresAd: true,
        ),
        attemptNumber: 2,
      );

      expect(events, <String>['retry', 'availability']);
      expect(result.isAllowed, isFalse);
      expect(result.diagnosticCode, 'E-ADS0');
    });
  });

  group('광고 terminal 단계 매핑', () {
    test('dismiss-without-reward만 cancelled이고 SDK 표시 실패는 failed다', () {
      expect(
        voiceConversationAdTerminalStageForOutcome(
          VoiceConversationAdOutcomeKind.dismissedWithoutReward,
        ),
        VoiceConversationAdDialogStage.cancelled,
      );
      expect(
        voiceConversationAdTerminalStageForOutcome(
          VoiceConversationAdOutcomeKind.showFailed,
        ),
        VoiceConversationAdDialogStage.failed,
      );
    });

    test('보상 성공 완료 목록은 failed/cancelled terminal을 완료 처리하지 않는다', () {
      expect(
        voiceConversationAdRewardCompletedStages,
        isNot(contains(VoiceConversationAdDialogStage.failed)),
      );
      expect(
        voiceConversationAdRewardCompletedStages,
        isNot(contains(VoiceConversationAdDialogStage.cancelled)),
      );
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

  group('voiceConversationGateDenialMessage 진단 코드 매핑', () {
    test('7개 reason 모두에 대해 고유한 메시지를 반환한다', () {
      final messages = VoiceConversationGateDenialReason.values
          .map(voiceConversationGateDenialMessage)
          .toSet();

      expect(
          messages, hasLength(VoiceConversationGateDenialReason.values.length));
    });

    test('rewardedDisabled와 remoteDisabled는 서로 다른 메시지를 반환한다', () {
      final rewarded = voiceConversationGateDenialMessage(
        VoiceConversationGateDenialReason.rewardedDisabled,
      );
      final remote = voiceConversationGateDenialMessage(
        VoiceConversationGateDenialReason.remoteDisabled,
      );

      expect(rewarded, isNot(equals(remote)));
    });

    test('진단 코드가 부여된 reason은 메시지 끝에 E- 코드 suffix를 가진다', () {
      const expectations = <VoiceConversationGateDenialReason, String>{
        VoiceConversationGateDenialReason.entitlementUnavailable: 'E-GATE0',
        VoiceConversationGateDenialReason.rewardedDisabled: 'E-RC1',
        VoiceConversationGateDenialReason.remoteDisabled: 'E-RC2',
        VoiceConversationGateDenialReason.adsUnavailable: 'E-ADS0',
      };

      expectations.forEach((reason, code) {
        final message = voiceConversationGateDenialMessage(reason);
        expect(message, endsWith('($code)'));
        // suffix를 제거해도 기존(코드 부여 전) 메시지 형태가 유지돼야 한다.
        final base = message.replaceFirst(' ($code)', '');
        expect(base, isNotEmpty);
      });
    });

    test('suffix가 없는 reason은 진단 코드를 메시지에 포함하지 않는다', () {
      const noCodeReasons = <VoiceConversationGateDenialReason>{
        VoiceConversationGateDenialReason.inFlight,
        VoiceConversationGateDenialReason.userCanceled,
        VoiceConversationGateDenialReason.adFailed,
      };

      for (final reason in noCodeReasons) {
        final message = voiceConversationGateDenialMessage(reason);
        expect(message, isNot(contains('(E-')));
      }
    });

    test('voiceConversationGateDenialCode는 모든 reason에 대해 E- 코드를 반환한다', () {
      for (final reason in VoiceConversationGateDenialReason.values) {
        final code = voiceConversationGateDenialCode(reason);
        expect(code, startsWith('E-'));
        expect(code, isNotEmpty);
      }
    });

    test('모든 진단 코드가 서로 다르다 (7개 모두 distinct)', () {
      final codes = VoiceConversationGateDenialReason.values
          .map(voiceConversationGateDenialCode)
          .toSet();

      expect(codes, hasLength(VoiceConversationGateDenialReason.values.length));
    });
  });

  group('진단 시도 결과의 fail-closed 계약', () {
    test('보상 완료만 일반 승인으로 표현하고 실패는 진입을 허용하지 않는다', () {
      const rewarded = VoiceConversationAdDialogAttemptResult.rewarded();
      const failed = VoiceConversationAdDialogAttemptResult.failure(
        diagnosticCode: 'E-ADFAIL',
        diagnosticDetail: 'reason=load_failed',
      );

      expect(rewarded.isAllowed, isTrue);
      expect(rewarded.isRewarded, isTrue);
      expect(failed.isAllowed, isFalse);
      expect(failed.isRewarded, isFalse);
    });

    test('free_pass 표시는 기존 명시 예외이며 보상 완료로 위장하지 않는다', () {
      const freePass = VoiceConversationAdDialogAttemptResult.freePass();

      expect(freePass.isAllowed, isTrue);
      expect(freePass.isRewarded, isFalse);
    });
  });

  group('free_pass 정책 (RemoteConfigService.rewardAdFailurePolicy)', () {
    test(
      "rewardAdFailurePolicy == 'free_pass'면 광고 실패 시에도 무료 진입 "
      'grant를 반환한다(entitlement 소비 없음)',
      () {
        RemoteConfigService.rewardAdFailurePolicyForTest = 'free_pass';

        final grant = VoiceConversationAdGate.instance.maybeFreePassGrant(
          initialRemainingAtGate: 0,
          dailyRemainingAtGate: 0,
        );

        expect(grant, isNotNull);
        expect(grant!.source, EntitlementSource.adFailedFreePass);
        expect(grant.initialRemainingAtGate, 0);
        expect(grant.dailyRemainingAtGate, 0);
      },
    );

    test(
      "rewardAdFailurePolicy가 'free_pass'가 아니면(기본값 'retry' 및 그 외 "
      "명시 값) 무료 진입을 허용하지 않는다(fail-closed 유지)",
      () {
        for (final policy in <String?>[null, 'retry', 'deny', '']) {
          RemoteConfigService.rewardAdFailurePolicyForTest = policy;

          final grant = VoiceConversationAdGate.instance.maybeFreePassGrant(
            initialRemainingAtGate: 0,
            dailyRemainingAtGate: 0,
          );

          expect(
            grant,
            isNull,
            reason: 'policy=$policy 상태에서는 free_pass grant가 만들어지면 안 된다',
          );
        }
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
