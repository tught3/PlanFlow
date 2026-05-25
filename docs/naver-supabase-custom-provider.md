# Naver Login + Supabase Custom Provider 설정

PlanFlow는 Supabase custom OAuth provider로 네이버 로그인을 연결합니다.
네이버 프로필 API는 사용자 정보를 `response.id`, `response.email`처럼 중첩해서 반환하므로,
Supabase가 기대하는 `sub`, `email` 형태로 바꾸기 위해 Edge Function 프록시를 사용합니다.

## 1. Edge Function 배포

Supabase CLI 로그인이 되어 있다면 프로젝트 루트에서 실행합니다.

```powershell
supabase functions deploy naver-userinfo-proxy --project-ref xqvvfnvmytjlblcngipn --no-verify-jwt
```

배포 후 Supabase custom provider의 Userinfo URL은 아래 값을 사용합니다.

```text
https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/naver-userinfo-proxy
```

## 2. Supabase Auth Provider 설정

Supabase Dashboard에서 아래로 이동합니다.

```text
Authentication > Sign In / Providers > Custom Auth Providers > Naver
```

권장값:

```text
Provider Identifier: custom:naver
Display Name: Naver
Configuration Method: Manual configuration
Issuer URL: https://nid.naver.com
Authorization URL: https://nid.naver.com/oauth2.0/authorize
Token URL: https://nid.naver.com/oauth2.0/token
Userinfo URL: https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/naver-userinfo-proxy
Scopes: email
Allow users without email: OFF
Callback URL: https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback
```

`Allow manual linking`도 켜야 이메일/구글/카카오로 로그인한 사용자가 같은 PlanFlow 계정에 네이버 캘린더 권한을 추가 연결할 수 있습니다.

```text
Authentication > Sign In / Providers > User Signups > Allow manual linking: ON
```

## 3. Naver Developers 설정

Naver Developers에서 아래 항목을 확인합니다.

```text
Application > PlanFlow > API 설정
```

필수 확인:

```text
사용 API: 네이버 로그인
제공 정보: 연락처 이메일 주소
추가 권한: 캘린더 일정담기
Callback URL: https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback
Android 패키지 이름: com.fluxstudio.planflow
```

## 4. PlanFlow 네이버 캘린더 동기화 범위

네이버 공개 Calendar API는 `createSchedule.json` 중심입니다.
따라서 PlanFlow 1차 구현은 “PlanFlow 일정을 네이버 캘린더에 담기”입니다.
Google Calendar처럼 외부 네이버 캘린더 일정을 전체 조회해서 가져오는 기능은 공개 API 범위가 제한적이므로 별도 백엔드/제휴 API가 필요합니다.

## 5. 자주 보는 오류

```text
manual_linking_disabled
```

Supabase의 `Allow manual linking`이 꺼져 있습니다.

```text
Error getting user email from external provider
```

Naver Developers에서 이메일 제공이 꺼져 있거나, Userinfo URL이 프록시로 설정되지 않았습니다.

```text
missing provider id
```

Supabase가 네이버의 `response.id`를 사용자 식별자로 읽지 못한 상태입니다.
Userinfo URL이 `naver-userinfo-proxy`인지 확인하세요.
