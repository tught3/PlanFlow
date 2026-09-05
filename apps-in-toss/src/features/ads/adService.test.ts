import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

import {
  attachBannerToContainer,
  initializeAds,
  loadInterstitial,
  showInterstitial,
  showRewardedAd,
  type AdSdk,
} from './adService';

/**
 * 이 프로젝트에는 jsdom이 설치되어 있지 않아(adBannerStyles.test.ts 상단 주석 참고)
 * 실제 `document.createElement`를 쓸 수 없다. `attachBannerToContainer`는 container를
 * 그대로 sdk.attachBanner에 전달만 할 뿐 DOM API를 직접 호출하지 않으므로, 자리표시용
 * plain object를 HTMLElement로 캐스팅해 쓴다.
 */
function fakeContainer(): HTMLElement {
  return {} as HTMLElement;
}

/** 최소한의 유효한 AdSdk 기본값을 만든다. 개별 테스트는 필요한 필드만 override한다. */
function makeSdk(overrides: Partial<AdSdk>): AdSdk {
  return {
    initialize: vi.fn(),
    attachBanner: vi.fn(),
    loadFullScreenAd: vi.fn(() => () => {}),
    showFullScreenAd: vi.fn(() => () => {}),
    ...overrides,
  };
}

describe('initializeAds', () => {
  it('init callbacks의 onInitialized가 오면 {ok:true}', async () => {
    const sdk = makeSdk({
      initialize: vi.fn((options) => {
        options.callbacks?.onInitialized?.();
      }),
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: true });
  });

  it('SDK init이 동기적으로 throw해도 {ok:false}이고 예외가 위로 전파되지 않는다', async () => {
    const sdk = makeSdk({
      initialize: vi.fn(() => {
        throw new Error('boom');
      }),
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: false });
  });

  it('onInitializationFailed가 오면 {ok:false}', async () => {
    const sdk = makeSdk({
      initialize: vi.fn((options) => {
        options.callbacks?.onInitializationFailed?.(new Error('nope'));
      }),
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: false });
  });

  it('isInitializeSupported()가 false면 {ok:false}이고 initialize는 호출되지 않는다', async () => {
    const initialize = vi.fn();
    const sdk = makeSdk({
      initialize,
      isInitializeSupported: () => false,
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: false });
    expect(initialize).not.toHaveBeenCalled();
  });

  it('isMinVersionSupported()가 false면 {ok:false}이고 initialize는 호출되지 않는다', async () => {
    const initialize = vi.fn();
    const sdk = makeSdk({
      initialize,
      isMinVersionSupported: () => false,
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: false });
    expect(initialize).not.toHaveBeenCalled();
  });

  it('isInitializeSupported()가 throw해도 {ok:false}로 안전하게 귀결된다', async () => {
    const initialize = vi.fn();
    const sdk = makeSdk({
      initialize,
      isInitializeSupported: () => {
        throw new Error('boom');
      },
    });

    await expect(initializeAds(sdk)).resolves.toEqual({ ok: false });
    expect(initialize).not.toHaveBeenCalled();
  });
});

describe('initializeAds - 타임아웃', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('콜백이 끝내 안 오면 결국 {ok:false}로 귀결되고 테스트를 영원히 붙잡지 않는다', async () => {
    const sdk = makeSdk({
      // 아무 콜백도 호출하지 않는 init(무응답 시뮬레이션)
      initialize: vi.fn(),
    });

    const resultPromise = initializeAds(sdk);
    await vi.runAllTimersAsync();
    await expect(resultPromise).resolves.toEqual({ ok: false });
  });
});

describe('attachBannerToContainer', () => {
  it('adGroupId가 null이면 null을 반환하고 SDK를 호출하지 않는다', () => {
    const attachBanner = vi.fn();
    const sdk = makeSdk({ attachBanner });
    const container = fakeContainer();

    const result = attachBannerToContainer(sdk, null, container);

    expect(result).toBeNull();
    expect(attachBanner).toHaveBeenCalledTimes(0);
  });

  it('SDK attach가 throw하면 null을 반환하고 예외가 위로 전파되지 않는다', () => {
    const sdk = makeSdk({
      attachBanner: vi.fn(() => {
        throw new Error('boom');
      }),
    });
    const container = fakeContainer();

    expect(() => attachBannerToContainer(sdk, 'group-1', container)).not.toThrow();
    expect(attachBannerToContainer(sdk, 'group-1', container)).toBeNull();
  });

  it('SDK attach가 성공하면 동작하는 destroy()를 가진 객체를 반환한다', () => {
    const destroy = vi.fn();
    const sdk = makeSdk({
      attachBanner: vi.fn(() => ({ destroy })),
    });
    const container = fakeContainer();

    const result = attachBannerToContainer(sdk, 'group-1', container);

    expect(result).not.toBeNull();
    result?.destroy();
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  it('destroy()가 내부적으로 throw해도 호출부로 전파되지 않는다', () => {
    const destroy = vi.fn(() => {
      throw new Error('destroy boom');
    });
    const sdk = makeSdk({
      attachBanner: vi.fn(() => ({ destroy })),
    });
    const container = fakeContainer();

    const result = attachBannerToContainer(sdk, 'group-1', container);

    expect(result).not.toBeNull();
    expect(() => result?.destroy()).not.toThrow();
  });
});

describe('loadInterstitial', () => {
  it('adGroupId가 null이면 SDK 호출 없이 즉시 {loaded:false}', async () => {
    const loadFullScreenAd = vi.fn(() => () => {});
    const sdk = makeSdk({ loadFullScreenAd });

    await expect(loadInterstitial(sdk, null)).resolves.toEqual({ loaded: false });
    expect(loadFullScreenAd).not.toHaveBeenCalled();
  });

  it('loaded 이벤트가 오면 {loaded:true}', async () => {
    const sdk = makeSdk({
      loadFullScreenAd: vi.fn((params) => {
        params.onEvent({ type: 'loaded' });
        return () => {};
      }),
    });

    await expect(loadInterstitial(sdk, 'group-1')).resolves.toEqual({ loaded: true });
  });

  it('onError가 오면 {loaded:false}', async () => {
    const sdk = makeSdk({
      loadFullScreenAd: vi.fn((params) => {
        params.onError(new Error('no fill'));
        return () => {};
      }),
    });

    await expect(loadInterstitial(sdk, 'group-1')).resolves.toEqual({ loaded: false });
  });

  it('SDK가 동기적으로 throw해도 {loaded:false}이고 예외가 위로 전파되지 않는다', async () => {
    const sdk = makeSdk({
      loadFullScreenAd: vi.fn(() => {
        throw new Error('boom');
      }),
    });

    await expect(loadInterstitial(sdk, 'group-1')).resolves.toEqual({ loaded: false });
  });

  describe('타임아웃', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });
    afterEach(() => {
      vi.useRealTimers();
    });

    it('이벤트가 끝내 안 오면 결국 {loaded:false}로 귀결되고 테스트를 영원히 붙잡지 않는다', async () => {
      const sdk = makeSdk({
        loadFullScreenAd: vi.fn(() => () => {}), // onEvent/onError 둘 다 절대 호출 안 함
      });

      const resultPromise = loadInterstitial(sdk, 'group-1');
      await vi.runAllTimersAsync();
      await expect(resultPromise).resolves.toEqual({ loaded: false });
    });
  });
});

