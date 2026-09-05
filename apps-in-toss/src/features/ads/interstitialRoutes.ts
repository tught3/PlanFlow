/**
 * P9(라우터 배선): 전면 광고 적격성 체크를 "시도"할 정착(settled) 라우트를
 * 결정하는 순수 함수.
 *
 * 전면 광고 적격성 체크(adPolicy.ts의 canShowInterstitial)는 라우트가 바뀔
 * 때마다 무조건 실행하면 안 된다 - 편집 중(isEditingEvent), 저장 대기 중
 * (isSavePending), 삭제 확인 중(isDeleteConfirming) 같은 중간 상태에서는
 * 절대 실행하면 안 된다. 이 프로젝트의 라우트 구조상 그 중간 상태들은 전부
 * "같은 경로에 머무른 채" 내부 컴포넌트 상태로만 표현되고 경로 자체는
 * 바뀌지 않는다(폼 입력 중은 /event/new 또는 /event/:id/edit 안에서,
 * 삭제 확인 다이얼로그는 /event/:id 안에서 발생 - router.tsx 참고). 그래서
 * "경로가 바뀌어 아래 allowlist에 새로 도달했다"는 사실 자체가 그 중간
 * 상태가 아님을 구조적으로 보장한다 - 다이얼로그가 열려 있는 동안이나 폼이
 * 제출 중인 동안에는 라우트가 변하지 않으므로 이 함수를 트리거하는 라우터
 * 이벤트 자체가 발생하지 않는다.
 *
 * fail-closed(default-deny) 원칙: bannerRoutes.ts와 동일하게, 아래
 * allowlist에 해당하는 경로에서만 true를 반환한다. 새 라우트가 추가돼도
 * 이 파일을 명시적으로 수정하지 않는 한 자동으로 트리거되지 않는다.
 *
 * 정착 지점 3종:
 * - /today, /calendar/month, /calendar/week: 목록/브리핑 화면. 세션이
 *   가장 오래 머무르는 화면이라 자연스러운 트리거 지점이다.
 * - /event/:id(상세): 방금 생성/수정을 완료하고 도달한 화면이거나
 *   (EventForm의 onSaved가 navigate(`/event/${event.id}`)), 목록에서
 *   상세로 막 진입한 직후 - 삭제 확인 다이얼로그를 열기 "이전" 시점이다.
 *   /event/new(생성 폼)와 /event/:id/edit(수정 폼)는 명시적으로 제외한다.
 */
const SETTLED_STATIC_PATHS = ['/today', '/calendar/month', '/calendar/week'] as const;

/**
 * 쿼리스트링/해시를 제거하고 trailing slash를 정리한다.
 * bannerRoutes.ts의 normalizePathname과 동일한 정규화 규칙(중복 방지를 위해
 * 그 파일을 import하지 않고 독립적으로 유지한다 - 이 함수는 향후 정착 지점
 * 규칙이 배너 규칙과 갈라질 수 있어 결합하지 않는다).
 */
function normalizePathname(pathname: string): string {
  const withoutQueryAndHash = pathname.split('?')[0]?.split('#')[0] ?? '';

  if (withoutQueryAndHash.length > 1 && withoutQueryAndHash.endsWith('/')) {
    return withoutQueryAndHash.slice(0, -1);
  }

  return withoutQueryAndHash;
}

/**
 * `/event/:id` 형태(정확히 2개 세그먼트, id가 'new'가 아님)인지 판정한다.
 * `/event/:id/edit`는 세그먼트가 3개라 자동으로 제외된다.
 */
function isEventDetailPath(normalized: string): boolean {
  const segments = normalized.split('/').filter((segment) => segment.length > 0);
  if (segments.length !== 2 || segments[0] !== 'event') {
    return false;
  }
  const id = segments[1];
  return id !== undefined && id !== 'new';
}

/** 해당 pathname이 전면 광고 적격성 체크를 시도해도 되는 정착 지점인지 여부. */
export function isSettledRouteForInterstitial(pathname: string): boolean {
  const normalized = normalizePathname(pathname);
  if ((SETTLED_STATIC_PATHS as readonly string[]).includes(normalized)) {
    return true;
  }
  return isEventDetailPath(normalized);
}
