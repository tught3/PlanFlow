/**
 * TossAds SDK 어댑터 - 이 모듈이 SDK(`TossAds`/`loadFullScreenAd`/`showFullScreenAd`)를
 * 직접 건드리는 유일한 곳이다. 화면 컴포넌트는 절대 SDK 함수를 직접 호출하지 않고
 * 반드시 이 모듈의 함수를 통해서만 광고를 다룬다.
 *
 * 이 파일은 안전 격리 계층(safety-critical isolation layer)이다: 광고 SDK가
 * 어떤 형태로 실패하든(동기 throw, onError 콜백, no-fill, 무응답 타임아웃) 그
 * 실패가 일정 관리 등 앱의 핵심 기능을 절대 깨뜨리면 안 된다. 그래서 이 파일이
 * export하는 모든 함수는 다음을 지킨다:
 *   - 동기적으로 throw하지 않는다.
 *   - 반환하는 Promise를 reject하지 않는다(항상 resolve만 한다).
 *   - 호출부가 try/catch로 감쌀 필요가 없다.
 *
 * SDK 함수는 실제로 import해서 쓰지 않고 `AdSdk` 인터페이스로 주입받는다 -
 * 테스트에서 가짜(fake) SDK로 load-fail/timeout/show-fail/no-fill/dismiss/throw
 * 등 모든 실패 모드를 재현할 수 있게 하기 위함이다. 타입만 실제 SDK 선언
 * (`node_modules/@apps-in-toss/web-framework/dist/index.d.ts`)에서 가져와
 * 시그니처를 정확히 맞춘다.
 */

import type {
  LoadFullScreenAdEvent,
  LoadFullScreenAdOptions,
  ShowFullScreenAdEvent,
  ShowFullScreenAdOptions,
  TossAdsAttachBannerOptions,
  TossAdsAttachBannerResult,
  TossAdsInitializeOptions,
} from '@apps-in-toss/web-framework';

import { MIN_TOSS_APP_VERSION } from './adConfig';

/** initialize/load/show 콜백이 끝내 안 오는 경우를 대비한 안전 타임아웃(ms). */
const INITIALIZE_TIMEOUT_MS = 10_000;
const LOAD_TIMEOUT_MS = 10_000;
const SHOW_TIMEOUT_MS = 15_000;

/**
 * 이 모듈이 실제로 호출하는 SDK 표면만 담은 최소 인터페이스.
 * 필드 시그니처는 `node_modules/@apps-in-toss/web-framework/dist/index.d.ts`의
 * `TossAds.initialize`/`TossAds.attachBanner`/`loadFullScreenAd`/`showFullScreenAd`/
 * `isMinVersionSupported`와 정확히 맞춘다. `TossAds.destroyAll`은 이 파일의 어떤
 * 함수도 호출하지 않으므로(배너 정리는 attachBanner가 돌려주는 result.destroy만
 * 사용) 인터페이스에 포함하지 않는다 - 필요해지면 그때 여기에 추가한다.
 */
export interface AdSdk {
  /** `TossAds.initialize` - 동기 함수이며, 실제 성공/실패는 callbacks로 통지된다. */
  initialize: (options: TossAdsInitializeOptions) => void;
  /** `TossAds.initialize.isSupported` - 미주입 시 이 체크는 건너뛴다. */
  isInitializeSupported?: () => boolean;
  /** `isMinVersionSupported` - 미주입 시 버전 게이트는 건너뛴다. */
  isMinVersionSupported?: (minVersions: {
    android: `${number}.${number}.${number}` | 'always' | 'never';
    ios: `${number}.${number}.${number}` | 'always' | 'never';
  }) => boolean;
  /** `TossAds.attachBanner` */
  attachBanner: (
    adGroupId: string,
    target: string | HTMLElement,
    options?: TossAdsAttachBannerOptions,
  ) => TossAdsAttachBannerResult;
  /** `loadFullScreenAd` - 호출 즉시 구독 해제 함수(`() => void`)를 동기 반환한다. */
  loadFullScreenAd: (params: {
    options?: LoadFullScreenAdOptions;
    onEvent: (event: LoadFullScreenAdEvent) => void;
    onError: (error: Error) => void;
  }) => () => void;
  /** `showFullScreenAd` - 호출 즉시 구독 해제 함수(`() => void`)를 동기 반환한다. */
  showFullScreenAd: (params: {
    options?: ShowFullScreenAdOptions;
    onEvent: (event: ShowFullScreenAdEvent) => void;
    onError: (error: Error) => void;
  }) => () => void;
}

