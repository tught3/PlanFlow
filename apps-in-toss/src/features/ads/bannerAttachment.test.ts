/**
 * bannerAttachment.ts 테스트.
 *
 * 이 프로젝트에는 jsdom이 설치되어 있지 않다(adService.test.ts 상단 주석
 * 참고) - `attachBannerToContainer`는 container를 그대로 sdk.attachBanner에
 * 전달만 할 뿐 DOM API를 직접 호출하지 않으므로, 여기서도 자리표시용 plain
 * object를 HTMLElement로 캐스팅해 쓴다.
 *
 * `BannerSlot.tsx`의 useEffect가 실제로 호출하는 함수는 정확히 이 파일의
 * `attachBanner`/`detachBanner`다. 이 컴포넌트는 jsdom 없이는 실제 DOM
 * ref/effect를 재현할 수 없으므로(BannerSlot.test.tsx 상단 주석 참고),
 * React StrictMode의 "setup -> cleanup -> setup" 재현을 포함한 attach/detach
 * 생명주기의 정확성 검증은 전부 이 파일이 담당한다.
 */
import { describe, expect, it, vi } from 'vitest';

import type { AdSdk } from './adService';
import {
  attachBanner,
  createBannerAttachmentHandle,
  detachBanner,
  type BannerAttachmentHandle,
} from './bannerAttachment';

function fakeContainer(): HTMLElement {
  return {} as HTMLElement;
}

/** 최소한의 유효한 AdSdk 기본값을 만든다. 개별 테스트는 필요한 필드만 override한다. */
function makeSdk(overrides: Partial<AdSdk> = {}): AdSdk {
  return {
    initialize: vi.fn(),
    attachBanner: vi.fn(),
    loadFullScreenAd: vi.fn(() => () => {}),
    showFullScreenAd: vi.fn(() => () => {}),
    ...overrides,
  };
}

/** 항상 성공하는 attachBanner를 가진 SDK. destroy는 spy로 감싸 호출 횟수를 검증한다. */
function makeSuccessfulSdk(destroy = vi.fn()): { sdk: AdSdk; destroy: ReturnType<typeof vi.fn> } {
  const sdk = makeSdk({
    attachBanner: vi.fn(() => ({ destroy })),
  });
  return { sdk, destroy };
}

describe('createBannerAttachmentHandle', () => {
  it('phase=idle, destroy=null인 초기 handle을 만든다', () => {
    const handle = createBannerAttachmentHandle();
    expect(handle).toEqual<BannerAttachmentHandle>({ phase: 'idle', destroy: null });
  });
});

describe('attachBanner', () => {
  it('성공하면 phase=attached로 전이하고 destroy 함수를 저장한다', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk, destroy } = makeSuccessfulSdk();

    attachBanner(handle, sdk, 'group-id', fakeContainer());

    expect(handle.phase).toBe('attached');
    expect(handle.destroy).toBeTypeOf('function');
    expect(sdk.attachBanner).toHaveBeenCalledTimes(1);
    expect(sdk.attachBanner).toHaveBeenCalledWith('group-id', expect.anything());
    expect(destroy).not.toHaveBeenCalled();
  });

  it('adGroupId===null이면 sdk.attachBanner를 호출하지 않고 phase=idle로 남는다', () => {
    const handle = createBannerAttachmentHandle();
    const sdk = makeSdk();

    attachBanner(handle, sdk, null, fakeContainer());

    expect(sdk.attachBanner).not.toHaveBeenCalled();
    expect(handle.phase).toBe('idle');
    expect(handle.destroy).toBeNull();
  });

  it('sdk.attachBanner가 유효하지 않은 결과(null)를 반환하면 phase=idle로 남는다', () => {
    const handle = createBannerAttachmentHandle();
    const sdk = makeSdk({ attachBanner: vi.fn(() => null as never) });

    attachBanner(handle, sdk, 'group-id', fakeContainer());

    expect(handle.phase).toBe('idle');
    expect(handle.destroy).toBeNull();
  });

  it('sdk.attachBanner가 동기적으로 throw해도 예외가 전파되지 않고 phase=idle로 남는다', () => {
    const handle = createBannerAttachmentHandle();
    const sdk = makeSdk({
      attachBanner: vi.fn(() => {
        throw new Error('boom');
      }),
    });

    expect(() => attachBanner(handle, sdk, 'group-id', fakeContainer())).not.toThrow();
    expect(handle.phase).toBe('idle');
    expect(handle.destroy).toBeNull();
  });

  it('이미 attached 상태면 두 번째 attach 호출은 완전히 무시된다(중복 광고 요청 방지)', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk } = makeSuccessfulSdk();

    attachBanner(handle, sdk, 'group-id', fakeContainer());
    attachBanner(handle, sdk, 'group-id', fakeContainer());
    attachBanner(handle, sdk, 'group-id', fakeContainer());

    expect(sdk.attachBanner).toHaveBeenCalledTimes(1);
    expect(handle.phase).toBe('attached');
  });
});

