/**
 * 개발 미리보기 모드 게이트.
 *
 * import.meta.env.DEV는 Vite가 production 빌드(`vite build`)에서 정적으로
 * `false` 리터럴로 치환하는 빌드타임 상수다(dev 서버/`vitest`에서는 true).
 * 이 게이트는 반드시 `import.meta.env.DEV && import.meta.env.VITE_DEV_PREVIEW
 * === '1'` 순서로 평가해야 한다 - `import.meta.env.DEV`가 리터럴 `false`로
 * 치환되면 `&&`의 단락평가(short-circuit) 덕분에 오른쪽 피연산자
 * (VITE_DEV_PREVIEW 조회)는 애초에 평가되지 않고, 이 표현식 전체가 production
 * 빌드에서 `false`로 완전히 접힌다(JS 언어 시맨틱상 항상 안전한 최적화) -
 * 즉 어떤 값을 실수로 VITE_DEV_PREVIEW에 넣어 배포해도(예: .env.production에
 * 잘못 남은 값) production 빌드에서는 이 게이트가 무조건 false다.
 *
 * secret/service_role/토스 인증정보는 이 모듈이 일절 참조하지 않는다.
 * useSession()이 이 게이트가 켜졌을 때 supabase.auth를 전혀 호출하지 않고
 * 즉시 완료된 모의(mock) 세션을 반환하도록 하는 게 이 게이트의 유일한 책임이다.
 */

/**
 * 프로덕션 번들에 이 모듈이 죽은 코드로 남지 않고 실제로 제거됐는지 검증하는
 * 고정 마커 문자열. resolveDevPreviewEnabled()의 값과 무관하게 이 모듈이
 * 참조되는 코드 경로가 남아있으면(트리쉐이킹 실패) 이 문자열도 번들에 남는다.
 * scripts/scan-bundle.mjs가 `npm run build` 산출물(dist/)에서 이 마커를
 * 찾으면 빌드를 실패시킨다 - 검증: `npm run build` 후
 * `grep -c "PLANFLOW_DEV_PREVIEW_ENABLED" dist/assets/*.js` 가 0이어야 한다.
 */
export const PLANFLOW_DEV_PREVIEW_MARKER = 'PLANFLOW_DEV_PREVIEW_ENABLED';

/**
 * 개발 미리보기 모드에서 useSession()이 반환할 고정 mock 사용자 id.
 *
 * 일부러 UUID 형태(32자+ 하이픈/숫자 조합)를 쓰지 않는다 - previewRepository
 * 는 게이트가 꺼져 있어도(production) 모듈 자체는 라우터가 정적으로 import해
 * 참조하므로(반드시 previewRepository가 즉시 평가 가능한 값이어야 라우터가
 * 동기적으로 repository prop을 주입할 수 있다), 이 문자열은 tree-shaking
 * 여부와 무관하게 production 번들에 실제로 포함될 수 있다. UUID 모양의
 * 32자+ 숫자밀집 문자열은 scripts/scan-bundle.mjs의 "긴 hex/base64 토큰"
 * 휴리스틱(진짜 시크릿 탐지용, fail-closed)에 그대로 걸려 오탐을 낸다 -
 * 실측: `npm run build && npm run secret-scan`이 이 값을 "possible raw
 * secret"로 잡아 exit 1을 냈다. 짧고 사람이 읽을 수 있는 문자열(32자 미만)로
 * 바꿔 그 휴리스틱을 원천적으로 벗어난다.
 */
export const DEV_PREVIEW_USER_ID = 'dev-preview-user';

export interface DevPreviewGateInput {
  /** import.meta.env.DEV. dev 서버/vitest에서 true, production 빌드에서 항상 false. */
  isDev: boolean;
  /** import.meta.env.VITE_DEV_PREVIEW. .env(.local)에서 명시적으로 '1'로 설정해야만 켜진다. */
  viteDevPreviewFlag: string | boolean | undefined;
}

/**
 * (isDev, viteDevPreviewFlag) -> 게이트 활성 여부로 변환하는 순수 함수.
 * import.meta.env를 직접 읽지 않으므로 vitest에서 env 스터빙 없이도
 * 결정적으로 테스트할 수 있다(ConfirmDialog.resolveConfirmState와 동일한 패턴).
 */
export function resolveDevPreviewEnabled({ isDev, viteDevPreviewFlag }: DevPreviewGateInput): boolean {
  return isDev === true && viteDevPreviewFlag === '1';
}

/** 게이트 = import.meta.env.DEV && import.meta.env.VITE_DEV_PREVIEW === '1'. 기본 비활성. */
export function isDevPreviewEnabled(): boolean {
  return resolveDevPreviewEnabled({
    isDev: import.meta.env.DEV,
    viteDevPreviewFlag: import.meta.env.VITE_DEV_PREVIEW,
  });
}

/** 개발 미리보기 모드에서 즉시 확정되는 mock 세션 값. */
export interface PreviewSessionState {
  userId: string;
  loading: false;
}

/**
 * 게이트 활성 여부로부터 "mock 세션을 반환할지"를 결정하는 순수 함수.
 *
 * gateEnabled=false면 null을 반환한다 - 이는 "mock을 반환하지 않는다"를
 * 뜻하며, 호출부(useSession)는 이 경우 기존 supabase.auth 흐름을 그대로
 * 진행해야 한다(즉 게이트가 꺼져 있으면 supabase.auth가 여전히 호출된다).
 * gateEnabled=true면 즉시 loading:false인 mock 세션을 반환하고, 호출부는
 * 이 값을 받은 즉시 상태를 확정하며 supabase.auth를 전혀 호출하지 않는다.
 */
export function resolvePreviewSessionState(gateEnabled: boolean): PreviewSessionState | null {
  if (!gateEnabled) {
    return null;
  }
  return { userId: DEV_PREVIEW_USER_ID, loading: false };
}
