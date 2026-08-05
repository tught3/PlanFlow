# Apps in Toss 비게임 앱 심사 체크리스트 대응표

출처: [Apps in Toss 비게임 앱 심사 체크리스트](https://developers-apps-in-toss.toss.im/checklist/app-nongame.html)
(2026-08-05 WebFetch로 확인. 원문 페이지가 404를 반환해 동일 도메인의
`app-nongame.md` 마크다운 버전으로 확인함. 원문 표현이 확인되지 않은
항목은 "일반 원칙"으로 표시하고 재확인이 필요함을 명시함.)

이 문서는 심사 체크리스트의 카테고리별로 PlanFlow Apps in Toss 미니앱이
어떻게 대응하는지, 그리고 그 근거가 되는 코드/설정 파일 경로를 정리한다.
새 기능을 추가할 때는 이 표를 먼저 확인하고, 해당 안 되는 항목이 생기면
이 문서를 함께 갱신한다.

## 1. 로그인 (Toss Login)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 로그인 수단은 토스 로그인만 허용, 자체 로그인 금지 | 구현 완료. `LoginScreen`은 토스 로그인 버튼 1개만 노출하고, 이메일/비밀번호 입력 필드를 두지 않는다. 실제 인증은 `TossAuth.login()` → `toss-login` Edge Function → `supabase.auth.verifyOtp`로 발급받은 세션이며, 사용자에게 노출되는 로그인 경로는 토스 로그인 하나뿐이다(자체 로그인 UI 금지 규정과의 관계는 `docs/toss-login-setup.md` 4절 참고). | `src/features/auth/LoginScreen.tsx`, `src/features/auth/tossLogin.ts` |
| 로그인 거부 시 앱 종료 | 구현 완료. 로그인 취소(`user_cancelled`) 및 그 외 모든 실패 코드에서 `buildLoginScreenState()`가 "다시 시도"/"앱 종료" 선택지를 함께 제공하고, "앱 종료"는 `@apps-in-toss/web-framework`의 `closeView()`를 호출한다. | `src/features/auth/LoginScreen.tsx`, `src/features/auth/tossLogin.ts` |
| 로그아웃 시 사용자 데이터 삭제 | **미구현(TODO)**. 로그아웃 진입점(버튼/메뉴) 자체가 아직 UI에 없다. 세션 상태 구독(`useSession`)만 구현되어 있고, 로그아웃 액션과 그에 따른 로컬 캐시 정리 정책은 이번 라운드 범위에서 제외했다. | 해당 코드 미존재 |
| 인트로 페이지에 서비스 설명 및 약관 URL 표시 | 구현 완료. `LoginScreen`에 서비스 설명 문구("토스 계정으로 로그인하고 AI 음성 일정 관리를 시작하세요")와 개인정보처리방침 링크(`openURL`로 외부 브라우저에서 열림)를 표시한다. 단, 이 URL 자체가 다른 문서(`docs/play-console-*.md`)와 불일치하는 문제는 "미확정/재확인 필요" 절 참고. | `src/features/auth/LoginScreen.tsx` |

## 2. 사용자 식별 (User Identification)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 사용자 식별자 값 확인 후 저장 | 구현 완료. `toss-login` Edge Function이 토스 인증 결과를 검증해 `toss_identities` 테이블에 토스 사용자 식별자와 Supabase `auth.users.id`를 매핑해 저장하고, 클라이언트는 `supabase.auth.verifyOtp`로 발급받은 Supabase 세션의 user id를 사용한다. | `supabase/migrations/20260806000000_*.sql`, `supabase/functions/toss-login/logic.ts`, `src/features/auth/tossLogin.ts` |
| 앱 재실행/재시작 시 데이터 유지 | 구현 완료(세션 부분). `useSession`이 마운트 시 `supabase.auth.getSession()`으로 기존 세션을 복원하고 `onAuthStateChange`를 구독해, 앱을 재실행해도 이미 로그인된 사용자는 다시 로그인 화면을 거치지 않는다. 이벤트/설정 데이터 자체는 로컬 캐시 없이 Supabase를 단일 소스로 삼아 매 실행 시 조회한다. | `src/features/auth/useSession.ts`, `src/router.tsx`(`AuthGate`), `src/domain/`(다른 병렬 작업에서 구현 중, 본 작업 범위 아님) |

## 3. 보안 및 안정성 (Security & Stability)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| `eval()` 등 외부 코드 실행 금지 | 빌드 산출물(`dist/`)에서 `eval(` 리터럴이 없는지 빌드 시 자동 스캔한다. | `scripts/scan-bundle.mjs`, `package.json`(`secret-scan` 스크립트) |
| 서버사이드 렌더링 금지, 클라이언트 렌더링만 | Vite + React SPA로 빌드되며 SSR 파이프라인을 두지 않는다. | `vite.config.ts`, `src/main.tsx` |
| 브라우저 히스토리 조작으로 외부→자사 사이트 리다이렉트 금지 | `react-router-dom`의 표준 클라이언트 라우팅만 사용하고, `history.replaceState`/`pushState`를 임의 조작하는 코드를 두지 않는다. | `src/router.tsx` |
| WebSocket은 `wss://`(암호화) 연결만 허용 | 현재 WebSocket을 사용하지 않음. 추후 실시간 기능 도입 시 `wss://`만 허용하도록 이 표를 갱신해야 함(TODO). | 해당 코드 미존재 |
| Supabase `service_role` 키 등 민감 키 클라이언트 번들 미노출 | 빌드 산출물에서 `service_role` 문자열, 32자 이상 hex/base64 토큰을 자동 스캔해 발견 시 빌드를 실패시킨다. `service_role` 키는 클라이언트 코드/환경변수에 절대 넣지 않고, `anon`/공개 키만 사용한다. 토스 로그인 연동에 필요한 서버 전용 시크릿(mTLS 인증서/개인키, clientId/clientSecret, PII 복호화 키 등)도 동일 원칙으로 클라이언트 `.env`에는 절대 넣지 않고 Supabase Edge Function secret으로만 등록한다. | `scripts/scan-bundle.mjs`, `.env.example`(anon 키만 노출, 시크릿 목록은 `docs/toss-login-setup.md` 참고) |

## 4. 서비스 이용 행태 (Service Usage Behavior)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 불필요한 제스처 줌 비활성화 | 뷰포트 메타 태그로 확대/축소를 제한한다. | `index.html` |
| 라이트 모드 테마 유지 | 다크모드 강제 전환 없이 기본 라이트 테마를 유지한다. | `src/App.css`, `src/index.css` |
| 2초 이내 응답성 유지 | 데이터 페칭은 `src/data/`, `src/domain/` 계층에서 처리하며 무거운 동기 연산을 렌더 경로에 두지 않는다. | `src/data/index.ts` |
| 앱 종료 후에도 사용자 데이터 유지 | 3번 항목과 동일 — Supabase를 단일 소스로 유지. | `src/data/index.ts` |
| 공유 시 `intoss://` 스킴 사용 | 공유 기능 도입 시 `intoss://` 스킴을 사용하도록 구현 예정(TODO, 현재 공유 기능 미구현). | 해당 코드 미존재 |
| 비속어 금지 | 정적 텍스트(라벨/안내문구)에 비속어를 포함하지 않는다. | `src/App.tsx`, 각 화면 컴포넌트 |
| 예상치 못한 네트워크/메모리 급증 방지 | 반복 폴링이나 무한 루프 없이 사용자 액션 기반 요청만 수행한다. | `src/data/index.ts` |

## 5. 개인정보(PII) 보호

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 개인정보 최소 수집 | 위치/카메라/연락처 등 민감 권한을 요청하지 않는다(아래 6번 참조). | `apps-in-toss.config.ts` |
| 로그·콘솔 출력에 PII 평문 노출 금지 | `title`/`memo`/`participants`/`location`/`phone`/`email` 등 PII 필드는 로깅 전 반드시 `sanitizeForLog`로 마스킹한다. 이벤트 객체를 통째로 `console.log`하는 경로를 두지 않는다. | `src/observability/logger.ts`, `src/observability/logger.test.ts` |
| 분석(analytics) 이벤트에 PII 미포함 | `track()`은 현재 `console.debug`만 수행하는 스텁이며, 네트워크 전송이 없다. 실제 분석 백엔드 연동 시에도 PII 필드를 props로 넘기지 않아야 한다. | `src/observability/analytics.ts` |

## 6. 권한 (Permissions)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 위치 권한 미사용 | 위치 기반 기능(이동 시간 버퍼 등)은 이번 Apps in Toss 미니앱 범위에 포함하지 않는다. | `apps-in-toss.config.ts` |
| 카메라 권한 미사용 | 카메라를 사용하는 기능이 없다. | `apps-in-toss.config.ts` |
| 권한 요청 전 사용자 동의, 거부해도 나머지 기능 정상 동작 | 현재 권한을 요구하는 기능이 없으므로 해당 없음. 추후 권한이 필요한 기능 추가 시 동의 흐름과 거부 시 폴백을 함께 구현해야 함(TODO). | 해당 코드 미존재 |

## 7. 외부 링크 (External Links)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 외부 링크는 새 탭/외부 브라우저로만 열기, 자사 사이트로 임의 리다이렉트 금지 | 외부 링크(약관, 고객센터 등)를 추가할 때 `target="_blank"` + `rel="noopener noreferrer"`를 사용하고, 히스토리 조작으로 자사 사이트로 우회하지 않는다(TODO, 현재 외부 링크 미구현). | 해당 코드 미존재 |

## 8. 저장소/데이터 (Storage)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 원본 데이터 저장소 | 모든 이벤트/일정 데이터의 단일 소스는 기존 PlanFlow(Flutter 앱)와 동일한 Supabase(PostgreSQL) 프로젝트이며, 별도의 자체 DB를 새로 두지 않는다. | `src/data/index.ts`, `src/domain/`(다른 병렬 작업 범위) |
| 클라이언트에는 공개(anon) 키만 노출 | 클라이언트 번들에는 Supabase `anon` 공개 키만 포함하고 `service_role` 키는 절대 포함하지 않는다. 빌드 시 자동 스캔으로 검증한다. | `scripts/scan-bundle.mjs`, `.env.example` |

## 미확정/재확인 필요 항목

- 인앱결제(Toss Pay), 인앱 광고, 리퍼럴 리워드 관련 세부 항목은
  이번 스캐폴딩 단계에서 아직 해당 기능이 구현되지 않아 "TODO"로 표시했다.
  각 기능을 실제로 구현하는 시점에 원문 체크리스트를 다시 확인하고 이
  표를 갱신해야 한다.
- 원문 페이지(`app-nongame.html`)가 스캔 시점에 404를 반환해 `.md`
  버전으로 대체 확인했다. 배포 전 담당자가 최신 원문을 직접 열람해
  이 표와 대조하는 것을 권장한다.
- **개인정보처리방침 URL 불일치(P7에서 발견)**: `docs/play-console-data-safety.md`
  (프로젝트 루트, `E:\FluxStudio\PlanFlow-AppsInToss\docs\`)의 15행은
  `https://fluxstudio.co.kr/privacy`를 정본으로 쓰는 반면, 같은 위치의
  `docs/play-console-submission.md`는 `https://tught3.github.io/PlanFlow/privacy-policy.html`을
  쓴다. `LoginScreen`의 `PRIVACY_POLICY_URL` 상수는 현재 데이터 보안 답변표
  (`play-console-data-safety.md`) 쪽 값을 정본으로 간주해 사용 중이다
  (`src/features/auth/LoginScreen.tsx`의 관련 TODO 주석 참고). 실제 제출/심사
  전에 어느 URL이 최신·정본인지 확인하고, 세 문서(두 Play Console 문서 +
  `LoginScreen.tsx`의 상수)를 동일한 값으로 맞춰야 한다.
- 아래 항목은 이번 라운드에서 의도적으로 구현하지 않았다(TODO로 유지,
  완료로 표시하지 않는다). 사유와 상세는 `docs/toss-login-setup.md` 3절 참고.
  - **mTLS 실호출**: `toss-login` Edge Function은 `mtls_unsupported` 에러
    코드만 정의되어 있고, 실제 mTLS 클라이언트 인증서를 붙인 토스 API
    호출부는 구현하지 않았다(501/TODO로 남김).
  - **PII 복호화**: 복호화 키 수령 경로 자체가 미확정이라 복호화 로직을
    구현하지 않았다.
  - **로그아웃 UI**: 위 1절 참고 — 로그아웃 진입점과 데이터 정리 정책이
    아직 없다.
  - **rate limit**: `toss-login` Edge Function 호출 빈도 제한을 아직
    설계하지 않았다.