/** 리워드 광고의 `userEarnedReward` 이벤트 payload 형태(SDK d.ts와 동일 필드명). */
export interface AdRewardEarned {
  unitType: string;
  unitAmount: number;
}

/**
 * SDK를 초기화한다. `isInitializeSupported`/`isMinVersionSupported`가 주입돼
 * 있으면 먼저 확인하고, 미지원이면 SDK를 아예 호출하지 않는다. 어떤 경로로든
 * 실패해도(동기 throw, isSupported/버전 체크 실패, onInitializationFailed,
 * 콜백 무응답 타임아웃) 절대 throw/reject하지 않고 `{ok:false}`로 귀결된다.
 */
export async function initializeAds(sdk: AdSdk): Promise<{ ok: boolean }> {
  try {
    if (typeof sdk.isInitializeSupported === 'function') {
      let supported: boolean;
      try {
        supported = sdk.isInitializeSupported();
      } catch {
        return { ok: false };
      }
      if (!supported) {
        return { ok: false };
      }
    }

    if (typeof sdk.isMinVersionSupported === 'function') {
      let versionOk: boolean;
      try {
        versionOk = sdk.isMinVersionSupported(MIN_TOSS_APP_VERSION);
      } catch {
        return { ok: false };
      }
      if (!versionOk) {
        return { ok: false };
      }
    }

    return await new Promise<{ ok: boolean }>((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        settled = true;
        resolve({ ok: false });
      }, INITIALIZE_TIMEOUT_MS);

      const finish = (ok: boolean) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve({ ok });
      };

      try {
        sdk.initialize({
          callbacks: {
            onInitialized: () => finish(true),
            onInitializationFailed: () => finish(false),
          },
        });
      } catch {
        finish(false);
      }
    });
  } catch {
    // 위 블록이 이미 모든 실패 경로를 감싸지만, 예상 못 한 예외까지 마지막
    // 안전망으로 한 번 더 막는다 - 이 함수는 절대 reject하지 않는다.
    return { ok: false };
  }
}

/**
 * 컨테이너에 배너를 붙인다. `adGroupId===null`이면(P2의 fail-closed 계약대로
 * production 광고 id가 아직 콘솔에서 발급되지 않은 상태) SDK를 아예 호출하지
 * 않고 즉시 `null`을 반환한다 - 빈 배너 박스를 그리며 "광고가 있는 척"하지
 * 않기 위함이다. SDK 호출이 던지거나 유효한 결과를 못 주면 `null`을 반환한다.
 * 반환된 `destroy()`도 내부에서 예외를 삼켜 절대 위로 던지지 않는다.
 */
export function attachBannerToContainer(
  sdk: AdSdk,
  adGroupId: string | null,
  container: HTMLElement,
): { destroy: () => void } | null {
  if (adGroupId === null) {
    return null;
  }

  try {
    const result = sdk.attachBanner(adGroupId, container);
    if (result == null || typeof result.destroy !== 'function') {
      return null;
    }
    return {
      destroy: () => {
        try {
          result.destroy();
        } catch {
          // destroy()는 정리(cleanup) 호출이다 - 실패해도 호출부를 절대 깨뜨리지 않는다.
        }
      },
    };
  } catch {
    return null;
  }
}

/**
 * 전면 광고를 미리 불러온다. `adGroupId===null`이면 SDK를 호출하지 않고
 * 즉시 `{loaded:false}`로 귀결된다. `loaded` 이벤트가 오면 `{loaded:true}`,
 * `onError`가 오거나 콜백이 끝내 안 오면(타임아웃) `{loaded:false}`다.
 * 어떤 경로로도 reject하지 않는다.
 */
export function loadInterstitial(
  sdk: AdSdk,
  adGroupId: string | null,
): Promise<{ loaded: boolean }> {
  if (adGroupId === null) {
    return Promise.resolve({ loaded: false });
  }

  return new Promise<{ loaded: boolean }>((resolve) => {
    let settled = false;
    let unsubscribe: (() => void) | undefined;

    const timer = setTimeout(() => finish(false), LOAD_TIMEOUT_MS);

    function finish(loaded: boolean): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (unsubscribe) {
        try {
          unsubscribe();
        } catch {
          // 구독 해제 실패도 결과 통지를 막으면 안 된다.
        }
      }
      resolve({ loaded });
    }

    try {
      unsubscribe = sdk.loadFullScreenAd({
        options: { adGroupId },
        onEvent: (event) => {
          if (event.type === 'loaded') {
            finish(true);
          }
        },
        onError: () => finish(false),
      });
    } catch {
      finish(false);
    }
  });
}

