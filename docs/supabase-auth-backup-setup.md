# PlanFlow Supabase 인증/백업 설정 체크리스트

앱 코드는 Supabase Auth와 `public.user_backups` 기반 백업/복원을 사용합니다.
아래 항목을 Supabase 대시보드에서 적용해야 실제 로그인과 백업이 동작합니다.

## 1. Schema SQL 적용

1. Supabase 프로젝트로 이동합니다.
2. 왼쪽 메뉴에서 `SQL Editor`를 엽니다.
3. `supabase/schema.sql` 전체 내용을 붙여넣고 실행합니다.
4. `public.users`, `public.events`, `public.user_backups` 등이 생성됐는지 확인합니다.

## 2. Email 로그인 켜기

1. `Authentication` > `Providers`로 이동합니다.
2. `Email` provider를 켭니다.
3. 개발 중에는 필요에 따라 `Confirm email`을 끄면 가입 즉시 로그인됩니다.
4. 운영 배포 전에는 이메일 인증을 켜는 것을 권장합니다.

## 3. Redirect URL 등록

`Authentication` > `URL Configuration`에서 Redirect URL에 아래 값을 추가합니다.

```text
planflow://auth-callback
```

비밀번호 재설정과 소셜 로그인 모두 이 딥링크로 앱에 돌아옵니다.

## 4. 소셜 로그인 Provider 설정

### Google

1. Google Cloud Console에서 OAuth Client를 만듭니다.
2. Supabase `Authentication` > `Providers` > `Google`에 Client ID/Secret을 넣습니다.
3. Google OAuth 승인된 redirect URI에는 Supabase callback URL을 등록합니다.

### Kakao

1. Kakao Developers에서 앱을 등록합니다.
2. 카카오 로그인 활성화 후 REST API 키와 Secret을 확인합니다.
3. Supabase `Authentication` > `Providers` > `Kakao`에 값을 넣습니다.

### Naver

Supabase 대시보드에 Naver가 기본 provider로 보이지 않으면 커스텀 OAuth/OIDC 설정이 필요합니다.
앱 코드는 Supabase custom provider ID `naver`를 기준으로 `custom:naver`를 호출하도록 준비되어 있습니다.

## 5. 앱 런타임 설정값

앱은 더 이상 런타임에서 `.env`를 읽지 않습니다. 로컬 실행과 빌드에서는
`--dart-define` 또는 `--dart-define-from-file=env/local.json`으로 클라이언트 설정값을 전달합니다.

```json
{
  "SUPABASE_URL": "https://your-project.supabase.co",
  "SUPABASE_ANON_KEY": "your-supabase-anon-key",
  "GOOGLE_WEB_CLIENT_ID": "your-web-oauth-client-id.apps.googleusercontent.com"
}
```

실행 예시는 아래와 같습니다.

```powershell
flutter run --dart-define-from-file=env/local.json
```

`SUPABASE_URL`과 `SUPABASE_ANON_KEY`는 클라이언트 공개 설정값입니다. 이 값이 앱에 포함되는 것은
정상이며, 사용자 데이터 보호는 `supabase/schema.sql`의 RLS 정책으로 강제해야 합니다.

`service_role`, OpenAI API key, OAuth client secret 같은 서버 전용 비밀값은 앱에 넣지 않습니다.
OpenAI 일정 파싱처럼 비밀키가 필요한 기능은 Supabase Edge Function 같은 서버 경유 방식으로 호출해야 합니다.

Google Calendar 연결을 Android에서 사용하려면 Google Cloud Console에서 만든 **Web OAuth Client ID**를
`GOOGLE_WEB_CLIENT_ID` 또는 `GOOGLE_SERVER_CLIENT_ID`로 설정해야 합니다. Android 앱에
`google-services.json`을 넣지 않는 구성에서는 `google_sign_in_android` 기준으로 Android Client ID가
아니라 Web OAuth Client ID가 `serverClientId`로 전달되어야 합니다.

## 6. PRO 얼리버드 이메일

현재 앱의 PRO 얼리버드 신청은 `public.submit_early_bird_email` RPC를 통해 `planflow.early_bird_emails`에 이메일을 저장하는 대기자 명단 기능입니다.
이 단계에서는 사용자에게 자동 이메일이 발송되지 않습니다.

자동 안내 메일을 보내려면 추가로 아래 중 하나를 연결해야 합니다.

1. Supabase Edge Function + Resend/SendGrid 같은 이메일 발송 서비스
2. Zapier/Make 자동화로 `planflow.early_bird_emails` 신규 row 감지 후 메일 발송
3. 운영자가 Supabase Table에서 이메일 목록을 내려받아 수동 발송
