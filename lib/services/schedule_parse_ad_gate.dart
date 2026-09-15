import 'dart:async';

import 'package:flutter/widgets.dart';

import '../widgets/rewarded_ad_dialog.dart';
import 'ad_consent_service.dart';
import 'ad_service.dart';
import 'remote_config_service.dart';
import 'schedule_parse_entitlement.dart';

/// AI 일정분석(GPT 파싱) 진입 게이트.
///
/// [VoiceConversationAdGate](voice_conversation_ad_gate.dart)와 동일한 정책
/// 골격을 그대로 따른다. 다만 이 기능은 [ScheduleParseEntitlementService]의
/// RPC(peek/consume)가 서버 인증 컨텍스트(auth.uid())로 사용자를 식별하므로
/// `userId` 파라미터를 받지 않는다.
///
/// 1. 확인화면(ConfirmScreen) 진입 시 GPT 파싱이 필요한 경우 호출된다.
/// 2. 하루 무료 잔여([ScheduleParseEntitlementService.peek])가 남아 있으면
///    광고 다이얼로그 없이 즉시 진입을 허용한다.
/// 3. 무료 잔여가 소진된 경우에만 리워드 광고
///    다이얼로그([RewardedAdDialog])를 띄우고, 사용자가 시청을 완료했을
///    때만 진입을 허용한다.
/// 4. 광고 취소·실패·요청 불가·기능 비활성은 모두 진입을 거부한다.
///
/// 설계 메모(voice_conversation_ad_gate.dart와 동일 원칙):
/// - 이 게이트는 진입 시점에 무료 사용 횟수를 **소비하지 않는다**
///   (부작용 없는 [ScheduleParseEntitlementService.peek]만 사용). 실제 소비는
///   화면에서 GPT 파싱이 실제로 시작될 때
///   [ScheduleParseEntitlementService.consume]으로 호출자가 처리한다.
/// - 진입이 허용되면 [ScheduleParseEntryGrant]를 만들어 [onEnterAllowed]로
///   전달한다. grant에는 이 진입을 유일하게 식별하는 `sessionId`(추후 consume
///   호출 시 멱등 키로 재사용 가능)와 승인 근거([ScheduleParseEntitlementSource])가
///   담긴다.
/// - peek() 실패(RPC 오류 등)는 "무료 잔여를 알 수 없음"이므로, 광고 우회도
///   허용하지 않고 fail-closed로 진입을 거부한다.
/// - 동시 호출 안전: 같은 진입 흐름에서 두 번 다이얼로그가 뜨는 것을 막기
///   위해 인플라이트 가드(_inFlight)로 보호한다.
class ScheduleParseAdGate {
  ScheduleParseAdGate._();

  static final ScheduleParseAdGate instance = ScheduleParseAdGate._();

  /// 테스트/QA가 게이트 결정을 주입할 수 있도록 하는 백도어.
  /// - null이면 본 클래스의 정책 로직을 그대로 사용.
  ScheduleParseAdGateDelegate? _delegateForTest;
  set delegateForTest(ScheduleParseAdGateDelegate? value) {
    _delegateForTest = value;
  }

  /// 동일 화면의 tryEnterScheduleParse 동시 호출을 거부.
  bool _inFlight = false;

  @visibleForTesting
  ScheduleParseGateDenialReason? lastDenialReason;

  @visibleForTesting
  ScheduleParseEntitlementPeek? lastPeek;

  /// 직전 `_runGate` 실행에서 rewardAdFailurePolicy='free_pass' 정책에
  /// 따라 광고 실패를 무료 진입으로 넘겨준 경우 true. 테스트/추적용.
  @visibleForTesting
  bool lastFreePassApplied = false;

