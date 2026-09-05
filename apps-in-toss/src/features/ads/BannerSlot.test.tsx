/**
 * BannerSlot 테스트.
 *
 * 이 프로젝트에는 jsdom이 설치되어 있지 않아(adBannerStyles.test.ts,
 * adService.test.ts 상단 주석 참고) 실제 `ref`/`useEffect`가 DOM에 붙어
 * 실행되는 것을 재현할 수 없다 - `react-dom/server`의 `renderToStaticMarkup`은
 * effect를 아예 실행하지 않으므로(SSR은 원래 effect를 실행하지 않는다),
 * attach/detach가 실제로 호출되는지는 이 파일에서 검증할 수 없다.
 *
 * 그래서 두 갈래로 나눠 검증한다(ConfirmDialog.test.tsx와 동일한 전략):
 * 1) attach/detach의 실제 로직(멱등성, StrictMode 재현 포함)은
 *    bannerAttachment.test.ts가 plain 함수 호출만으로 완전히 검증한다 -
 *    BannerSlot.tsx의 useEffect가 호출하는 함수가 정확히 그 함수들이다.
 * 2) 이 파일은 `renderToStaticMarkup`으로 "렌더 결과 자체의 계약"만
 *    검증한다: 배너를 노출해야 하는 경로에서는 `.ad-banner-slot` 컨테이너가
 *    렌더되고, 노출하면 안 되는 경로에서는 아무것도(빈 문자열) 렌더되지
 *    않는다는 것.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';

import type { ProductionAdGroupIds } from './adConfig';
import type { AdSdk } from './adService';
import { BannerSlot } from './BannerSlot';

/** 최소한의 유효한 AdSdk fake. renderToStaticMarkup은 effect를 실행하지 않으므로 호출되지 않는다. */
function makeSdk(): AdSdk {
  return {
    initialize: vi.fn(),
    attachBanner: vi.fn(),
    loadFullScreenAd: vi.fn(() => () => {}),
    showFullScreenAd: vi.fn(() => () => {}),
  };
}

describe('BannerSlot 렌더링 (정적 마크업 계약)', () => {
  it('배너 허용 경로(/today)에서는 .ad-banner-slot 컨테이너를 렌더링한다', () => {
    const html = renderToStaticMarkup(<BannerSlot pathname="/today" sdk={makeSdk()} />);

    expect(html).toContain('class="ad-banner-slot"');
  });

  it('배너 허용 경로(/calendar/month, /calendar/week)에서도 렌더링한다', () => {
    const monthHtml = renderToStaticMarkup(
      <BannerSlot pathname="/calendar/month" sdk={makeSdk()} />,
    );
    const weekHtml = renderToStaticMarkup(
      <BannerSlot pathname="/calendar/week" sdk={makeSdk()} />,
    );

    expect(monthHtml).toContain('class="ad-banner-slot"');
    expect(weekHtml).toContain('class="ad-banner-slot"');
  });

  it('배너 비허용 경로에서는 완전히 빈 마크업(null)을 렌더링한다 - 빈 배너 박스 없음', () => {
    const html = renderToStaticMarkup(<BannerSlot pathname="/settings" sdk={makeSdk()} />);

    expect(html).toBe('');
    expect(html).not.toContain('ad-banner-slot');
    expect(html).not.toContain('<div');
  });

  it('쿼리스트링/해시가 붙은 배너 허용 경로도 렌더링한다(bannerRoutes.ts 정규화 위임)', () => {
    const html = renderToStaticMarkup(
      <BannerSlot pathname="/today?foo=bar#frag" sdk={makeSdk()} />,
    );

    expect(html).toContain('class="ad-banner-slot"');
  });

  it('알 수 없는 신규 경로는 기본적으로 배너를 렌더링하지 않는다(default-deny)', () => {
    const html = renderToStaticMarkup(<BannerSlot pathname="/some/new/route" sdk={makeSdk()} />);

    expect(html).toBe('');
  });

  it('배너 허용 경로(/today)라도 getAdGroupIds().banner가 null이면 아무것도 렌더링하지 않는다(빈 배너 박스 방지)', async () => {
    // production 배너 광고 id가 콘솔에서 아직 발급되지 않은 현재 상태를
    // 재현한다. vitest는 항상 import.meta.env.DEV===true라 실제
    // getAdGroupIds()는 절대 null을 반환하지 않으므로(adConfig.ts의
    // resolveAdGroupIds가 isDev===true면 TEST_AD_GROUP_IDS로 대체) 이
    // 경로는 모듈을 직접 mock해야만 재현할 수 있다.
    vi.resetModules();
    vi.doMock('./adConfig', async () => {
      const actual = await vi.importActual<typeof import('./adConfig')>('./adConfig');
      return {
        ...actual,
        getAdGroupIds: (): ProductionAdGroupIds => ({
          interstitial: null,
          rewarded: null,
          banner: null,
          bannerNative: null,
        }),
      };
    });

    const { BannerSlot: MockedBannerSlot } = await import('./BannerSlot');
    const html = renderToStaticMarkup(
      <MockedBannerSlot pathname="/today" sdk={makeSdk()} />,
    );

    expect(html).toBe('');
    expect(html).not.toContain('ad-banner-slot');

    vi.doUnmock('./adConfig');
    vi.resetModules();
  });
});
