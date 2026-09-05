/**
 * adConfig.ts 테스트.
 *
 * resolveAdGroupIds는 import.meta.env를 직접 읽지 않는 순수 함수라 env
 * 스터빙 없이 결정적으로 테스트한다(devPreview.ts의
 * resolveDevPreviewEnabled와 동일한 패턴). getAdGroupIds는 실제
 * import.meta.env를 경유하는 얇은 래퍼이므로 "값이 있든 없든 boolean/타입
 * 계약을 지킨다"만 검증한다.
 */
import { describe, expect, it } from 'vitest';

import { TEST_AD_GROUP_IDS, getAdGroupIds, resolveAdGroupIds, type ProductionAdGroupIds } from './adConfig.ts';

describe('resolveAdGroupIds', () => {
  it('isDev=true면 productionIds와 무관하게 항상 TEST_AD_GROUP_IDS 값을 반환한다', () => {
    const productionIds: ProductionAdGroupIds = {
      interstitial: 'prod-interstitial',
      rewarded: 'prod-rewarded',
      banner: 'prod-banner',
      bannerNative: 'prod-banner-native',
    };

    const result = resolveAdGroupIds({ isDev: true, productionIds });

    expect(result).toEqual(TEST_AD_GROUP_IDS);
  });

  it('isDev=false + productionIds가 전부 설정되어 있으면 그 값을 그대로 반환한다', () => {
    const productionIds: ProductionAdGroupIds = {
      interstitial: 'prod-interstitial',
      rewarded: 'prod-rewarded',
      banner: 'prod-banner',
      bannerNative: 'prod-banner-native',
    };

    const result = resolveAdGroupIds({ isDev: false, productionIds });

    expect(result).toEqual(productionIds);
  });

  it('isDev=false + productionIds가 전부 null이면(콘솔 미발급 상태, 현재 실제 상태) 전부 null을 반환한다 - throw하지 않고 fail-closed로 귀결된다', () => {
    const productionIds: ProductionAdGroupIds = {
      interstitial: null,
      rewarded: null,
      banner: null,
      bannerNative: null,
    };

    const result = resolveAdGroupIds({ isDev: false, productionIds });

    expect(result).toEqual({
      interstitial: null,
      rewarded: null,
      banner: null,
      bannerNative: null,
    });
  });

  it('isDev=false + productionIds가 일부만 설정되어 있으면 설정된 필드는 값을, 미설정 필드는 null을 그대로 유지한다', () => {
    const productionIds: ProductionAdGroupIds = {
      interstitial: 'prod-interstitial',
      rewarded: null,
      banner: 'prod-banner',
      bannerNative: null,
    };

    const result = resolveAdGroupIds({ isDev: false, productionIds });

    expect(result).toEqual(productionIds);
  });
});

describe('getAdGroupIds (실제 import.meta.env 경유)', () => {
  it('resolveAdGroupIds에 실제 import.meta.env 값을 넣은 것과 항상 동일한 결과를 낸다(배선 계약)', () => {
    const expected = resolveAdGroupIds({
      isDev: import.meta.env.DEV,
      productionIds: {
        interstitial: import.meta.env.VITE_AD_GROUP_ID_INTERSTITIAL ?? null,
        rewarded: import.meta.env.VITE_AD_GROUP_ID_REWARDED ?? null,
        banner: import.meta.env.VITE_AD_GROUP_ID_BANNER ?? null,
        bannerNative: import.meta.env.VITE_AD_GROUP_ID_BANNER_NATIVE ?? null,
      },
    });

    expect(getAdGroupIds()).toEqual(expected);
  });

  it('vitest 환경(import.meta.env.DEV===true)에서는 항상 TEST_AD_GROUP_IDS를 반환한다', () => {
    expect(getAdGroupIds()).toEqual(TEST_AD_GROUP_IDS);
  });
});