describe('detachBanner', () => {
  it('attached 상태에서 호출하면 destroy를 정확히 한 번 호출하고 phase=destroyed로 전이한다', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk, destroy } = makeSuccessfulSdk();
    attachBanner(handle, sdk, 'group-id', fakeContainer());

    detachBanner(handle);

    expect(destroy).toHaveBeenCalledTimes(1);
    expect(handle.phase).toBe('destroyed');
    expect(handle.destroy).toBeNull();
  });

  it('attach된 적 없는(idle) handle에 호출해도 안전하게 destroyed로 전이하고 아무것도 호출하지 않는다', () => {
    const handle = createBannerAttachmentHandle();

    expect(() => detachBanner(handle)).not.toThrow();
    expect(handle.phase).toBe('destroyed');
  });

  it('이미 destroyed 상태에서 다시 호출해도 destroy를 재호출하지 않는다(멱등)', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk, destroy } = makeSuccessfulSdk();
    attachBanner(handle, sdk, 'group-id', fakeContainer());

    detachBanner(handle);
    detachBanner(handle);
    detachBanner(handle);

    expect(destroy).toHaveBeenCalledTimes(1);
    expect(handle.phase).toBe('destroyed');
  });

  it('destroy()가 내부에서 throw해도 예외가 전파되지 않는다', () => {
    const handle = createBannerAttachmentHandle();
    const throwingDestroy = vi.fn(() => {
      throw new Error('destroy boom');
    });
    const { sdk } = makeSuccessfulSdk(throwingDestroy);
    attachBanner(handle, sdk, 'group-id', fakeContainer());

    expect(() => detachBanner(handle)).not.toThrow();
    expect(throwingDestroy).toHaveBeenCalledTimes(1);
    expect(handle.phase).toBe('destroyed');
  });
});

describe('StrictMode 이중 호출(setup -> cleanup -> setup) 재현', () => {
  /**
   * React 19 StrictMode(dev)는 effect를 setup -> cleanup -> setup 순서로
   * 두 번 실행한다. BannerSlot.tsx의 useEffect가 실제로 하는 일이 정확히
   * attachBanner -> detachBanner -> attachBanner이므로, 이 시퀀스를 handle
   * 하나에 그대로 재현해 검증한다.
   */
  it('attach -> detach -> attach를 반복해도 throw하지 않고, destroy는 정확히 한 번만, 최종적으로 정상 attached 상태로 귀결된다', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk, destroy } = makeSuccessfulSdk();
    const container = fakeContainer();

    expect(() => {
      // StrictMode 1차 setup
      attachBanner(handle, sdk, 'group-id', container);
      // StrictMode 가짜 cleanup(즉시 실행됨)
      detachBanner(handle);
      // StrictMode 2차 setup(진짜로 남는 마운트)
      attachBanner(handle, sdk, 'group-id', container);
    }).not.toThrow();

    // 두 번의 실제 attach(각각 진짜 SDK 요청)와, 그 사이 한 번의 destroy만 일어난다 -
    // "이중 요청"(동시에 두 개의 attach된 배너가 떠 있는 상태)은 없다.
    expect(sdk.attachBanner).toHaveBeenCalledTimes(2);
    expect(destroy).toHaveBeenCalledTimes(1);
    expect(handle.phase).toBe('attached');
    expect(handle.destroy).toBeTypeOf('function');
  });

  it('진짜 언마운트(마지막 detach)까지 이어져도 안전하고, 그 시점 destroy는 총 2번(중간 1번 + 최종 1번)만 호출된다', () => {
    const handle = createBannerAttachmentHandle();
    const { sdk, destroy } = makeSuccessfulSdk();
    const container = fakeContainer();

    attachBanner(handle, sdk, 'group-id', container); // StrictMode 1차 setup
    detachBanner(handle); // StrictMode 가짜 cleanup
    attachBanner(handle, sdk, 'group-id', container); // StrictMode 2차 setup(진짜 마운트)
    detachBanner(handle); // 진짜 언마운트

    expect(destroy).toHaveBeenCalledTimes(2);
    expect(handle.phase).toBe('destroyed');
    expect(handle.destroy).toBeNull();

    // 그 뒤로 언마운트 cleanup이 실수로 다시 호출돼도(React가 그렇게 하진
    // 않지만) 추가 destroy 호출은 없어야 한다.
    detachBanner(handle);
    expect(destroy).toHaveBeenCalledTimes(2);
  });
});
