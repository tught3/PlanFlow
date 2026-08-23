# PlanFlow 1차 배포 콘솔 설정 체크리스트

이 문서는 Play Console 내부 테스트 전 외부 콘솔에서 직접 확인해야 하는 값만 모아둔 체크리스트입니다.

## 공통 값

- Android package: `com.fluxstudio.planflow`
- Debug SHA-1: `D8:A5:47:45:F2:B3:FF:2E:A1:42:B5:07:2A:12:C7:F4:2F:32:5D:06`
- Debug SHA-256: `CB:AB:1A:9F:8D:62:AA:12:2A:61:70:97:EE:94:24:78:39:57:BB:43:67:EA:30:9A:B1:EF:CC:E6:96:7D:2F:9A`
- Release SHA-1: `5A:94:6B:45:25:44:8B:89:B9:C0:13:69:E9:21:59:A4:B3:70:16:A7`
- Release SHA-256: `75:AB:45:C8:84:19:D9:72:F4:6F:34:1F:B2:97:60:CE:7C:14:FC:0B:A9:1D:BA:11:93:6C:02:DF:00:75:36:1E`
- Kakao release key hash: `WpRrRSVEi4m5wBNp6SFZpLNwFqc=`
- Supabase callback URL: `https://xqvvfnvmytjlblcngipn.supabase.co/auth/v1/callback`
- App auth deep link: `planflow://auth-callback`
- Play Console privacy policy URL: `https://fluxstudio.co.kr/privacy`

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
6. Package name에는 `com.fluxstudio.planflow`을 입력합니다.
7. SHA-1에는 내부 테스트/릴리스용 Android OAuth client에는 위 release SHA-1 값을 입력하고, 로컬 debug APK 테스트용 Android OAuth client에는 위 debug SHA-1 값을 입력합니다.
8. Web OAuth client의 Authorized redirect URIs에 Supabase callback URL을 등록합니다.
9. Web OAuth client ID는 `GOOGLE_WEB_CLIENT_ID` 또는 `GOOGLE_SERVER_CLIENT_ID`로 앱에 전달합니다.
10. `android/app/google-services.json`의 `oauth_client`가 비어 있거나 현재 APK 서명 SHA-1이 Android OAuth client에 없으면 Google Sign-In에서 `ApiException: 10`이 날 수 있습니다.
11. Google Maps API key 제한은 Android apps로 설정하고 `com.fluxstudio.planflow` + release SHA-1을 추가합니다.

## Naver Developers / Naver Cloud

1. Naver Developers에서 PlanFlow 애플리케이션을 선택합니다.
2. Login callback URL에 Supabase callback URL을 등록합니다.
3. Android package 입력란이 있으면 `com.fluxstudio.planflow`을 등록합니다.
4. Naver Cloud Platform Console > Maps에서 PlanFlow Maps 애플리케이션을 선택합니다.
5. Android service environment/package 제한에 `com.fluxstudio.planflow`을 등록합니다.
6. 앱에는 `NAVER_MAP_CLIENT_SECRET`을 넣지 않습니다. Naver geocode는 Supabase Edge Function proxy에 secret을 보관하고, 앱에는 `NAVER_MAP_CLIENT_ID`와 `NAVER_MAP_PROXY_URL`만 전달합니다.

## Kakao Developers

1. Kakao Developers에서 PlanFlow 애플리케이션을 선택합니다.
2. 앱 설정 > 플랫폼 > Android 플랫폼을 추가하거나 수정합니다.
3. Package name에 `com.fluxstudio.planflow`을 입력합니다.
4. Key hash에 `WpRrRSVEi4m5wBNp6SFZpLNwFqc=`를 입력합니다.
5. 카카오 로그인 redirect URI가 필요하면 Supabase callback URL을 등록합니다.

## Google Play Console

1. Play Console에서 PlanFlow 앱을 생성합니다.
2. App content > Privacy policy에 `https://fluxstudio.co.kr/privacy`을 입력합니다.
3. Internal testing 트랙에 `build/app/outputs/bundle/release/app-release.aab`를 업로드합니다.
4. Data safety에는 이메일, 위치, 캘린더 이벤트 수집을 앱 기능 목적으로 표시합니다.
5. 오디오 파일은 수집하지 않음으로 표시합니다.
6. 스토어 설명, 데이터 보안, 릴리즈 노트는 `docs/play-console-submission.md` 초안을 기준으로 입력합니다.

## 프로덕션 출시 자동화

프로덕션 자동화는 내부 테스트 스크립트와 별도 진입점을 사용합니다. 기본 실행은
사전검증만 수행하고 업로드하지 않습니다. 프로덕션 설정 파일에는 서비스 계정 경로를
직접 입력해야 하며 저장소에 커밋하지 않습니다.

```powershell
Copy-Item config\play-production.example.json config\play-production.json
# config\play-production.json의 enabled=true와 로컬 서비스 계정 경로를 확인
.\scripts\deploy-play-production.ps1
```

후보 AAB만 만들 때는 `-BuildDraft`, 실제 공개 트랙 업로드는 Play Console 검토 후
명시적으로 `-ConfirmProductionRollout`을 추가합니다.

```powershell
.\scripts\deploy-play-production.ps1 -BuildDraft
.\scripts\deploy-play-production.ps1 -ConfirmProductionRollout
```

이 경로는 `scripts/build-internal-aab.ps1`의 지도용 define 사전검증과 map artifact
marker를 그대로 사용합니다. 일반 `flutter build appbundle` 명령으로 프로덕션 AAB를
만들지 않습니다. 트랙은 반드시 `production`이어야 하며, 예제 설정 파일·비활성 설정·없는
서비스 계정·지도 marker가 있는 AAB가 아니면 업로드를 중단합니다. 실제 Play Console의
국가, 심사, 스토어 등록 상태는 이 저장소에서 추정하지 않고 콘솔에서 확인합니다.
