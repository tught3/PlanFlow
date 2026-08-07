/**
 * P8: 배너 광고 슬롯 컴포넌트.
 *
 * 라우터에 직접 의존하지 않는다 - 현재 경로는 `pathname` prop으로 주입받아
 * 라우팅 로직과 완전히 분리한다(테스트하기 쉽고, 어떤 라우터를 쓰든 재사용
 * 가능). 실제 경로 전달은 이 작업 범위 밖(P9, 라우터 배선)에서 담당한다.
 *
 * `shouldShowBannerForPath`(bannerRoutes.ts)가 false를 반환하는 경로,
 * 또는 `getAdGroupIds().banner`가 아직 콘솔에서 발급되지 않아 `null`인
 * 경우(예: 이번 세션 기준 production 배너 광고 id 미발급 상태)에는
 * `null`을 렌더링한다 - 빈 배너 박스를 그리지 않는다(adService.ts에 이미
 * 명시된 "빈 배너 박스로 광고가 있는 척하지 않는다" 정책을 이 컴포넌트도
 * 그대로 따른다). adGroupId가 없는데 컨테이너 div만 그리면 실제로는 아무
 * 광고도 붙지 않은 채 `.ad-banner-slot`의 min-height/margin(adBannerStyles.ts)
 * 만큼의 빈 공간이 화면에 남는다 - 이 컴포넌트는 그 상태를 만들지 않는다.
 *
 * attach/detach의 실제 판단 로직(멱등성 포함)은 bannerAttachment.ts에 전부
 * 분리되어 있다 - 이 컴포넌트는 ref 두 개(container DOM 노드, attachment
 * handle)를 만들고 effect에서 그 함수들을 호출하기만 한다.
 */
import { useEffect, useRef } from 'react';

import { getAdGroupIds } from './adConfig';
import type { AdSdk } from './adService';
import { attachBanner, createBannerAttachmentHandle, detachBanner } from './bannerAttachment';
import { shouldShowBannerForPath } from './bannerRoutes';

export interface BannerSlotProps {
  /** 현재 라우트 pathname. 배너 노출 여부(shouldShowBannerForPath)를 이 값으로 판단한다. */
  pathname: string;
  /**
   * TossAds SDK 어댑터. 이 컴포넌트는 실제 SDK를 직접 import하지 않는다
   * (adService.ts의 안전 격리 원칙 - 화면 컴포넌트는 SDK를 직접 건드리지
   * 않는다) - 호출부(P9 라우터 배선)가 실제 배선된 SDK를 주입한다. 이
   * 저장소에는 아직 "기본 real SDK" DI 값이 따로 마련되어 있지 않으므로
   * (adService.test.ts의 makeSdk 같은 fake로만 존재) 필수 prop으로 받는다.
   */
  sdk: AdSdk;
}

export function BannerSlot({ pathname, sdk }: BannerSlotProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const handleRef = useRef(createBannerAttachmentHandle());
  const adGroupId = getAdGroupIds().banner;
  const visible = shouldShowBannerForPath(pathname) && adGroupId !== null;

  useEffect(() => {
    if (!visible) {
      return undefined;
    }

    const container = containerRef.current;
    if (container === null) {
      return undefined;
    }

    const handle = handleRef.current;
    attachBanner(handle, sdk, adGroupId, container);

    return () => {
      detachBanner(handle);
    };
    // pathname을 deps에 포함해 배너가 계속 보이는 경로 사이를 이동해도(예:
    // /calendar/month -> /calendar/week) 매 경로마다 새로 attach한다.
  }, [visible, pathname, sdk, adGroupId]);

  if (!visible) {
    return null;
  }

  return <div ref={containerRef} className="ad-banner-slot" />;
}
