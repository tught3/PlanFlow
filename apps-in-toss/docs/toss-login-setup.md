# 토스 로그인(TossAuth) 서버 설정 가이드

이 문서는 `.env.example`에서 안내만 하고 값을 적지 않은 서버 전용 시크릿을
어디서 발급받고 어떻게 설정하는지 정리한다. **이 문서에도 실제 시크릿 값은
한 글자도 적지 않는다** — 발급 절차와 설정 명령 형식만 남긴다.

## 1. 콘솔에서 확인 필요 (확정/추정 구분)

아래 항목은 이 저장소 코드만으로는 확정할 수 없고, 토스 개발자 콘솔 /
Supabase 대시보드에서 직접 확인해야 한다.

| 항목 | 상태 | 비고 |
|------|------|------|
| mTLS 인증서 발급 절차 | **미확인** | 토스 오픈API(TossAuth) 서버-to-서버 호출에 mTLS가 요구되는지, 요구된다면 인증서/개인키를 어느 콘솔 메뉴에서 발급받는지 확인 필요. `src/features/auth/tossLogin.ts`에는 `mtls_unsupported` 에러 코드가 이미 정의돼 있어 mTLS 미지원 환경을 구분하고 있으나, 실제 발급 절차는 이 저장소에 문서화된 적이 없다. |
| clientId 발급 여부·용도 | **미확인** | 토스 오픈API 연동에 별도 clientId/clientSecret 발급이 필요한지, 필요하다면 Edge Function secret으로 넣을지 아니면 다른 방식으로 관리할지 확인 필요. |
| `TOSS_API_BASE_URL_DEFAULT` / `TOSS_API_BASE_URL_SANDBOX` 실제 호스트 | **미확인** | `runTossLogin()`이 `referrer: 'DEFAULT' | 'SANDBOX'`를 Edge Function에 그대로 전달하는 구조로 봐서 서버 쪽에 운영/샌드박스 두 개의 base URL이 필요할 것으로 추정되나, 실제 호스트 값은 토스 콘솔에서 발급받아야 확인 가능하다. |
| PII 복호화 키 수령 경로 | 콘솔 설정 후 이메일로 수신 예정(**미확인, 절차 미확정**) | 토스 사용자 식별 정보(PII)를 복호화하는 키를 콘솔 설정 완료 후 이메일로 받는다고 안내받았으나, 정확한 발급 트리거·형식·회전 주기는 아직 확인되지 않았다. |
| Supabase email auth provider 활성 여부 | **미확인, 콘솔에서 확인 필요** | `toss-login` Edge Function이 `token_hash`를 발급하고 클라이언트가 `supabase.auth.verifyOtp({ type: 'email' })`로 세션을 발급받는 흐름이므로, Supabase 프로젝트의 Authentication > Providers에서 Email(매직링크/OTP) provider가 켜져 있어야 한다. 현재 프로젝트에서 이 설정이 켜져 있는지는 대시보드에서 직접 확인해야 한다. |

## 2. Edge Function secret 설정

서버 전용 값은 클라이언트 `.env`가 아니라 Supabase Edge Function secret으로
등록한다. 값은 실제 발급받은 뒤 로컬 셸에서만 채워 넣고, 이 문서나
`.env.example`에는 옮겨 적지 않는다.

```bash
# 예시 - 키 이름 형식만, 실제 값은 발급받은 뒤 로컬에서 직접 입력
supabase secrets set TOSS_API_BASE_URL_DEFAULT=...
supabase secrets set TOSS_API_BASE_URL_SANDBOX=...
supabase secrets set TOSS_MTLS_CLIENT_CERT=...
supabase secrets set TOSS_MTLS_CLIENT_KEY=...
supabase secrets set TOSS_CLIENT_ID=...
supabase secrets set TOSS_CLIENT_SECRET=...
supabase secrets set TOSS_PII_DECRYPT_KEY=...
```

`TOSS_API_BASE_URL_DEFAULT` / `TOSS_API_BASE_URL_SANDBOX` /
`TOSS_MTLS_CLIENT_CERT` / `TOSS_MTLS_CLIENT_KEY`는 실제
`supabase/functions/toss-login/index.ts`가 `Deno.env.get(...)`으로
읽는 키 이름과 일치한다(이 4개가 모두 설정돼야 501 `mtls_unsupported`
가드를 통과해 아래 TODO 실호출부까지 도달할 수 있다). 반면
`TOSS_CLIENT_ID` / `TOSS_CLIENT_SECRET` / `TOSS_PII_DECRYPT_KEY`는
현재 `index.ts`가 읽지 않는다 — mTLS 실호출부(TODO)를 구현할 때
필요할 것으로 추정되는 값을 미리 나열해 둔 것뿐이며, 실제 필요 여부와
키 이름은 그 구현 시점에 다시 확정해야 한다.

