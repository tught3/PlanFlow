/**
 * 광고 수익화 정책 상수 + production 광고 ID 해석 게이트.
 *
 * P1: 정책 매직넘버(간격/쿨다운/최소버전)와 테스트 광고 ID를 이 파일 하나에
 * 모은다 - 다른 곳에 흩어놓지 않는다(계획서 명시).
 *
 * P2: production 광고 ID 해석은 devPreview.ts의 검증된 패턴을 그대로 따른다 -
 * 순수 함수(resolveAdGroupIds) + 얇은 env 읽기 래퍼(getAdGroupIds)로 분리하고,
 * 안전성은 post-build 마커 스캔이 아니라 Vite가 `import.meta.env.DEV`를
 * production 빌드에서 리터럴 `false`로 접어주는 빌드타임 상수 폴딩에서 나온다
 * (devPreview.ts 상단 주석 참고 - 동일 근거이므로 여기서 반복하지 않는다).
 */

/** 전면 광고를 노출하기 전 최소 세션 지속 시간(초). */
export const INTERSTITIAL_MIN_SESSION_SECONDS = 60;

/** 동일 사용자에게 전면 광고를 다시 노출하기까지의 최소 간격(시간). */
export const INTERSTITIAL_COOLDOWN_HOURS = 24;

/** 하루 최대 전면 광고 노출 횟수. */
export const INTERSTITIAL_MAX_PER_DAY = 1;

/** 설치 첫날은 전면 광고를 노출하지 않는다. */
export const FIRST_DAY_INTERSTITIAL_DISABLED = true;

/**
 * 전면 광고 기능을 지원하는 최소 토스 앱 버전.
 * 형태는 SDK의 isMinVersionSupported(minVersions) 시그니처와 동일하게 맞춘다
 * (node_modules/@apps-in-toss/web-framework/dist/index.d.ts 확인:
 * `{ android: `${number}.${number}.${number}` | 'always' | 'never';
 *    ios: `${number}.${number}.${number}` | 'always' | 'never' }`).
 */
export const MIN_TOSS_APP_VERSION: {
  android: `${number}.${number}.${number}` | 'always' | 'never';
  ios: `${number}.${number}.${number}` | 'always' | 'never';
} = { android: '5.241.0', ios: '5.241.0' };

/** 개발/미검증 환경에서 사용하는 토스 공식 테스트 광고 그룹 id. */
export const TEST_AD_GROUP_IDS = {
  interstitial: 'ait-ad-test-interstitial-id',
  rewarded: 'ait-ad-test-rewarded-id',
  banner: 'ait-ad-test-banner-id',
  bannerNative: 'ait-ad-test-native-image-id',
} as const;

/** production 광고 그룹 id 묶음. 콘솔에서 발급되기 전에는 null일 수 있다(fail-closed). */
export interface ProductionAdGroupIds {
  interstitial: string | null;
  rewarded: string | null;
  banner: string | null;
  bannerNative: string | null;
}

/**
 * (isDev, productionIds) -> 실제로 사용할 광고 그룹 id 묶음으로 변환하는 순수 함수.
 *
 * isDev===true면 테스트 광고 id로 대체한다(dev 서버/vitest에서 production
 * 광고 id를 실수로 요청하지 않도록). isDev===false면 productionIds를 그대로
 * 반환한다 - 이 시점에 값이 null이어도(콘솔 미발급) 예외를 던지지 않는다.
 * null 처리는 이 함수의 책임이 아니라 호출부(AdService 등)의 책임이다 -
 * null이면 "그 광고 종류는 요청하지 않는다"로 해석해야 한다(fail-closed).
 */
export function resolveAdGroupIds(input: {
  isDev: boolean;
  productionIds: ProductionAdGroupIds;
}): ProductionAdGroupIds {
  if (input.isDev) {
    return { ...TEST_AD_GROUP_IDS };
  }
  return { ...input.productionIds };
}

/**
 * 실제 import.meta.env를 읽어 resolveAdGroupIds에 위임하는 얇은 래퍼.
 * production 광고 id는 이번 세션 기준 콘솔 미발급 상태라 아래 4개 env var는
 * .env(.local/.example) 어디에도 값이 없다 - 이는 예상된 상태이며, 이 경우
 * ?? null로 정상적으로 null로 귀결되어야 하고 throw/crash하면 안 된다.
 */
export function getAdGroupIds(): ProductionAdGroupIds {
  return resolveAdGroupIds({
    isDev: import.meta.env.DEV,
    productionIds: {
      interstitial: import.meta.env.VITE_AD_GROUP_ID_INTERSTITIAL ?? null,
      rewarded: import.meta.env.VITE_AD_GROUP_ID_REWARDED ?? null,
      banner: import.meta.env.VITE_AD_GROUP_ID_BANNER ?? null,
      bannerNative: import.meta.env.VITE_AD_GROUP_ID_BANNER_NATIVE ?? null,
    },
  });
}
