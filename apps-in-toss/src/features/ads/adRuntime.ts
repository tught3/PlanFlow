/**
 * P9(라우터 배선): 실제 TossAds SDK/Storage를 조립하는 유일한 곳.
 *
 * adService.ts/adState.ts는 SDK/Storage를 직접 import하지 않고 `AdSdk`/
 * `AdStatePort` 인터페이스로 주입받는다(각 파일 상단 주석 참고 - 테스트
 * 가능성과 안전 격리를 위한 설계). 이 파일이 그 인터페이스를 실제
 * `@apps-in-toss/web-framework`의 `TossAds`/`loadFullScreenAd`/
 * `showFullScreenAd`/`isMinVersionSupported`/`Storage`로 채워 넣는 유일한
 * 조립 지점이다 - 앱 전체에서 이 실제 SDK 함수들을 직접 import하는 곳은
 * 여기뿐이어야 한다(BannerSlot/router.tsx 등 화면 쪽은 이 파일이 export하는
 * `realAdSdk`/`realAdStatePort`를 주입받기만 한다).
 *
 * 이 파일은 또한 세션 스코프 광고 상태(adSession.ts)를 모듈 레벨 싱글턴으로
 * 들고 있다 - router.tsx의 `activeEventRepository`(모듈 로드 시점 1회 평가)와
 * 동일한 패턴이다. ES 모듈은 애플리케이션 생명주기 동안 1회만 평가되므로,
 * 이 싱글턴은 페이지 전체 재로드(=세션 재시작) 전까지는 라우트 이동과
 * 무관하게 유지된다 - adSession.ts가 요구하는 "페이지가 새로 로드되면 매번
 * 초기 상태로 리셋"이라는 계약과 정확히 일치한다. React Context를 별도로
 * 두지 않은 이유도 이 계약이 모듈 싱글턴만으로 자연스럽게 충족되기
 * 때문이다.
 */

import {
  isMinVersionSupported,
  loadFullScreenAd,
  showFullScreenAd,
  Storage,
  TossAds,
} from '@apps-in-toss/web-framework';

import { isSameKstDay } from '../../domain/datetime';
import type { AdSdk } from './adService';
import type { AdFrequencyState, AdStatePort } from './adState';
import type { AdSessionAction, AdSessionState } from './adSession';
import { createAdSessionState, nextAdSessionState } from './adSession';
import type { InterstitialEligibilityContext } from './adPolicy';

/**
 * 실제 TossAds SDK로 채운 `AdSdk`. adService.ts의 모든 함수(`initializeAds`,
 * `attachBannerToContainer`, `loadInterstitial`, `showInterstitial`,
 * `showRewardedAd`)에 그대로 주입할 수 있다.
 */
export const realAdSdk: AdSdk = {
  initialize: (options) => TossAds.initialize(options),
  isInitializeSupported: () => TossAds.initialize.isSupported(),
  isMinVersionSupported: (minVersions) => isMinVersionSupported(minVersions),
  attachBanner: (adGroupId, target, options) => TossAds.attachBanner(adGroupId, target, options),
  loadFullScreenAd: (params) => loadFullScreenAd(params),
  showFullScreenAd: (params) => showFullScreenAd(params),
};

/** 실제 Toss `Storage`로 채운 `AdStatePort`. adState.ts 함수에 그대로 주입한다. */
export const realAdStatePort: AdStatePort = {
  getItem: (key) => Storage.getItem(key),
  setItem: (key, value) => Storage.setItem(key, value),
};

/**
 * 전면 광고 in-flight 락. router.tsx의 전면 광고 effect는 `cancelled`
 * 플래그로 "이전 effect 인스턴스"가 자기 자신의 결과를 반영하지 못하게
 * 막지만, 그 플래그는 effect 인스턴스마다 독립된 클로저 변수라 "서로 다른
 * 두 effect 인스턴스가 동시에 살아있는 좁은 창"(예: 두 정착 라우트 사이를
 * 빠르게 왕복 이동)을 막지 못한다 - 둘 다 아직 취소되지 않은 채로
 * `loadAdFrequencyState`를 각자 await하고, 아직 영속화되지 않은 같은
 * frequency 스냅샷을 근거로 각자 적격성을 판단해 전면 광고를 두 번 시도할
 * 수 있다(하루 1회/24시간 쿨다운 보장이 이 좁은 창에서 깨질 위험).
 *
 * 이 모듈 레벨 싱글턴 락이 그 창을 막는다 - 두 번째 시도는 "적격하지
 * 않음"과 동일하게 취급되어 즉시 포기한다(throw하지 않음).
 */