## 3. 이번 라운드에 구현하지 않은 것

아래 항목은 이번 작업 범위에서 의도적으로 제외했다. 이유를 함께 남긴다.

- **mTLS 실호출**: 토스 오픈API가 실제로 mTLS를 요구하는지, 요구한다면
  Deno Edge Function 런타임에서 클라이언트 인증서를 어떻게 붙이는지가
  미확인 상태라 실제 네트워크 호출 코드를 작성하지 않았다.
- **PII 복호화**: 복호화 키 수령 경로 자체가 미확정이라 복호화 로직을
  구현하면 잘못된 키 포맷을 가정한 죽은 코드가 될 위험이 있다. 키를
  실제로 손에 넣은 뒤 별도 라운드에서 구현한다.
- **rate limit**: `toss-login` Edge Function 호출 빈도 제한(rate limit)은
  아직 설계하지 않았다. 로그인 실패 재시도, 봇 방지 등 정책이 먼저
  정해져야 하는 사업적 판단 영역이라 이번 범위에서 제외했다.

## 4. magiclink 세션 발급과 "자체 로그인 UI 금지" 규정의 관계

`runTossLogin()`은 `supabase.auth.verifyOtp({ token_hash, type: 'email' })`로
세션을 발급받는다. 이것이 이메일 기반 매직링크/OTP 메커니즘을 쓰는 것은
맞지만, 아래 이유로 "자체 로그인 UI 금지" 규정과 충돌하지 않는다.

- 사용자에게 이메일 주소를 입력받는 UI가 화면 어디에도 없다. 사용자가
  누르는 유일한 버튼은 토스 로그인(`TossAuth.login()`)이다.
- `token_hash`는 사용자가 아니라 `toss-login` Edge Function이 토스 인증
  결과를 검증한 뒤 서버 쪽에서 발급한다. 클라이언트는 그 값을 받아
  즉시 `verifyOtp`에 넘겨 소비할 뿐, 사람이 읽거나 입력하는 흐름이
  아니다.
- 즉 email/매직링크는 사용자에게 노출되는 로그인 수단이 아니라, 토스
  로그인 성공 이후 Supabase 세션을 발급받기 위해 서버-클라이언트 간에만
  오가는 내부 구현 수단이다. 사용자 관점에서 로그인 경로는 여전히
  "토스 로그인" 하나뿐이다.

## 5. 연결 끊기 콜백(Disconnect Callback) 설정

`toss-disconnect-callback` Edge Function은 사용자가 토스 앱 쪽에서 서비스
연결을 끊거나 회원탈퇴할 때, 토스 서버가 서버-to-서버로 호출하는
콜백을 받아 처리한다. 로그인 흐름(위 1~4절)과 별개의 인증 경계를
가지므로 아래 설정을 빠짐없이 따른다.

### 5.1 필요한 Edge Function secret

```bash
# 예시 - 키 이름 형식만, 실제 값은 발급받은 뒤 로컬에서 직접 입력
supabase secrets set TOSS_DISCONNECT_CALLBACK_BASIC_AUTH=...
```

이 문서에도 실제 시크릿 값은 한 글자도 적지 않는다 — 위 명령의 `...`
자리에 실제 값을 채워 넣는 것은 로컬 셸에서 직접 한다.

### 5.2 토스 콘솔 "Basic Auth 헤더" 값 — 평문(plaintext)으로 입력

Apps-in-Toss 콘솔의 연결 끊기 콜백 설정 화면에는 "Basic Auth 헤더"를
입력하는 필드가 있다. **이 필드에는 `TOSS_DISCONNECT_CALLBACK_BASIC_AUTH`에
설정한 값과 동일한 평문(plaintext) 자격증명을 그대로 입력한다** —
`Basic <base64>` 형태로 미리 인코딩해서 넣는 것이 아니다. 토스 서버가
실제 콜백을 보낼 때 이 평문 값을 자체적으로 base64 인코딩해
`Authorization: Basic <base64>` 헤더로 담아 보내고, 우리 서버는 수신한
헤더를 디코딩한 뒤 `TOSS_DISCONNECT_CALLBACK_BASIC_AUTH` 평문과 비교한다.
콘솔 필드에 이미 인코딩된 값을 넣으면 이중 인코딩이 되어 모든 콜백이
인증 실패로 거부되므로, 이 부분은 특히 헷갈리기 쉬운 지점이라 명시해
둔다.

