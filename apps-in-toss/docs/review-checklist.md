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
| 로그인 수단은 토스 로그인만 허용, 자체 로그인 금지 | 구현 완료.[^mtls-501] `LoginScreen`은 토스 로그인 버튼 1개만 노출하고, 이메일/비밀번호 입력 필드를 두지 않는다. 실제 인증은 `TossAuth.login()` → `toss-login` Edge Function → `supabase.auth.verifyOtp`로 발급받은 세션이며, 사용자에게 노출되는 로그인 경로는 토스 로그인 하나뿐이다(자체 로그인 UI 금지 규정과의 관계는 `docs/toss-login-setup.md` 4절 참고). | `src/features/auth/LoginScreen.tsx`, `src/features/auth/tossLogin.ts` |
| 로그인 거부 시 앱 종료 | 구현 완료.[^mtls-501] 로그인 취소(`user_cancelled`) 및 그 외 모든 실패 코드에서 `buildLoginScreenState()`가 "다시 시도"/"앱 종료" 선택지를 함께 제공하고, "앱 종료"는 `@apps-in-toss/web-framework`의 `closeView()`를 호출한다. | `src/features/auth/LoginScreen.tsx`, `src/features/auth/tossLogin.ts` |
| 로그아웃 시 사용자 데이터 삭제 | 구현 완료(D1). `AppLayout`(`src/router.tsx`) 헤더에 로그아웃 버튼을 추가했고, 클릭 시 `ConfirmDialog`로 확인을 받은 뒤에만 `supabase.auth.signOut()`을 호출해 `/login`으로 이동한다(확인 전 `signOut` 미호출 계약은 `appLayoutLogout.test.ts`로 고정). 이 앱은 이벤트/설정 데이터를 별도 로컬 캐시 없이 Supabase를 단일 소스로 매 요청 조회하므로(8절 참고), `signOut()`으로 세션이 끊기는 순간 그 세션에 결부된 로컬 접근 경로가 사라져 "로그아웃 시 사용자 데이터 삭제" 요구를 충족한다(로컬에 남아 지워야 할 캐시 자체가 없음 — 근거는 `src/router.tsx`의 `AppLayout` 주석). | `src/router.tsx`(`AppLayout`, `handleLogout`), `src/appLayoutLogout.ts`, `src/appLayoutLogout.test.ts` |
| 인트로 페이지에 서비스 설명 및 약관 URL 표시 | 구현 완료.[^mtls-501] `LoginScreen`에 서비스 설명 문구("토스 계정으로 로그인하고 AI 음성 일정 관리를 시작하세요")와 개인정보처리방침 링크(`openURL`로 외부 브라우저에서 열림)를 표시한다. 단, 이 URL 자체가 다른 문서(`docs/play-console-*.md`)와 불일치하는 문제는 "미확정/재확인 필요" 절 참고. | `src/features/auth/LoginScreen.tsx` |

## 2. 사용자 식별 (User Identification)

