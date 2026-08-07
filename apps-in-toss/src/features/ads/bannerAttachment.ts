/**
 * P8: 배너 컨테이너의 attach/detach 생명주기를 다루는 순수 로직.
 *
 * `attachBannerToContainer`(adService.ts)는 이미 SDK 실패를 전부 흡수해
 * `throw`/`reject`하지 않지만, "여러 번 attach를 시도해도 SDK에 중복 요청을
 * 보내지 않는다"와 "여러 번 destroy를 호출해도 안전하다"는 계약은 그 호출부
 * (React effect)의 책임이다. 이 파일이 그 책임을 React 훅과 분리된 plain
 * 함수로 구현한다 - `BannerSlot.tsx`는 `useRef`로 만든 handle 객체를 여기
 * 함수들에 넘기기만 하고, 실제 attach/detach 판단 로직은 전부 여기 있다.
 *
 * 이 분리 덕분에 jsdom 없이도(DOM/React 렌더링 없이) plain 함수 호출만으로
 * StrictMode의 "attach -> detach -> attach" 재현 시퀀스를 직접 재현해
 * 테스트할 수 있다 - src/components/ConfirmDialog.tsx가 `resolveConfirmState`를
 * 분리한 것과 같은 이유(jsdom 미설치, 순수 로직은 컴포넌트 밖에서 검증)다.
 *
 * 상태 전이(idle -> attaching -> attached -> destroyed)는 계획서에서 요구한
 * 4단계를 그대로 따른다. `attaching`은 `attachBannerToContainer`가 동기
 * 함수라 사실상 순간적으로 지나가지만, 중복 호출 가드 지점을 명확히 하기 위해
 * 명시적인 phase로 남겨둔다.
 */

import { attachBannerToContainer, type AdSdk } from './adService';

export type BannerAttachmentPhase = 'idle' | 'attaching' | 'attached' | 'destroyed';

/**
 * 배너 하나의 attach 생명주기를 담는 mutable handle.
 * React 훅이 아니라 `useRef(createBannerAttachmentHandle())`로 만들어 컴포넌트가
 * 들고 있다가 effect setup/cleanup마다 이 파일의 함수에 그대로 넘긴다.
 */
export interface BannerAttachmentHandle {
  phase: BannerAttachmentPhase;
  /** 현재 attach된 배너의 정리 함수. attached 상태가 아니면 항상 null. */
  destroy: (() => void) | null;
}

/** 아직 아무것도 attach하지 않은 초기 handle을 만든다. */
export function createBannerAttachmentHandle(): BannerAttachmentHandle {
  return { phase: 'idle', destroy: null };
}

/**
 * handle을 attach 상태로 전이시킨다.
 *
 * 멱등(idempotent) 보장: handle이 이미 `attaching`/`attached`면 아무 것도 하지
 * 않고 즉시 반환한다 - 같은 handle에 attach를 두 번 연속 호출해도(예: effect가
 * 의도치 않게 두 번 실행됨) SDK에 중복으로 광고를 요청하지 않는다. `destroyed`나
 * `idle`에서는 정상적으로 재시도한다 - StrictMode의 attach -> detach -> attach
 * 재현 시퀀스에서 두 번째 attach는 반드시 실제로 다시 attach해야 하므로(첫
 * attach는 이미 detach로 정리됐다), 이 경우까지 막으면 안 된다.
 *
 * `attachBannerToContainer` 자체는 절대 throw하지 않으므로(adService.ts의
 * 안전 계약) 이 함수도 throw하지 않는다.
 */
export function attachBanner(
  handle: BannerAttachmentHandle,
  sdk: AdSdk,
  adGroupId: string | null,
  container: HTMLElement,
): void {
  if (handle.phase === 'attaching' || handle.phase === 'attached') {
    return;
  }

  handle.phase = 'attaching';
  const result = attachBannerToContainer(sdk, adGroupId, container);

  if (result === null) {
    // adGroupId===null이거나 SDK가 유효한 결과를 못 준 경우 - "빈 배너 박스"를
    // 만들지 않고 idle로 되돌린다(adService.ts의 fail-closed 계약과 동일).
    handle.phase = 'idle';
    handle.destroy = null;
    return;
  }

  handle.phase = 'attached';
  handle.destroy = result.destroy;
}

/**
 * handle을 destroyed 상태로 전이시키고, attached 상태였다면 정리 함수를 호출한다.
 *
 * 멱등 보장: handle이 이미 `destroyed`면 아무 것도 하지 않고 즉시 반환한다 -
 * `destroy`를 두 번 이상 호출하지 않는다(StrictMode의 cleanup이 중복 실행되거나,
 * 호출부가 실수로 두 번 부르는 경우 모두 안전). `attaching`/`idle`에서 호출되면
 * (attach가 진행 중이거나 애초에 attach된 적이 없는 경우) destroy할 대상이
 * 없으므로 단순히 destroyed로 전이만 한다.
 *
 * `result.destroy()` 자체는 이미 adService.ts의 attachBannerToContainer가
 * 내부에서 try/catch로 감싸 절대 throw하지 않지만, 이 함수는 그 계약이 깨지는
 * 경우에도 컴포넌트를 절대 깨뜨리지 않도록 한 번 더 방어적으로 감싼다
 * (adService.ts와 동일한 "정리 호출은 실패해도 호출부를 깨뜨리지 않는다" 원칙).
 */
export function detachBanner(handle: BannerAttachmentHandle): void {
  if (handle.phase === 'destroyed') {
    return;
  }

  const destroyFn = handle.destroy;
  handle.phase = 'destroyed';
  handle.destroy = null;

  if (destroyFn === null) {
    return;
  }

  try {
    destroyFn();
  } catch {
    // destroy()는 정리(cleanup) 호출이다 - 실패해도 호출부(React effect cleanup)를
    // 절대 깨뜨리지 않는다.
  }
}