let interstitialInFlight = false;

/**
 * 전면 광고 시도 슬롯을 선점한다. 이미 다른 in-flight 시도가 있으면
 * `false`를 반환한다(호출부는 이를 "지금은 적격하지 않음"과 동일하게
 * 취급해 조용히 포기해야 한다 - throw하지 않는다).
 */
export function tryAcquireInterstitialSlot(): boolean {
  if (interstitialInFlight) {
    return false;
  }
  interstitialInFlight = true;
  return true;
}

/**
 * 전면 광고 시도 슬롯을 반환한다. `tryAcquireInterstitialSlot()`으로 슬롯을
 * 선점한 시도는 성공/실패/조기 종료 등 모든 경로에서 반드시(`finally`로)
 * 이 함수를 호출해야 한다 - 그렇지 않으면 다음 시도가 영구히 막힌다.
 */
export function releaseInterstitialSlot(): void {
  interstitialInFlight = false;
}

/**
 * 세션 스코프 광고 상태 싱글턴. 모듈 로드 시점(=페이지 로드/앱 부트스트랩
 * 시점)에 정확히 한 번만 `createAdSessionState()`로 초기화된다.
 */
let adSessionState: AdSessionState = createAdSessionState();

/** 현재 세션 스코프 광고 상태를 읽는다. */
export function getAdSessionState(): AdSessionState {
  return adSessionState;
}

/**
 * 세션 스코프 광고 상태에 액션을 적용한다(순수 리듀서 nextAdSessionState를
 * 호출해 싱글턴을 교체). 의미 있는 행동 완료(meaningful-action), 다른 모달
 * 열림/닫힘(modal-open/modal-close) 이벤트를 라우터/화면 콜백에서 이 함수로
 * 통지한다.
 */
export function dispatchAdSessionAction(action: AdSessionAction): void {
  adSessionState = nextAdSessionState(adSessionState, action);
}

/**
 * 세션 스코프 상태(adSession.ts)와 영속 빈도 상태(adState.ts)를 조합해
 * adPolicy.ts가 요구하는 `InterstitialEligibilityContext`를 만드는 순수
 * 함수.
 *
 * `isEditingEvent`/`isDeleteConfirming`/`isSavePending`/`isErrorRecovering`은
 * 항상 `false`로 고정한다 - 이 값들은 호출부(router.tsx의 AppLayout)가
 * interstitialRoutes.ts의 `isSettledRouteForInterstitial`로 이미 "이 경로에
 * 도달했다는 사실 자체가 그 중간 상태가 아님을 보장"한 뒤에만 이 함수를
 * 부르기 때문이다(interstitialRoutes.ts 상단 주석 참고) - 호출부 계약이
 * 깨지지 않는 한 이 값들은 실제로 항상 false다.
 *
 * `adState.adState.interstitialCountToday`는 저장된
 * `lastInterstitialAt`이 `now`와 같은 KST 날짜일 때만 저장된 카운트를
 * 쓰고, 날짜가 바뀌었으면(또는 아직 한 번도 노출된 적 없으면) 0으로
 * 취급한다 - adState.ts의 `recordInterstitialShown`이 날짜가 바뀌면
 * 카운트를 1로 리셋하는 것과 대칭되는 읽기 쪽 규칙이다.
 */
export function buildInterstitialEligibilityContext(input: {
  authenticated: boolean;
  session: AdSessionState;
  frequency: AdFrequencyState;
  now: Date;
}): InterstitialEligibilityContext {
  const { authenticated, session, frequency, now } = input;

  const interstitialCountToday =
    frequency.lastInterstitialAt !== null && isSameKstDay(now, frequency.lastInterstitialAt)
      ? frequency.interstitialCountForDay
      : 0;

  return {
    authenticated,
    isAuthScreen: false,
    isEditingEvent: false,
    isDeleteConfirming: false,
    isSavePending: false,
    isErrorRecovering: false,
    modalOpen: session.modalOpen,
    session: {
      sessionStartedAt: session.sessionStartedAt,
      meaningfulActionCompleted: session.meaningfulActionCompleted,
    },
    adState: {
      firstUsedAt: frequency.firstUsedAt,
      lastInterstitialAt: frequency.lastInterstitialAt,
      interstitialCountToday,
    },
  };
}
