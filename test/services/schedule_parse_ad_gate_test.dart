import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';

/// [ScheduleParseAdGate]/[ScheduleParseEntitlementService]의 회귀 테스트
/// (H1: 신규 과금 게이트 테스트 0건 보강).
///
/// [VoiceConversationAdGate](voice_conversation_ad_gate_test.dart)와 동일한
/// 전략을 따른다:
/// - peek() 실패(fail-closed) 분기는 `ScheduleParseAdGate`의 delegate를
///   주입하지 않고, `ScheduleParseEntitlementService`의 delegate만 주입해
///   실제 `_runGate` 경로(peek 실패 분기는 RC/광고 SDK에 닿기 전에 끝남)를
///   그대로 검증한다.
/// - 무료 잔여가 남아 즉시 진입하는 분기도 같은 방식(실제 `_runGate`,
///   entitlement peek delegate만 주입)으로 검증한다(RC/광고 SDK에 닿기 전에
///   반환됨).
/// - 광고 다이얼로그가 개입하는 분기(무료 소진 → 광고 시청 완료/취소)는
///   Firebase Remote Config·AdConsentService·AdService 같은 정적 SDK
///   의존성 때문에 실제 `_runGate`를 단위 테스트로 몰아붙이기 어려워
///   `ScheduleParseAdGate`의 delegate로 시뮬레이션한다
///   (voice_conversation_ad_gate_test.dart의 `_ScenarioAdGateDelegate`와
///   동일 패턴).
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    ScheduleParseAdGate.instance.delegateForTest = null;
    ScheduleParseEntitlementService.instance.delegateForTest = null;
    RemoteConfigService.rewardAdFailurePolicyForTest = null;
    ScheduleParseAdGate.instance.lastFreePassApplied = false;
  });

  group('실제 _runGate 경로 (ScheduleParseAdGate delegate 미주입)', () {
    testWidgets(
      '1) peek() 실패(null) → fail-closed로 진입 거부(entitlementUnavailable)',
      (tester) async {
        ScheduleParseEntitlementService.instance.delegateForTest =
            _FakeEntitlementDelegate(peekResult: null);

        ScheduleParseEntryGrant? captured;
        ScheduleParseGateDenialReason? deniedReason;

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    unawaited(
                      ScheduleParseAdGate.instance.tryEnterScheduleParse(
                        context: context,
                        onEnterAllowed: (grant) => captured = grant,
                        onDenied: (reason) => deniedReason = reason,
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
        expect(
          deniedReason,
          ScheduleParseGateDenialReason.entitlementUnavailable,
        );
        expect(
          ScheduleParseAdGate.instance.lastDenialReason,
          ScheduleParseGateDenialReason.entitlementUnavailable,
        );
      },
    );

    testWidgets(
      '2) peek() 결과 잔여>0(requiresAd=false) → 광고 다이얼로그 없이 즉시 '
      '진입 허용(dailyFree)',
      (tester) async {
        ScheduleParseEntitlementService.instance.delegateForTest =
            _FakeEntitlementDelegate(
          peekResult: const ScheduleParseEntitlementPeek(
            dailyRemaining: 2,
            requiresAd: false,
          ),
        );

        ScheduleParseEntryGrant? captured;
        ScheduleParseGateDenialReason? deniedReason;

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    unawaited(
                      ScheduleParseAdGate.instance.tryEnterScheduleParse(
                        context: context,
                        onEnterAllowed: (grant) => captured = grant,
                        onDenied: (reason) => deniedReason = reason,
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
        // 다이얼로그가 뜨지 않으므로 pumpAndSettle이 아니라도 즉시 완료된다.
        await tester.pump();

        expect(deniedReason, isNull);
        expect(captured, isNotNull);
        expect(captured!.source, ScheduleParseEntitlementSource.dailyFree);
        expect(captured!.dailyRemainingAtGate, 2);
        // 광고 다이얼로그가 뜨지 않았음을 확인(즉시 진입).
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  });

  group('광고 다이얼로그 분기 (ScheduleParseAdGate delegate 경유)', () {
    testWidgets(
      '3) peek() 결과 잔여=0 → 다이얼로그 표시 → 광고 시청 완료 → 진입 허용'
      '(adRewarded)',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.allow(
            source: ScheduleParseEntitlementSource.adRewarded,
            dailyRemainingAtGate: 0,
          ),
        );

        expect(captured, isNotNull);
        expect(
          captured!.source,
          ScheduleParseEntitlementSource.adRewarded,
        );
        expect(captured.dailyRemainingAtGate, 0);
      },
    );

    testWidgets(
      '4) 잔여=0 상태에서 사용자가 다이얼로그에서 취소 → 진입 거부'
      '(userCanceled)',
      (tester) async {
        final captured = await _runScenario(
          tester,
          delegate: _ScenarioAdGateDelegate.deny(
            reason: ScheduleParseGateDenialReason.userCanceled,
          ),
        );

        expect(captured, isNull);
      },
    );
  });

  group('consume() 소비 계약', () {
    test(
      '5) 진입 승인 후 consume()이 grant의 sessionId로 정확히 1회 호출된다',
      () async {
        final fake = _FakeEntitlementDelegate(
          peekResult: const ScheduleParseEntitlementPeek(
            dailyRemaining: 0,
            requiresAd: true,
          ),
          consumeResult: const ScheduleParseConsumeResult(
            source: 'ad_required',
            dailyRemaining: 0,
          ),
        );
        ScheduleParseEntitlementService.instance.delegateForTest = fake;

        // 게이트가 승인한 진입(grant)을 시뮬레이션 — 실제 화면
        // (ConfirmScreen._hydrateParsedSchedule)이 하는 것과 동일하게
        // grant.sessionId를 그대로 consume()에 전달한다.
        const grant = ScheduleParseEntryGrant(
          sessionId: 'schedule_parse_session_test-1',
          source: ScheduleParseEntitlementSource.adRewarded,
          dailyRemainingAtGate: 0,
        );

        await ScheduleParseEntitlementService.instance.consume(
          grant.sessionId,
        );

        expect(fake.consumeCallCount, 1);
        expect(fake.lastConsumeSessionId, grant.sessionId);
      },
    );

    test('연속 호출은 서로 다른 sessionId를 생성한다', () {
      final ids = List<String>.generate(
        20,
        (_) => ScheduleParseSessionIdGenerator.next(),
      );

      expect(ids.toSet().length, ids.length);
    });

    test('sessionId는 비어있지 않은 문자열이다', () {
      final id = ScheduleParseSessionIdGenerator.next();

      expect(id, isNotEmpty);
      expect(id, startsWith('schedule_parse_session_'));
    });
  });

  group('free_pass 정책 (RemoteConfigService.rewardAdFailurePolicy)', () {
    test(
      "rewardAdFailurePolicy == 'free_pass'면 광고 실패 시에도 무료 진입 "
      'grant를 반환하고, consume()은 호출하지 않는다',
      () async {
        RemoteConfigService.rewardAdFailurePolicyForTest = 'free_pass';

        final fake = _FakeEntitlementDelegate(
          peekResult: const ScheduleParseEntitlementPeek(
            dailyRemaining: 0,
            requiresAd: true,
          ),
        );
        ScheduleParseEntitlementService.instance.delegateForTest = fake;

        final grant = ScheduleParseAdGate.instance.maybeFreePassGrant(
          dailyRemainingAtGate: 0,
        );

        expect(grant, isNotNull);
        expect(
          grant!.source,
          ScheduleParseEntitlementSource.adFailedFreePass,
        );
        expect(grant.dailyRemainingAtGate, 0);
        expect(ScheduleParseAdGate.instance.lastFreePassApplied, isTrue);
        // maybeFreePassGrant()는 entitlement 서비스를 전혀 건드리지 않는다
        // (peek/consume 어느 쪽도 호출하지 않음) — 광고도 무료횟수도 소진된
        // 상태의 예외 통과이지 정상 무료소진이 아니므로 소비가 없어야 한다.
        expect(fake.consumeCallCount, 0);
      },
    );

    test(
      "rewardAdFailurePolicy가 'free_pass'가 아니면(기본값 'retry' 및 그 외 "
      "명시 값) 무료 진입을 허용하지 않는다(fail-closed 유지)",
      () {
        for (final policy in <String?>[null, 'retry', 'deny', '']) {
          RemoteConfigService.rewardAdFailurePolicyForTest = policy;

          final grant = ScheduleParseAdGate.instance.maybeFreePassGrant(
            dailyRemainingAtGate: 3,
          );

          expect(
            grant,
            isNull,
            reason: 'policy=$policy 상태에서는 free_pass grant가 만들어지면 안 된다',
          );
        }
        expect(ScheduleParseAdGate.instance.lastFreePassApplied, isFalse);
      },
    );
  });
}

/// [_ScenarioAdGateDelegate]를 주입한 뒤 tryEnterScheduleParse를 1회
/// 호출하고, onEnterAllowed로 전달된 grant(또는 null)를 반환하는 헬퍼.
Future<ScheduleParseEntryGrant?> _runScenario(
  WidgetTester tester, {
  required ScheduleParseAdGateDelegate delegate,
}) async {
  ScheduleParseAdGate.instance.delegateForTest = delegate;

  ScheduleParseEntryGrant? captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () {
              unawaited(
                ScheduleParseAdGate.instance.tryEnterScheduleParse(
                  context: context,
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
/// - [allow]: 진입을 즉시 허용하고 지정한
///   [ScheduleParseEntitlementSource]/잔여값으로 grant를 만들어
///   onEnterAllowed에 전달한다(실제 `_runGate`가 해당 분기에서 만드는
///   grant와 동일한 형태).
/// - [deny]: 진입을 거부한다(onEnterAllowed를 호출하지 않고, onDenied만
///   호출한다). 실제 `_runGate`의 광고 취소/실패 분기와 동일한 결과.
class _ScenarioAdGateDelegate implements ScheduleParseAdGateDelegate {
  const _ScenarioAdGateDelegate._({
    required this.allowed,
    this.source,
    this.dailyRemainingAtGate = 0,
    this.denialReason,
  });

  factory _ScenarioAdGateDelegate.allow({
    required ScheduleParseEntitlementSource source,
    int dailyRemainingAtGate = 0,
  }) {
    return _ScenarioAdGateDelegate._(
      allowed: true,
      source: source,
      dailyRemainingAtGate: dailyRemainingAtGate,
    );
  }

  factory _ScenarioAdGateDelegate.deny({
    ScheduleParseGateDenialReason reason =
        ScheduleParseGateDenialReason.userCanceled,
  }) {
    return _ScenarioAdGateDelegate._(allowed: false, denialReason: reason);
  }

  final bool allowed;
  final ScheduleParseEntitlementSource? source;
  final int dailyRemainingAtGate;
  final ScheduleParseGateDenialReason? denialReason;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  }) async {
    if (!allowed) {
      onDenied?.call(denialReason ?? ScheduleParseGateDenialReason.userCanceled);
      return;
    }
    onEnterAllowed(
      ScheduleParseEntryGrant(
        sessionId: ScheduleParseSessionIdGenerator.next(),
        source: source!,
        dailyRemainingAtGate: dailyRemainingAtGate,
      ),
    );
  }
}

/// [ScheduleParseEntitlementService]의 RPC 호출을 대체하는 fake delegate.
///
/// [consumeCallCount]/[lastConsumeSessionId]로 consume() 호출 횟수와 마지막
/// sessionId를 기록해 "정확히 1회, 올바른 sessionId로 호출됨"을 검증할 수
/// 있게 한다.
class _FakeEntitlementDelegate implements ScheduleParseEntitlementDelegate {
  _FakeEntitlementDelegate({this.peekResult, this.consumeResult});

  final ScheduleParseEntitlementPeek? peekResult;
  final ScheduleParseConsumeResult? consumeResult;

  int consumeCallCount = 0;
  String? lastConsumeSessionId;

  @override
  Future<ScheduleParseEntitlementPeek?> peek() async => peekResult;

  @override
  Future<ScheduleParseConsumeResult?> consume(String sessionId) async {
    consumeCallCount += 1;
    lastConsumeSessionId = sessionId;
    return consumeResult;
  }
}