| 항목 | 대응방식 | 근거 파일경로 |
|------|----------|----------------|
| 사용자 식별자 값 확인 후 저장 | 코드 작성 완료, 단위테스트 미작성(mTLS 게이트로 현재 미실행 상태).[^mtls-501][^link-issue-no-test] `toss-login` Edge Function의 `linkAndIssueSession()`이 토스 인증 결과를 검증해 `toss_identities` 테이블에 토스 사용자 식별자와 Supabase `auth.users.id`를 매핑해 저장하고, 클라이언트는 `supabase.auth.verifyOtp`로 발급받은 Supabase 세션의 user id를 사용한다. | `supabase/migrations/20260806000000_*.sql`, `supabase/functions/toss-login/index.ts`(`linkAndIssueSession`), `supabase/functions/toss-login/logic.ts`, `src/features/auth/tossLogin.ts` |
| 앱 재실행/재시작 시 데이터 유지 | 구현 완료(세션 부분).[^mtls-501] `useSession`이 마운트 시 `supabase.auth.getSession()`으로 기존 세션을 복원하고 `onAuthStateChange`를 구독해, 앱을 재실행해도 이미 로그인된 사용자는 다시 로그인 화면을 거치지 않는다. 이벤트/설정 데이터 자체는 로컬 캐시 없이 Supabase를 단일 소스로 삼아 매 실행 시 조회한다. | `src/features/auth/useSession.ts`, `src/router.tsx`(`AuthGate`), `src/domain/`(다른 병렬 작업에서 구현 중, 본 작업 범위 아님) |

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
| 불필요한 제스처 줌 비활성화 | 구현 완료(A4). `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">`로 핀치줌/더블탭줌을 막고, 노치 기기 세이프에어리어(`viewport-fit=cover`)까지 지정했다. | `index.html` |
| 라이트 모드 테마 유지 | 구현 완료. `src/styles/base.css`가 `:root { color-scheme: light; }`로 라이트 테마를 고정하며, 이 프로젝트 어디에도 `prefers-color-scheme` 다크모드 미디어쿼리를 두지 않는다(전체 `src/` 검색으로 확인, 실측 0건). 과거 이 행이 가리키던 `src/App.css`는 A5(미사용 스캐폴드 정리) 커밋에서 삭제됐고, 스타일 진입점은 `src/index.css`가 6개 파일(`tokens.css`/`base.css`/`layout.css`/`components.css`/`screens.css`/`event.css`)을 import하는 구조로 재구성됐다(A2/A3) — 이 행의 근거 경로를 그 재구성 이후 실제 위치로 정정했다. | `src/index.css`, `src/styles/base.css` |
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

## 9. 개발 미리보기 모드 (devPreview) — 심사 대상 빌드에 미포함되는 이유

이 앱은 로컬 개발 편의를 위해 `import.meta.env.DEV && import.meta.env.VITE_DEV_PREVIEW === '1'`
게이트로만 켜지는 개발 전용 미리보기 모드(`src/features/devPreview/`)를 갖고 있다.
심사관점에서 숨겨서는 안 되는 사항이므로 별도 절로 명시한다.

| 항목 | 내용 |
|------|------|
| 게이트 조건 | `resolveDevPreviewEnabled({ isDev, viteDevPreviewFlag })`가 `isDev === true && viteDevPreviewFlag === '1'`일 때만 `true`. `isDev`는 Vite의 `import.meta.env.DEV`(빌드타임 상수)를, `viteDevPreviewFlag`는 `.env(.local)`의 `VITE_DEV_PREVIEW`를 그대로 넘긴다. |
| 켜졌을 때 동작 | `useSession()`이 `supabase.auth`를 전혀 호출하지 않고 고정 mock 사용자(`dev-preview-user`)로 즉시 세션을 확정하고, 라우터가 실제 `eventRepository` 대신 인메모리 목 리포지토리(`previewRepository`, 시드 6건)를 `TodayView`/`MonthView`/`WeekView`/`EventForm`(생성)에 주입한다. 화면 상단에 눈에 띄는 배너를 표시한다. |
| production 비활성 보장 수단 1 — 빌드타임 상수 접힘 | `import.meta.env.DEV`는 Vite가 `vite build`(production) 산출물에서 리터럴 `false`로 정적 치환하는 상수다. `&&`의 단락평가로 이 표현식이 `false`로 완전히 접히므로, `VITE_DEV_PREVIEW`에 어떤 값이 실수로 배포 환경에 남아 있어도(예: `.env.production` 오염) production 빌드에서는 게이트가 무조건 `false`다(코드 근거: `src/features/devPreview/devPreview.ts` 상단 주석). |
| production 비활성 보장 수단 2 — 빌드 산출물 마커 스캔 | `devPreview.ts`는 고정 마커 문자열 `PLANFLOW_DEV_PREVIEW_ENABLED`(`PLANFLOW_DEV_PREVIEW_MARKER`)를 export한다. `scripts/scan-bundle.mjs`가 `npm run build` 산출물(`dist/assets/*.js`)에서 이 마커를 찾으면 빌드를 실패시킨다 — 즉 devPreview 관련 코드가 트리쉐이킹되지 않고 번들에 죽은 코드로라도 남으면 빌드 자체가 막힌다. 실측: `npm run build` 후 `npm run secret-scan` exit 0(마커 0건). |
| `.env.example` 안내 | `VITE_DEV_PREVIEW=`(빈 값, 기본 비활성)로만 노출되며, 값 자체가 시크릿이 아니라 커밋에 문제 없다. |

