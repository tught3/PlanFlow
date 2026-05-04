# Naver Login + Supabase Custom Provider 설정

PlanFlow의 네이버 로그인은 Supabase custom OAuth provider를 사용합니다.
네이버 프로필 API는 사용자 정보를 `response.id`, `response.email` 형태로 반환하지만,
Supabase custom provider는 표준 OAuth/OIDC에 가까운 `sub`, `email` 형태를 기대합니다.

그래서 PlanFlow는 `supabase/functions/naver-userinfo-proxy` Edge Function으로 네이버 응답을 아래처럼 변환합니다.

```json
{
  "sub": "naver-response-id",
  "id": "naver-response-id",
  "email": "user@example.com",
  "name": "사용자 이름",
  "nickname": "별명",
  "picture": "프로필 이미지 URL",
  "provider": "naver"
}
```

## 1. Edge Function 배포

Supabase CLI가 로그인되어 있다면 프로젝트 루트에서 실행합니다.

```powershell
supabase functions deploy naver-userinfo-proxy --project-ref xqvvfnvmytjlblcngipn --no-verify-jwt
```

배포 후 Userinfo URL은 아래 주소입니다.

```text
https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/naver-userinfo-proxy
```

이 함수는 Supabase Auth 서버가 넘겨주는 `Authorization: Bearer {naver_access_token}` 헤더만 사용합니다.
네이버 Client Secret을 앱이나 함수에 저장하지 않습니다.

## 2. Supabase Auth Provider 설정

Supabase Dashboard에서 아래로 이동합니다.

```text
Authentication > Providers > Custom Auth Providers > Naver > Update
```

권장값:

```text
Provider Identifier: custom:naver
Display Name: Naver
Configuration Method: Manual configuration
Authorization URL: https://nid.naver.com/oauth2.0/authorize
Token URL: https://nid.naver.com/oauth2.0/token
Userinfo URL: https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/naver-userinfo-proxy
Scopes: email
Allow users without email: OFF
Callback URL: https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback
```

Naver는 일반 OAuth2 방식으로 붙입니다. Supabase 화면에서 `Issuer URL`이 표시되더라도
Auto-discovery/OIDC로 바꾸지 말고 Manual configuration을 유지하세요.
화면상 필수 입력으로 저장이 막힐 때만 `Issuer URL`에 `https://nid.naver.com`을 넣습니다.
`JWKS URI`는 비워둘 수 있으면 비워 둡니다.

`Allow users without email`은 PlanFlow 정책상 끕니다.
네이버가 이메일을 반환하지 않으면 로그인도 완료하지 않습니다.

## 3. Naver Developers 설정

Naver Developers에서 아래로 이동합니다.

```text
Application > PlanFlow > API 설정
```

확인값:

```text
사용 API: 네이버 로그인
제공 정보: 연락처 이메일 주소 필수 또는 추가 제공
Callback URL: https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback
Android 패키지 이름: com.example.planflow
```

권한을 바꾼 뒤에도 이전 동의가 남아 있으면 네이버가 새 동의 화면을 안 보여줄 수 있습니다.
그때는 네이버 계정의 연결된 서비스에서 PlanFlow 동의를 해제한 뒤 다시 로그인합니다.

## 4. 실패 로그 의미

```text
Error getting user email from external provider
```

네이버 이메일을 Supabase가 읽지 못한 상태입니다.
Naver Developers 이메일 제공 항목과 proxy Userinfo URL을 확인합니다.

```text
error missing provider id
```

Supabase가 네이버 `response.id`를 표준 사용자 식별자로 읽지 못한 상태입니다.
Userinfo URL이 `naver-userinfo-proxy`로 되어 있는지 확인합니다.