/**
 * 미리 불러온 전면 광고를 노출한다. `adGroupId===null`이면 SDK를 호출하지
 * 않고 즉시 `{shown:false, dismissed:false}`로 귀결된다. `failedToShow`나
 * 예외/타임아웃이면 `{shown:false, dismissed:false}` - 호출부는 이 결과를
 * 그냥 무시하고 계속 진행할 수 있어야 한다(광고 실패가 앱을 막으면 안 된다는
 * 이 파일의 핵심 안전 속성). `dismissed`가 오면 그 시점까지 관측한 `shown`
 * 값과 함께 `dismissed:true`로 귀결된다.
 */
export function showInterstitial(
  sdk: AdSdk,
  adGroupId: string | null,
): Promise<{ shown: boolean; dismissed: boolean }> {
  if (adGroupId === null) {
    return Promise.resolve({ shown: false, dismissed: false });
  }

  return new Promise<{ shown: boolean; dismissed: boolean }>((resolve) => {
    let settled = false;
    let unsubscribe: (() => void) | undefined;
    let shown = false;

    const timer = setTimeout(() => finish({ shown, dismissed: false }), SHOW_TIMEOUT_MS);

    function finish(result: { shown: boolean; dismissed: boolean }): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (unsubscribe) {
        try {
          unsubscribe();
        } catch {
          // 구독 해제 실패도 결과 통지를 막으면 안 된다.
        }
      }
      resolve(result);
    }

    try {
      unsubscribe = sdk.showFullScreenAd({
        options: { adGroupId },
        onEvent: (event) => {
          switch (event.type) {
            case 'show':
              shown = true;
              break;
            case 'dismissed':
              finish({ shown, dismissed: true });
              break;
            case 'failedToShow':
              finish({ shown: false, dismissed: false });
              break;
            default:
              break;
          }
        },
        onError: () => finish({ shown: false, dismissed: false }),
      });
    } catch {
      finish({ shown: false, dismissed: false });
    }
  });
}

/**
 * 리워드 광고 시그니처/타입 뼈대만 갖춘 함수다(계획서 P6: "아키텍처만, UI/호출부는
 * 이번 버전에 없음"). `showInterstitial`과 동일한 show-flow 패턴을 재사용하되,
 * `userEarnedReward` 이벤트가 실제로 온 경우에만 `rewardEarned`가 채워진다 -
 * 단순 `dismissed`(사용자가 광고를 끝까지 안 보고 닫음)만으로는 리워드를 절대
 * 지급하지 않는다. 이번 버전에서 이 함수를 호출하는 UI/라우트는 없다.
 */
export function showRewardedAd(
  sdk: AdSdk,
  adGroupId: string | null,
): Promise<{ shown: boolean; rewardEarned: AdRewardEarned | null }> {
  if (adGroupId === null) {
    return Promise.resolve({ shown: false, rewardEarned: null });
  }

  return new Promise<{ shown: boolean; rewardEarned: AdRewardEarned | null }>((resolve) => {
    let settled = false;
    let unsubscribe: (() => void) | undefined;
    let shown = false;
    let rewardEarned: AdRewardEarned | null = null;

    const timer = setTimeout(() => finish({ shown, rewardEarned }), SHOW_TIMEOUT_MS);

    function finish(result: { shown: boolean; rewardEarned: AdRewardEarned | null }): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (unsubscribe) {
        try {
          unsubscribe();
        } catch {
          // 구독 해제 실패도 결과 통지를 막으면 안 된다.
        }
      }
      resolve(result);
    }

    try {
      unsubscribe = sdk.showFullScreenAd({
        options: { adGroupId },
        onEvent: (event) => {
          switch (event.type) {
            case 'show':
              shown = true;
              break;
            case 'userEarnedReward':
              rewardEarned = {
                unitType: event.data.unitType,
                unitAmount: event.data.unitAmount,
              };
              break;
            case 'dismissed':
              // userEarnedReward가 먼저 오지 않았다면 rewardEarned는 null로 남는다 -
              // 단순 닫기(dismiss)만으로 보상을 지급하지 않는다는 것이 이 분기의 핵심.
              finish({ shown, rewardEarned });
              break;
            case 'failedToShow':
              finish({ shown: false, rewardEarned: null });
              break;
            default:
              break;
          }
        },
        onError: () => finish({ shown: false, rewardEarned: null }),
      });
    } catch {
      finish({ shown: false, rewardEarned: null });
    }
  });
}