근거 파일경로: `src/features/devPreview/devPreview.ts`, `src/features/devPreview/devPreview.test.ts`,
`scripts/scan-bundle.mjs`, `.env.example`, `src/router.tsx`(리포지토리 주입 지점), `src/features/auth/useSession.ts`.

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
  - **rate limit**: `toss-login` Edge Function 호출 빈도 제한을 아직
    설계하지 않았다.
  - (참고) **로그아웃 UI**는 이번 라운드(D1)에서 구현이 완료돼 이 TODO
    목록에서 제외했다 — 1절 표 참고.
- **반복 일정 지원 범위(C4)**: `EventForm`의 반복 select는 5개 프리셋
  (반복 안 함/매일/매주/매월/매년) + 선택적 종료일(`UNTIL`)만 편집할 수
  있다. 아래는 이번 라운드에서 의도적으로 지원하지 않은 범위이며, 기존
  일정의 `recurrenceRule`이 아래 패턴을 이미 포함하면 `recurrenceEditable`
  이 `false`가 되어 select 자체를 비활성화하고, 저장 시에도 해당 필드를
  patch에서 제외해 기존 값을 덮어쓰지 않는다(근거: `EventForm.tsx`의
  `parseRecurrencePreset`).
  - **BYDAY 다중 선택**(예: 매주 월/수/금) 미지원.
  - **INTERVAL 사용자 지정**(예: 2주마다) 미지원 — `FREQ`만 생성, `INTERVAL`
    키 자체를 만들지 않는다.
  - **COUNT 기반 종료**(예: 10회 반복 후 종료) 미지원 — 종료는 `UNTIL`
    (날짜)만 지원하고, 기존 규칙에 `COUNT`가 있으면 편집 불가로 처리한다
    (`domain/recurrence.ts`의 `expandOccurrences`가 `COUNT`를 파싱하지
    못하므로 UI에서도 COUNT 기반 종료를 표현하지 않음).
  - **예외 회차(단일 회차만 수정/삭제)** 미지원 — 반복 일정 전체에 대한
    편집만 가능하다.
  - **다일(multi-day) 일정 생성 UI** 미지원 — 반복 프리셋과 별개로, 하루를
    넘어가는 단일 이벤트를 만드는 입력 UI가 아직 없다(개발 미리보기 시드
    데이터에는 다일 샘플이 포함돼 있으나 이는 `previewRepository` 시드일
    뿐 실제 생성 폼 기능은 아니다).

[^mtls-501]: `toss-login` Edge Function(`supabase/functions/toss-login/index.ts`)은
    mTLS 클라이언트 인증서 실호출부가 구현되지 않아, 요청이 여기까지
    도달하면 항상 `501 mtls_unsupported`를 반환하고 종료한다(위 "미확정/재확인
    필요" 절의 mTLS 실호출 항목 참고). 즉 이 행이 설명하는 동작은 코드
    구현은 완료됐지만, `linkAndIssueSession()`을 포함한 로그인 흐름 전체가
    실제 토스 계정으로 끝까지 실행된 적은 아직 없다.
[^link-issue-no-test]: `linkAndIssueSession()`은 `toss_identities` 조회/삽입,
    `auth.admin.getUserById`/`createUser`/`generateLink` 등 여러 분기와
    실패 경로를 가진 비자명한 로직이지만, 이 함수를 직접 검증하는
    단위테스트가 없다(`supabase/functions/toss-login/logic.test.ts`는
    `logic.ts`의 순수 함수만 다루고 `index.ts`의 `linkAndIssueSession`은
    다루지 않는다). mTLS 게이트가 항상 501을 반환해 이 함수가 실제
    요청 경로로 호출되는 경우가 아직 없으므로 통합 테스트로도 간접
    검증되지 않는 상태다.
