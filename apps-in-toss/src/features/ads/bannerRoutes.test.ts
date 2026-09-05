import { describe, expect, it } from 'vitest';

import { shouldShowBannerForPath } from './bannerRoutes.ts';

describe('shouldShowBannerForPath', () => {
  it('허용된 3개 경로에서는 true를 반환한다', () => {
    expect(shouldShowBannerForPath('/today')).toBe(true);
    expect(shouldShowBannerForPath('/calendar/month')).toBe(true);
    expect(shouldShowBannerForPath('/calendar/week')).toBe(true);
  });

  it('일정 상세/작성/수정 경로는 false를 반환한다', () => {
    expect(shouldShowBannerForPath('/event/new')).toBe(false);
    expect(shouldShowBannerForPath('/event/abc123')).toBe(false);
    expect(shouldShowBannerForPath('/event/abc123/edit')).toBe(false);
  });

  it('로그인 경로는 false를 반환한다', () => {
    expect(shouldShowBannerForPath('/login')).toBe(false);
  });

  it('루트 경로는 false를 반환한다', () => {
    expect(shouldShowBannerForPath('/')).toBe(false);
  });

  it('미지의(향후 추가될) 경로는 false를 반환한다 — default-deny 증명', () => {
    expect(shouldShowBannerForPath('/settings')).toBe(false);
  });

  it('쿼리스트링이 붙어도 경로만으로 판단한다(정규화 후 비교)', () => {
    // 선택한 동작: 쿼리스트링은 배너 노출 여부에 영향을 주지 않는다.
    expect(shouldShowBannerForPath('/today?x=1')).toBe(true);
    expect(shouldShowBannerForPath('/event/abc123?ref=push')).toBe(false);
  });

  it('trailing slash가 붙어도 같은 경로로 취급한다(정규화 후 비교)', () => {
    // 선택한 동작: 끝 슬래시는 제거 후 비교한다.
    expect(shouldShowBannerForPath('/today/')).toBe(true);
    expect(shouldShowBannerForPath('/calendar/month/')).toBe(true);
  });

  it('해시(fragment)가 붙어도 경로만으로 판단한다', () => {
    expect(shouldShowBannerForPath('/today#section')).toBe(true);
  });
});
