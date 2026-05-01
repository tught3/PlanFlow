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

## 5. 앱 환경값

`.env`에 최소 아래 값을 넣어야 합니다.

```text
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-supabase-anon-key
OPENAI_API_KEY=your-openai-api-key
```

`OPENAI_API_KEY`가 없어도 로그인과 일정 저장은 가능하지만, GPT 일정 파싱은 동작하지 않습니다.
