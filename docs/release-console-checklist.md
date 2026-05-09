# PlanFlow 1차 배포 콘솔 설정 체크리스트

이 문서는 Play Console 내부 테스트 전 외부 콘솔에서 직접 확인해야 하는 값만 모아둔 체크리스트입니다.

## 공통 값

- Android package: `com.planflow.app`
- Release SHA-1: `5A:94:6B:45:25:44:8B:89:B9:C0:13:69:E9:21:59:A4:B3:70:16:A7`
- Release SHA-256: `75:AB:45:C8:84:19:D9:72:F4:6F:34:1F:B2:97:60:CE:7C:14:FC:0B:A9:1D:BA:11:93:6C:02:DF:00:75:36:1E`
- Kakao release key hash: `WpRrRSVEi4m5wBNp6SFZpLNwFqc=`
- Supabase callback URL: `https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback`
- App auth deep link: `planflow://auth-callback`
- Play Console privacy policy URL: `https://tught3.github.io/PlanFlow/privacy-policy.html`

## OpenAI

1. OpenAI Platform에 로그인합니다.
2. Organization/Project settings로 이동합니다.
3. Billing 또는 Limits에서 monthly budget/usage limit을 설정합니다.
4. 내부 테스트 기준 기본값은 `$10`에서 `$20`입니다.

## Google Cloud Console

1. Google Cloud Console에서 PlanFlow 프로젝트를 선택합니다.
2. APIs & Services > Enabled APIs & services에서 아래 API가 켜져 있는지 확인합니다.
3. Google Calendar API, Maps SDK for Android, Directions API, Distance Matrix API, Geocoding API.
4. APIs & Services > Credentials로 이동합니다.
5. Android OAuth client를 만들거나 수정합니다.
6. Package name에는 `com.planflow.app`을 입력합니다.
7. SHA-1에는 위 release SHA-1 값을 입력합니다.
8. Web OAuth client의 Authorized redirect URIs에 Supabase callback URL을 등록합니다.
9. Google Maps API key 제한은 Android apps로 설정하고 `com.planflow.app` + release SHA-1을 추가합니다.

## Naver Developers / Naver Cloud

1. Naver Developers에서 PlanFlow 애플리케이션을 선택합니다.
2. Login callback URL에 Supabase callback URL을 등록합니다.
3. Android package 입력란이 있으면 `com.planflow.app`을 등록합니다.
4. Naver Cloud Platform Console > Maps에서 PlanFlow Maps 애플리케이션을 선택합니다.
5. Android service environment/package 제한에 `com.planflow.app`을 등록합니다.
6. 앱의 `NAVER_MAP_CLIENT_ID` / `NAVER_MAP_CLIENT_SECRET`이 해당 Maps 애플리케이션 값과 일치하는지 확인합니다.

## Kakao Developers

1. Kakao Developers에서 PlanFlow 애플리케이션을 선택합니다.
2. 앱 설정 > 플랫폼 > Android 플랫폼을 추가하거나 수정합니다.
3. Package name에 `com.planflow.app`을 입력합니다.
4. Key hash에 `WpRrRSVEi4m5wBNp6SFZpLNwFqc=`를 입력합니다.
5. 카카오 로그인 redirect URI가 필요하면 Supabase callback URL을 등록합니다.

## Google Play Console

1. Play Console에서 PlanFlow 앱을 생성합니다.
2. App content > Privacy policy에 `https://tught3.github.io/PlanFlow/privacy-policy.html`을 입력합니다.
3. Internal testing 트랙에 `build/app/outputs/bundle/release/app-release.aab`를 업로드합니다.
4. Data safety에는 이메일, 위치, 캘린더 이벤트 수집을 앱 기능 목적으로 표시합니다.
5. 오디오 파일은 수집하지 않음으로 표시합니다.
6. 스토어 설명, 데이터 보안, 릴리즈 노트는 `docs/play-console-submission.md` 초안을 기준으로 입력합니다.