describe('showInterstitial', () => {
  it('adGroupId가 null이면 SDK 호출 없이 즉시 {shown:false, dismissed:false}', async () => {
    const showFullScreenAd = vi.fn(() => () => {});
    const sdk = makeSdk({ showFullScreenAd });

    await expect(showInterstitial(sdk, null)).resolves.toEqual({
      shown: false,
      dismissed: false,
    });
    expect(showFullScreenAd).not.toHaveBeenCalled();
  });

  it('failedToShow 이벤트는 {shown:false, dismissed:false}로 귀결되고, 호출부는 이 결과를 그냥 무시하고 계속 진행할 수 있다(핵심 안전 속성)', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn((params) => {
        params.onEvent({ type: 'failedToShow' });
        return () => {};
      }),
    });

    const result = await showInterstitial(sdk, 'group-1');
    expect(result).toEqual({ shown: false, dismissed: false });

    // 호출부 관점: 이 결과를 받고도 try/catch나 특별 처리 없이 다음 로직으로
    // 그냥 넘어갈 수 있어야 한다 - 여기서는 그저 결과가 정상적인 plain object임을
    // 다시 한번 확인해 "이걸 그냥 무시해도 안전하다"는 계약을 실증한다.
    expect(() => {
      const next = result.shown ? 'do-something' : 'continue-app-flow';
      expect(next).toBe('continue-app-flow');
    }).not.toThrow();
  });

  it('dismissed 이벤트는 깔끔하게 resolve된다(그 자체로 보상을 주지 않는다)', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn((params) => {
        params.onEvent({ type: 'show' });
        params.onEvent({ type: 'dismissed' });
        return () => {};
      }),
    });

    await expect(showInterstitial(sdk, 'group-1')).resolves.toEqual({
      shown: true,
      dismissed: true,
    });
  });

  it('SDK가 동기적으로 throw해도 {shown:false, dismissed:false}이고 예외가 위로 전파되지 않는다', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn(() => {
        throw new Error('boom');
      }),
    });

    await expect(showInterstitial(sdk, 'group-1')).resolves.toEqual({
      shown: false,
      dismissed: false,
    });
  });
});

describe('showRewardedAd', () => {
  it('adGroupId가 null이면 SDK 호출 없이 즉시 {shown:false, rewardEarned:null}', async () => {
    const showFullScreenAd = vi.fn(() => () => {});
    const sdk = makeSdk({ showFullScreenAd });

    await expect(showRewardedAd(sdk, null)).resolves.toEqual({
      shown: false,
      rewardEarned: null,
    });
    expect(showFullScreenAd).not.toHaveBeenCalled();
  });

  it('userEarnedReward 이벤트가 오면 rewardEarned가 그 payload와 일치한다', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn((params) => {
        params.onEvent({ type: 'show' });
        params.onEvent({
          type: 'userEarnedReward',
          data: { unitType: 'coin', unitAmount: 10 },
        });
        params.onEvent({ type: 'dismissed' });
        return () => {};
      }),
    });

    await expect(showRewardedAd(sdk, 'group-1')).resolves.toEqual({
      shown: true,
      rewardEarned: { unitType: 'coin', unitAmount: 10 },
    });
  });

  it('userEarnedReward 없이 dismissed만 오면 rewardEarned는 반드시 null이다(단순 닫기로 보상 지급 금지)', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn((params) => {
        params.onEvent({ type: 'show' });
        params.onEvent({ type: 'dismissed' });
        return () => {};
      }),
    });

    await expect(showRewardedAd(sdk, 'group-1')).resolves.toEqual({
      shown: true,
      rewardEarned: null,
    });
  });

  it('SDK가 동기적으로 throw해도 {shown:false, rewardEarned:null}이고 예외가 위로 전파되지 않는다', async () => {
    const sdk = makeSdk({
      showFullScreenAd: vi.fn(() => {
        throw new Error('boom');
      }),
    });

    await expect(showRewardedAd(sdk, 'group-1')).resolves.toEqual({
      shown: false,
      rewardEarned: null,
    });
  });
});