  /// 실제 진입 게이트. UI 컨텍스트(context)와 진입 허용 시 호출될 콜백을 받는다.
  /// - 광고/실패 정책 분기는 이 메서드 안에서 끝낸다.
  /// - 진입이 최종 거부된 경우에는 [onEnterAllowed]를 호출하지 않는다.
  /// - [onEnterAllowed]는 이 진입을 승인한 [ScheduleParseEntryGrant]를
  ///   받는다. 이 게이트 자체는 무료 횟수를 소비하지 않는다(peek만 사용) —
  ///   실제 소비는 grant.sessionId로 [ScheduleParseEntitlementService.consume]을
  ///   호출하는 화면 쪽 책임이다.
  /// - [onAdProgress]는 광고 표시 단계('loading'/'shown'/'completed'/
  ///   'failed'/'cancelled')를 [AdService.showForParseSchedule]로부터 그대로
  ///   전달한다(무료 잔여로 즉시 진입한 경우에는 호출되지 않는다).
  Future<void> tryEnterScheduleParse({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    void Function(String stage)? onAdProgress,
  }) async {
    lastDenialReason = null;
    lastFreePassApplied = false;
    if (_inFlight) {
      // 이미 진행 중이면 사일런트하게 무시(사용자 인지 불필요).
      return;
    }
    _inFlight = true;
    try {
      await _runGate(
        context: context,
        onEnterAllowed: onEnterAllowed,
        onDenied: onDenied,
        onAdProgress: onAdProgress,
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _runGate({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    void Function(String stage)? onAdProgress,
  }) async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      await delegate.tryEnter(
        context: context,
        onEnterAllowed: onEnterAllowed,
        onDenied: onDenied,
        gate: this,
      );
      return;
    }

    // 1. 무료 잔여 횟수 조회(부작용 없음).
    final peek = await ScheduleParseEntitlementService.instance.peek();
    lastPeek = peek;
    if (peek == null) {
      // 잔여를 확인하지 못한 상태에서는 광고로 우회하지 않는다.
      // 서버 상태를 확인할 수 있을 때만 무료/광고 분기를 결정한다.
      _deny(ScheduleParseGateDenialReason.entitlementUnavailable, onDenied);
      return;
    }
    if (!peek.requiresAd) {
      // 무료 잔여 있음 → 즉시 진입(소비는 화면 쪽에서 처리).
      onEnterAllowed(
        _grant(
          ScheduleParseEntitlementSource.dailyFree,
          dailyRemainingAtGate: peek.dailyRemaining,
        ),
      );
      return;
    }

    // 2. 무료 소진 → 광고가 필수다. 광고 기능이 꺼져 있으면 우회 진입시키지
    // 않고 운영 설정을 고친 뒤 다시 시도하도록 막는다. 단, RC fetch가
    // 실패한 상태라면(기본값을 잘못 읽었을 수 있음) 강제 재시도 1회 후
    // 재평가한다(voice_conversation_ad_gate.dart와 동일 정책).
    if (!RemoteConfigService.rewardedAdEnabled) {
      if (!RemoteConfigService.lastFetchSucceeded) {
        final retrySucceeded = await RemoteConfigService.retryFetchIfFailed();
        if (retrySucceeded && !RemoteConfigService.rewardedAdEnabled) {
          _deny(ScheduleParseGateDenialReason.rewardedDisabled, onDenied);
          return;
        }
        // 재시도 성공(값이 true로 바뀜) 또는 재시도 자체 실패(기본값 true) →
        // 어느 쪽이든 통과시켜 아래 광고 다이얼로그로 진행한다.
      } else {
        _deny(ScheduleParseGateDenialReason.rewardedDisabled, onDenied);
        return;
      }
    }

    // 3. 광고 요청 가능 여부(동의/네트워크 등) 확인.
    final adsOk = await AdConsentService.instance.canRequestAdsLive;
    if (!adsOk) {
      _deny(ScheduleParseGateDenialReason.adsUnavailable, onDenied);
      return;
    }

    if (!context.mounted) {
      _deny(ScheduleParseGateDenialReason.userCanceled, onDenied);
      return;
    }

    // 4. 광고 다이얼로그. ConfirmScreen이 아직 push 전환 애니메이션 중일 때
    // 다이얼로그를 띄우면 배경(barrier)이 슬라이드 중인 페이지 위에 겹쳐
    // 그려지는 렌더 결함이 있어(P6), 전환이 끝날 때까지 기다린 뒤 띄운다.
    await waitForRouteTransitionToComplete(context);
    if (!context.mounted) {
      _deny(ScheduleParseGateDenialReason.userCanceled, onDenied);
      return;
    }
    final confirmed = await RewardedAdDialog.show(context);
    if (confirmed != true) {
      _deny(ScheduleParseGateDenialReason.userCanceled, onDenied);
      return;
    }

    // 5. 광고 표시.
    final requestId = _requestId();
    final watched = await AdService.instance.showForParseSchedule(
      requestId: requestId,
      onProgress: onAdProgress,
    );
    if (watched) {
      onEnterAllowed(
        _grant(
          ScheduleParseEntitlementSource.adRewarded,
          dailyRemainingAtGate: peek.dailyRemaining,
        ),
      );
      return;
    }

    // 광고 실패는 원칙적으로 진입 거부다. 단, 운영 설정
    // (RemoteConfigService.rewardAdFailurePolicy)이 명시적으로 'free_pass'로
    // 설정된 경우에만 예외적으로 무료 진입을 허용한다. 이 경우 consume()은
    // 호출하지 않는다 — 광고도 무료횟수도 소진된 상태에서의 예외 통과이지
    // 정상적인 무료소진이 아니다(호출자가 consume을 호출하지 않도록
    // 화면 쪽에서 grant.source로 분기해야 한다).
    final freePassGrant = maybeFreePassGrant(
      dailyRemainingAtGate: peek.dailyRemaining,
    );
    if (freePassGrant != null) {
      onEnterAllowed(freePassGrant);
      return;
    }

    _deny(ScheduleParseGateDenialReason.adFailed, onDenied);
  }

  /// RemoteConfigService.rewardAdFailurePolicy가 명시적으로 'free_pass'로
  /// 설정된 경우에만 무료 진입 grant를 만들어 반환한다(그 외에는 null).
  ///
  /// `_runGate`의 광고 실패 분기가 실제로 사용하는 로직을 그대로 노출한
  /// 것이다 — Firebase/AdService 의존 없이 정책 분기를 직접 단위 테스트할
  /// 수 있도록 `@visibleForTesting`으로 공개한다.
  @visibleForTesting
  ScheduleParseEntryGrant? maybeFreePassGrant({
    required int dailyRemainingAtGate,
  }) {
    if (!_isFreePassPolicy()) {
      return null;
    }
    lastFreePassApplied = true;
    return _grant(
      ScheduleParseEntitlementSource.adFailedFreePass,
      dailyRemainingAtGate: dailyRemainingAtGate,
    );
  }

  /// RemoteConfigService.rewardAdFailurePolicy가 명시적으로 'free_pass'로
  /// 설정됐는지 확인한다(대소문자 무관). 기본값('retry') 또는 그 외 값은
  /// false — fail-closed 유지.
  bool _isFreePassPolicy() {
    return RemoteConfigService.rewardAdFailurePolicy.trim().toLowerCase() ==
        'free_pass';
  }

  void _deny(
    ScheduleParseGateDenialReason reason,
    void Function(ScheduleParseGateDenialReason reason)? callback,
  ) {
    lastDenialReason = reason;
    callback?.call(reason);
  }

  ScheduleParseEntryGrant _grant(
    ScheduleParseEntitlementSource source, {
    int dailyRemainingAtGate = 0,
  }) {
    return ScheduleParseEntryGrant(
      sessionId: ScheduleParseSessionIdGenerator.next(),
      source: source,
      dailyRemainingAtGate: dailyRemainingAtGate,
    );
  }

  String _requestId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = now.toRadixString(36);
    return 'schedule_parse_ad_$now-$random';
  }
}

