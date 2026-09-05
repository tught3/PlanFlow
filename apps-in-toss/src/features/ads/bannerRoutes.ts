/**
 * P7: 배너 광고를 노출할 라우트를 결정하는 순수 함수.
 *
 * fail-closed(default-deny) 원칙: 아래 allowlist의 정확히 3개 경로에서만 true.
 * 그 외 모든 경로(신규/미지 라우트 포함)는 false — 새 라우트가 추가돼도
 * 이 파일을 명시적으로 수정하지 않는 한 배너가 자동으로 노출되지 않는다.
 */
const BANNER_ALLOWED_PATHS = ['/today', '/calendar/month', '/calendar/week'] as const;

/**
 * 주어진 pathname 문자열 하나를 비교 가능한 형태로 정규화한다.
 * - 쿼리스트링(`?foo=bar`)과 해시(`#frag`)는 제거한다: 배너 노출 여부는
 *   경로 자체로만 결정하고, 쿼리 파라미터로 우회/차단되지 않게 한다.
 * - 끝의 슬래시(trailing slash)는 제거한다: `/today/`와 `/today`를 같은
 *   경로로 취급한다(루트 `/` 자체는 제거 후에도 빈 문자열이 되지 않도록 보존).
 */
function normalizePathname(pathname: string): string {
  const withoutQueryAndHash = pathname.split('?')[0]?.split('#')[0] ?? '';

  if (withoutQueryAndHash.length > 1 && withoutQueryAndHash.endsWith('/')) {
    return withoutQueryAndHash.slice(0, -1);
  }

  return withoutQueryAndHash;
}

/**
 * 해당 pathname에서 배너를 노출해야 하는지 여부.
 * BANNER_ALLOWED_PATHS에 정확히 일치하는 경로에서만 true를 반환한다(default-deny).
 */
export function shouldShowBannerForPath(pathname: string): boolean {
  const normalized = normalizePathname(pathname);
  return (BANNER_ALLOWED_PATHS as readonly string[]).includes(normalized);
}
