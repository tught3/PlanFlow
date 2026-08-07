/**
 * 광고 수익화 정책 상수 + production 광고 ID 해석 게이트.
 *
 * P1: 정책 매직넘버(간격/쿨다운/최소버전)와 테스트 광고 ID를 이 파일 하나에
 * 모은다 - 다른 곳에 흩어놓지 않는다(계획서 명시).
 *
 * P2 (2026-08 재정정, ground-truth 빌드+grep으로 발견된 실제 leak 수정):
 * production 광고 ID 해석은 devPreview.ts의 패턴을 따르되, 처음 버전은
 * `import.meta.env.DEV`를 boolean 파라미터로 감싸(resolveAdGroupIds의
 * `isDev` 인자) 함수 호출 경계 너머로 넘기고 있었다. Vite/esbuild의
 * 상수 폴딩+dead-code-elimination은 `import.meta.env.DEV` 참조 **그 자리**
 * (동일 함수 스코프 안)에서만 `false` 리터럴로 접힌 뒤 그 자리의 도달불가
 * 분기를 제거한다 - 함수 호출 경계 너머로 값이 전파돼(다른 함수의 파라미터로)
 * 그 함수 내부에서 조건 분기를 타는 경우까지 interprocedural하게 접어주지
 * 않는다. 그 결과 `resolveAdGroupIds`의 `if (input.isDev) return
 * {...TEST_AD_GROUP_IDS}` 분기는 production 빌드에서도 도달 가능한 코드로
 * 남았고, TEST_AD_GROUP_IDS의 문자열 리터럴 4개가 실제 `dist/` 번들에
 * 그대로 살아남았다(`vite build` 후 `grep`으로 직접 확인됨).
 *
 * 수정: `getAdGroupIds()`가 `import.meta.env.DEV`를 함수 파라미터로 넘기지
 * 않고 **자기 자신의 스코프 안에서 직접** 분기한다(devPreview.ts의
 * `isDevPreviewEnabled()`가 `import.meta.env.DEV && ...`를 자기 스코프
 * 안에서 직접 평가하는 것과 동일한 자리 - 함수 경계를 넘기지 않는다). 이
 * 자리는 production 빌드에서 `if (false) { return {...TEST_AD_GROUP_IDS} }`로
 * 완전히 리터럴 폴딩되고, esbuild 미니파이어가 그 도달불가 분기를 제거해
 * TEST_AD_GROUP_IDS 참조 자체가 getAdGroupIds()의 컴파일 결과에서 사라진다.
 * production 코드 경로(router.tsx, BannerSlot.tsx) 어디도 `TEST_AD_GROUP_IDS`나
 * `resolveAdGroupIds`를 직접 import하지 않으므로(둘 다 `getAdGroupIds()`만
 * 호출), Rollup의 export 단위 tree-shaking이 이 둘을 production 번들에서
 * 완전히 제거한다 - grep으로 재확인됨(아래 scripts/scan-bundle.mjs 실행
 * 결과 참고).
 *
 * `resolveAdGroupIds`(순수 함수, isDev를 boolean 파라미터로 받음)는 여전히
 * export되어 있다 - production 코드 경로가 더 이상 호출하지 않을 뿐,
 * adConfig.test.ts가 env 스터빙 없이 결정적으로 분기 로직을 단위 테스트하기
 * 위해 그대로 남겨둔다(devPreview.ts의 resolveDevPreviewEnabled와 동일한
 * "테스트 전용으로 남기는 순수 함수" 역할).
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
 *
 * **production 코드 경로는 더 이상 이 함수를 호출하지 않는다** - `isDev`가
 * 함수 파라미터로 넘어오면 그 값이 실제로는 빌드타임에 `import.meta.env.DEV`가
 * 접힌 리터럴 `false`라 해도, Vite/esbuild는 그 리터럴을 이 함수 호출 경계
 * 너머(파라미터로) interprocedural하게 전파해 `if (input.isDev)` 분기를
 * 접어주지 않는다 - 그 결과 이 함수가 production 코드에서 호출되면
 * TEST_AD_GROUP_IDS가 항상 도달 가능한 코드로 남아 실제 번들에 유출된다
 * (이 파일 상단 P2 주석에 실측 근거 기록). `getAdGroupIds()`가 이 로직을
 * 자기 스코프 안에서 직접 재구현해 그 문제를 피한다.
 *
 * 이 함수는 adConfig.test.ts가 env 스터빙 없이 분기 로직을 결정적으로 단위
 * 테스트하기 위한 용도로만 export되어 남아 있다(devPreview.ts의
 * resolveDevPreviewEnabled와 동일한 "테스트 전용 순수 함수" 역할) - 새 코드는
 * 이 함수를 호출하지 말고 `getAdGroupIds()`를 사용한다.
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
 * 실제 import.meta.env를 읽어 사용할 광고 그룹 id 묶음을 반환한다.
 *
 * `import.meta.env.DEV` 분기를 이 함수 자기 스코프 안에서 **직접** 평가한다
 * (devPreview.ts의 `isDevPreviewEnabled()`가 `import.meta.env.DEV && ...`를
 * 자기 스코프 안에서 직접 평가하는 것과 동일한 자리 - resolveAdGroupIds처럼
 * 파라미터로 넘기지 않는다). Vite는 이 참조를 production 빌드에서 리터럴
 * `false`로 정적 치환하고, esbuild 미니파이어가 그 결과 `if (false) {...}`가
 * 된 TEST_AD_GROUP_IDS 반환 분기를 도달불가 코드로 판단해 제거한다 - 그래서
 * TEST_AD_GROUP_IDS의 문자열 리터럴은 production 번들에 남지 않는다(이 파일
 * 상단 P2 주석과 scripts/scan-bundle.mjs 참고).
 *
 * production 광고 id는 이번 세션 기준 콘솔 미발급 상태라 아래 4개 env var는
 * .env(.local/.example) 어디에도 값이 없다 - 이는 예상된 상태이며, 이 경우
 * ?? null로 정상적으로 null로 귀결되어야 하고 throw/crash하면 안 된다.
 */
export function getAdGroupIds(): ProductionAdGroupIds {
  if (import.meta.env.DEV) {
    return { ...TEST_AD_GROUP_IDS };
  }
  return {
    interstitial: import.meta.env.VITE_AD_GROUP_ID_INTERSTITIAL ?? null,
    rewarded: import.meta.env.VITE_AD_GROUP_ID_REWARDED ?? null,
    banner: import.meta.env.VITE_AD_GROUP_ID_BANNER ?? null,
    bannerNative: import.meta.env.VITE_AD_GROUP_ID_BANNER_NATIVE ?? null,
  };
}