/// [context]가 속한 [ModalRoute]의 진입/전환 애니메이션이 끝날 때까지
/// 기다린다.
///
/// 배경(P6): [ConfirmScreen]의 `initState`가 첫 프레임 렌더 직후
/// (`addPostFrameCallback`) 광고 게이트를 실행하는데, GoRouter가 기본으로
/// 쓰는 push 전환(약 300ms 슬라이드)은 1프레임(약 16ms)보다 훨씬 길게
/// 진행 중이다. 이 상태에서 [showDialog]로 다이얼로그를 띄우면 다이얼로그의
/// barrier/배경이 아직 슬라이드 애니메이션 중인 페이지 위에 겹쳐 그려져
/// 시각적 렌더 결함이 발생한다. 이 함수는 해당 라우트의 전환 애니메이션이
/// [AnimationStatus.completed](또는 이미 되돌아간 [AnimationStatus.dismissed])
/// 상태가 될 때까지 대기해, 다이얼로그가 페이지 전환이 끝난 뒤에만
/// 표시되도록 한다.
///
/// - [ModalRoute]를 찾을 수 없거나 애니메이션이 이미 끝난 상태면 즉시
///   반환한다(대부분의 재시도 흐름은 이 경로를 탄다 — 사용자가 버튼을 눌러
///   호출하는 시점에는 진입 전환이 이미 끝나 있다).
/// - [fallbackTimeout] 안에 상태 전이가 오지 않으면(예: 커스텀 전환이 있어
///   completed/dismissed로 끝나지 않는 특수 케이스) 타임아웃으로 대기를
///   포기하고 진행한다 — 화면이 무한정 멈추는 것을 방지하는 안전장치다.
@visibleForTesting
Future<void> waitForRouteTransitionToComplete(
  BuildContext context, {
  Duration fallbackTimeout = const Duration(milliseconds: 400),
}) async {
  final animation = ModalRoute.of(context)?.animation;
  if (animation == null || animation.isCompleted) {
    return;
  }
  final completer = Completer<void>();
  void listener(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  animation.addStatusListener(listener);
  try {
    await completer.future.timeout(fallbackTimeout, onTimeout: () {});
  } finally {
    animation.removeStatusListener(listener);
  }
}

enum ScheduleParseGateDenialReason {
  entitlementUnavailable,
  rewardedDisabled,
  adsUnavailable,
  userCanceled,
  adFailed,
}

/// [ScheduleParseGateDenialReason]별 사용자 안내 메시지.
///
/// ConfirmScreen은 이 메시지를 `_hydrateMessage`에 채워 넣고 수동 입력으로
/// 폴백한다(voice_conversation_ad_gate.dart의
/// `voiceConversationGateDenialMessage`와 동일 패턴).
String scheduleParseGateDenialMessage(ScheduleParseGateDenialReason reason) {
  switch (reason) {
    case ScheduleParseGateDenialReason.entitlementUnavailable:
      return '무료 사용 횟수를 확인하지 못했어요. 잠시 후 다시 시도하거나 직접 입력해 주세요.';
    case ScheduleParseGateDenialReason.rewardedDisabled:
      return 'AI일정분석 광고 설정이 꺼져 있어요. 직접 입력해 주세요.';
    case ScheduleParseGateDenialReason.adsUnavailable:
      return '광고를 불러올 수 없어 AI일정분석을 시작하지 못했어요. 직접 입력해 주세요.';
    case ScheduleParseGateDenialReason.userCanceled:
      return '광고 없이 진행해요. 직접 입력해 주세요.';
    case ScheduleParseGateDenialReason.adFailed:
      return '광고를 완료하지 못했어요. 내용을 직접 수정해 주세요.';
  }
}

/// 게이트 로직을 테스트/QA가 주입할 수 있도록 하는 인터페이스.
abstract class ScheduleParseAdGateDelegate {
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  });
}