### 5.3 콘솔 HTTP 메서드 설정 — POST 권장 (GET 금지)

콜백 요청 방식을 콘솔에서 GET/POST 중 선택할 수 있다면 **POST를
사용한다.** GET을 쓰면 사용자 식별자(`userKey`)가 URL 쿼리 문자열에
노출되어 게이트웨이/프록시의 접근 로그(access log)에 평문으로 남을 수
있다. POST 바디로 전달하면 이 문제를 피할 수 있으며, 이는 이 저장소가
이미 지키고 있는 PII 로깅 규율(`supabase/functions/toss-login/index.ts`
헤더 주석 — hashed_token/service_role 키 등 민감 값을 어떤 로그 경로에도
남기지 않는다는 원칙)과 같은 맥락이다.

### 5.4 배포 시 필수 — `--no-verify-jwt` (중요, 반드시 지킬 것)

**이 함수는 반드시 아래 명령으로 배포해야 한다:**

```bash
supabase functions deploy toss-disconnect-callback --no-verify-jwt
```

Supabase Edge Function 게이트웨이는 기본적으로 모든 함수 호출에 대해
JWT 검증을 강제한다. 그런데 토스가 보내는 연결 끊기 콜백 요청에는
Supabase JWT도, `apikey` 헤더도 실려 있지 않다 — 인증 수단은 오직
위 5.2절의 Basic Auth 헤더 하나뿐이다. `--no-verify-jwt` 없이 배포하면
게이트웨이가 우리 함수 코드가 실행되기도 전에 모든 콜백 요청을 401로
거부한다. 즉 **이 배포 옵션이 빠지면 이 엔드포인트는 토스로부터 영원히
호출될 수 없다.**

이 옵션을 켜는 순간부터는 게이트웨이 레벨의 JWT 검증이 사라지므로,
**Basic Auth 헤더 검증이 이 엔드포인트의 유일한 인증 경계(sole
authentication boundary)가 된다.** 함수 코드 내부의 Basic Auth 비교
로직을 수정할 때는 이 사실을 항상 염두에 둔다.

### 5.5 콜백 URL 형식

콘솔에 등록할 콜백 URL 형식은 다음과 같다:

```
https://<project-ref>.supabase.co/functions/v1/toss-disconnect-callback
```

`<project-ref>`는 실제 Supabase 프로젝트 참조 값으로 교체해 콘솔에
입력하되, 이 문서에는 위 형식 그대로 자리표시자(placeholder)만 남긴다.

### 5.6 응답 코드·재시도 정책·타임아웃 — 미확인 (추정 구현)

토스 공식 문서(2026-08 기준 조사)에는 연결 끊기 콜백에 대해 우리
서버가 반환해야 할 기대 응답 상태 코드, 토스 측 재시도 정책, 요청
타임아웃이 명시되어 있지 않다 — **미확인**이다. 현재 구현은 아래를
자체 안전 설계로 채택했으며, 이는 토스 스펙이 확정한 요구사항이 아니라
우리 쪽의 추정 컨벤션임을 명확히 한다:

- 정상 처리된 모든 케이스(알 수 없는 사용자, 알 수 없는 referrer 값 등
  no-op으로 처리되는 경우 포함)에 `200`을 반환한다.
- 인증 실패(Basic Auth 불일치)에 `401`을 반환한다.
- 요청 형식이 잘못된 경우 `400`을 반환한다.
- 서버 설정 누락·DB 오류 등 서버 측 문제에는 `500`을 반환한다.
- 처리 로직은 멱등(idempotent)하게 설계되어 있어, **만약** 토스가
  재시도를 보내더라도 중복 처리로 인한 부작용이 발생하지 않는다.

위 응답 코드 체계와 멱등성은 토스 스펙이 요구해서가 아니라, 스펙이
미확인인 상태에서 우리가 선택한 방어적 설계라는 점을 기억한다 —
추후 토스 쪽에서 명시적인 기대 응답 스펙을 공지하면 이 절을 갱신한다.
