import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router-dom'
import './index.css'
import { router } from './router.tsx'
import { initializeAds } from './features/ads/adService.ts'
import { recordFirstUseIfAbsent } from './features/ads/adState.ts'
import { realAdSdk, realAdStatePort } from './features/ads/adRuntime.ts'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
)

// 광고 초기화/최초사용 기록은 앱의 첫 렌더를 절대 지연·차단하지 않는다 -
// 위 render() 호출과 무관하게 fire-and-forget으로 실행한다.
// initializeAds/recordFirstUseIfAbsent는 각자 파일(adService.ts/adState.ts)의
// 계약상 이미 절대 throw/reject하지 않지만, "광고는 핵심 기능을 절대
// 저하시키지 않는다"는 이 앱 전체의 안전 원칙에 따라 이 호출부에서도 한 번
// 더 방어적으로 감싼다(심층 방어) - 실패해도 이 부트스트랩 코드 자체가
// 앱 렌더링에 영향을 주지 않는다.
void initializeAds(realAdSdk).catch(() => undefined)
void recordFirstUseIfAbsent(realAdStatePort).catch(() => undefined)
