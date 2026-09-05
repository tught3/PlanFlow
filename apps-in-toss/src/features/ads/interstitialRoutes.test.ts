import { describe, expect, it } from 'vitest';

import { isSettledRouteForInterstitial } from './interstitialRoutes.ts';

describe('isSettledRouteForInterstitial', () => {
  it('목록/브리핑 3개 경로에서는 true를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/today')).toBe(true);
    expect(isSettledRouteForInterstitial('/calendar/month')).toBe(true);
    expect(isSettledRouteForInterstitial('/calendar/week')).toBe(true);
  });

  it('일정 상세 경로(/event/:id)는 true를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/event/abc123')).toBe(true);
  });

  it('일정 생성 경로(/event/new)는 false를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/event/new')).toBe(false);
  });

  it('일정 수정 경로(/event/:id/edit)는 false를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/event/abc123/edit')).toBe(false);
  });

  it('로그인 경로는 false를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/login')).toBe(false);
  });

  it('루트 경로는 false를 반환한다', () => {
    expect(isSettledRouteForInterstitial('/')).toBe(false);
  });

  it('미지의(향후 추가될) 경로는 false를 반환한다 — default-deny 증명', () => {
    expect(isSettledRouteForInterstitial('/settings')).toBe(false);
  });

  it('쿼리스트링/해시/trailing slash가 붙어도 정규화 후 판단한다', () => {
    expect(isSettledRouteForInterstitial('/today?x=1')).toBe(true);
    expect(isSettledRouteForInterstitial('/today/')).toBe(true);
    expect(isSettledRouteForInterstitial('/today#section')).toBe(true);
    expect(isSettledRouteForInterstitial('/event/abc123?ref=push')).toBe(true);
    expect(isSettledRouteForInterstitial('/event/new?x=1')).toBe(false);
  });
});
