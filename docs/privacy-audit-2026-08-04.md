# PlanFlow 개인정보 처리 현황 감사 보고서

- **작성일**: 2026-08-04
- **프로젝트**: PlanFlow v2 (Flutter Android-first)
- **목적**: Play Console Data Safety 섹션 수정, 개인정보처리방침 업데이트, AAB 권한/SDK 검증 근거 확보
- **범위**: 1차 출시 대상 기능 한정 (billing/ads/Kakao·SMS·call 감지 제외)

---

## 1. 데이터 수집·처리 현황

### 1.1 음성 입력 (STT)
- **구현**: `speech_to_text` 패키지, `SpeechListenOptions(onDevice: true)` 강제
- **서버 전송**: **없음**. 음성 파형은 기기 내 Android 시스템 STT 엔진에서 텍스트로 변환되며, 변환된 텍스트만 앱으로 전달됨
- **저장**: 변환된 텍스트는 `voice_logs.raw_text` 컬럼에 저장 (Supabase)
- **보관 기간**: 무제한 (사용자가 회원탈퇴하면 일괄 삭제)
- **권장**: 보관 기간 명시화 (예: 90일 후 자동 삭제 옵션) — Play 정책상 강제 아님, 사용자 신뢰 차원

### 1.2 voice_logs 테이블
- **저장 데이터**: `raw_text` (STT 결과 텍스트), `parsed_json` (GPT 파싱 결과), `event_id` (연결된 일정 FK), `location` (사용자 발화에 포함된 위치 텍스트 — 좌표 아님), `created_at`
- **위치 데이터 성격**: 자유 텍스트 ("강남역", "회사" 등). GPS 좌표 아님
- **민감 정보 가능성**: 일상 발화에 개인 이름, 일정, 위치가 포함될 수 있음
- **접근 권한**: RLS로 본인만 조회/삭제 가능
- **권장**: 사용자 설정에 "음성 로그 보관 기간" 옵션 추가 (30일/90일/영구)

### 1.3 GPT 파싱 (openai-proxy Edge Function)
- **구현**: `supabase/functions/openai-proxy/index.ts`
- **전송 데이터**: STT 텍스트만 전송 (음성 파형 X)
- **로깅**: **없음**. proxy는 요청/응답을 디스크에 저장하지 않음. OpenAI 측 로깅 정책은 별도
- **API 키 저장**: Supabase Edge Function secret (클라이언트 노출 X)
- **재검증**: `_shared/auth.ts`의 `verifyUser()`로 로그인 사용자만 호출 가능 (anon key 차단)

### 1.4 위치 정보
- **storage 형태**:
  - `voice_logs.location`: 텍스트 (사용자 발화에서 추출)
  - `events.location`: 텍스트
  - `events.location_lat` / `events.location_lng`: GPS 좌표 (사용자가 명시적으로 위치를 선택했을 때만)
  - `location_history.location`: 텍스트 (방문 기록)
- **백그라운드 위치 수집**: 없음. 사용자가 명시적으로 일정을 생성할 때만 위치 입력
- **지도 SDK**: flutter_naver_map (표시 전용)
- **이동 시간 API**: Google Maps Distance Matrix API (출발/도착 좌표만 전송)

### 1.5 Firebase Crashlytics
- **수집 데이터**: 크래시 스택트레이스, 기기 모델, OS 버전, 앱 버전
- **PII 수집**: **설정 안 함**. 사용자 ID, 이메일, 이름은 자동 수집하지 않음
- **옵트아웃**: 앱 내 제공 안 함 (Crashlytics는 익명 크래시 보고가 기본 정책상 허용됨)
- **네트워크 에러 필터**: `runtime_error_filter.dart`로 오프라인/타임아웃 에러는 전송에서 제외

### 1.6 Firebase Analytics
- **상태**: **비활성** (활성화 안 됨)
- **활성화 여부 확인**: `firebase_options.dart`, `AndroidManifest.xml`에 ANALYTICS 선언 없음
- **권장**: 향후 활성화 시 Data Safety 섹션에 "사용 통계" 데이터 유형 추가 필요

### 1.7 광고 ID (AD_ID)
- **과거 상태**: 2026-07-15 AD_ID 권한 제거됨 (1차 출시 범위에서 광고 제외 결정)
- **현재 상태**: `AndroidManifest.xml`에 `<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>` 선언 **없음**
- **복원 예정**: 2차 출시(리워드 광고 도입 시)에 복원 — 그 시점에 Data Safety 섹션에 광고 ID 데이터 유형 선언 필수
- **재확인 필요**: AAB 빌드 후 `aapt dump permissions`로 실제 권한 목록 검증

### 1.8 AdMob (google_mobile_ads)
- **현재 상태**: 1차 출시에는 광고 미포함이나, `ad_service.dart`, `AdService.instance.initialize()` 코드는 존재 (Remote Config로 활성화 제어)
- **테스트 ID**: 실제 광고 unit ID가 아닌 Google 제공 테스트 ID 사용 (코드상 하드코딩)
- **정책 영향**: AdMob SDK가 AAB에 포함되어 있으면 Data Safety 섹션에 광고 관련 데이터 수집 선언 필수 (앱이 광고를 실제로 띄우지 않아도 SDK 포함 = 선언 대상)
- **권장**: 1차 출시 AAB에서 AdMob SDK 완전 제거 검토 (pubspec에서 google_mobile_ads 임시 제거) 또는 Data Safety에 "광고" 데이터 유형 선언 추가

---

## 2. Play Console Data Safety 섹션 수정 항목

### 2.1 수정 필요 (1차 출시 기준)
| 데이터 유형 | 수정 내용 | 사유 |
|------------|----------|------|
| 개인 정보 (Personal info) | **Email address** 추가 (선택적, 계정 생성 시) | 이메일 회원가입 지원 |
| 개인 정보 | **User IDs** 추가 (선택적) | Supabase Auth user_id |
| 위치 (Location) | **Approximate location** 추가 (선택적) | events.location_lat/lng 사용 |
| 음성 녹음 (Audio) | **추가 안 함** | STT는 온디바이스, 서버 전송 없음 |
| 사진/동영상 | **추가 안 함** | 해당 기능 없음 |
| 파일/문서 | **추가 안 함** | 해당 기능 없음 |
| 앱 활동 (App activity) | **Search history** (선택적) | 일정 검색 기능 |
| 앱 정보/성능 | **Crash logs** (선택적) | Crashlytics |
| 앱 정보/성능 | **Diagnostics** (선택적) | Crashlytics 부가 데이터 |
| 광고 ID (Advertising ID) | **1차 출시: 없음** / **2차 출시: 추가 예정** | AdMob SDK 포함 여부에 따라 |

### 2.2 데이터 암호화 (Encryption)
- **전송 중 암호화**: HTTPS/TLS (Supabase REST, OpenAI API, Google Maps API 모두 HTTPS 강제)
- **저장 암호화**: Supabase 서버 측 암호화 (PostgreSQL at-rest encryption)
- **Data Safety 선언**: "데이터가 전송 중일 때 암호화됨" = **예**

### 2.3 데이터 삭제 (Data deletion)
- **구현 상태**: 회원 탈퇴 기능 구현 완료 (2026-08-04, `delete-account` Edge Function)
- **삭제 범위**: events, pre_actions, reminders, voice_logs, location_history, user_settings, user_backups, feedback_reports, group_members, group_backups, group_event_comments, group_role_delegations, group_invites, planflow.early_bird_emails, auth.users
- **예외**: 그룹 리더로 있는 active 그룹이 있으면 차단 (사용자가 먼저 위임/삭제하도록 안내)
- **Data Safety 선언**: "사용자가 데이터 삭제를 요청할 수 있음" = **예**

---

## 3. AAB 권한·SDK 검증 명령

### 3.1 권한 검증 (release AAB 대상)
```powershell
# 1. AAB를 APKS로 변환 (bundletool 필요)
java -jar bundletool.jar build-apks `
  --bundle="build\app\outputs\bundle\release\app-release.aab" `
  --output="build\app\outputs\bundle\release\planflow.apks" `
  --mode=universal

# 2. APKS에서 universal APK 추출
java -jar bundletool.jar extract-apks `
  --apks="build\app\outputs\bundle\release\planflow.apks" `
  --output-dir="build\app\outputs\bundle\release\universal_apk" `
  --device-spec=json-device-spec.json

# 3. 권한 목록 덤프 (aapt)
& "$env:ANDROID_HOME\build-tools\34.0.0\aapt.exe" dump permissions `
  "build\app\outputs\bundle\release\universal_apk\universal.apk"
```

### 3.2 예상 권한 목록 (1차 출시 기준)
- `INTERNET` (Supabase, OpenAI, Google Maps)
- `RECORD_AUDIO` (STT)
- `POST_NOTIFICATIONS` (Android 13+)
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` (알람)
- `RECEIVE_BOOT_COMPLETED` (부팅 후 알람 복원)
- `WAKE_LOCK` (알람 울릴 때 기기 깨우기)
- `FOREGROUND_SERVICE` (백그라운드 음성)
- `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` (지도에서 현재 위치 표시)
- `READ_CALENDAR` / `WRITE_CALENDAR` (Google/Naver 캘린더 동기화)
- `VIBRATE`

**예상치 못한 권한 발견 시**: 해당 권한을 요청하는 패키지를 pubspec.yaml에서 추적, 필요 없으면 제거

### 3.3 SDK 추적
```powershell
# pubspec.yaml의 모든 의존성에서 데이터 수집 SDK 식별
dart pub deps --style=compact | Select-String "firebase|analytics|crashlytics|admob|ad_|tracking"
```

### 3.4 데이터 수집 SDK 선언 대상
- `firebase_crashlytics`: **선언 대상** (Crash logs, Diagnostics)
- `google_mobile_ads`: **SDK만 포함돼도 선언 대상** (실제 광고 표시 여부 무관)
- `speech_to_text`: **선언 아님** (온디바이스, 데이터 수집 없음)
- `flutter_naver_map`: 네이버 정책에 따라 별도 확인 필요

---

## 4. 정책 수정 권장 항목

### 4.1 가상 재화 (In-app purchases)
- **1차 출시**: 결제/과금 코드 없음 (전체 무료)
- **2차 출시 계획 시**: Play Console "가상 재화" 정책 준수 필요 (영수증 검증, 환불 정책, 만료 처리)
- **Data Safety 영향**: 결제 도입 시 "구매" 데이터 유형 추가

### 4.2 UMP (User Messaging Platform)
- **현재 상태**: AdMob UMP 코드 없음
- **2차 출시(광고 도입) 시 필수**: GDPR/CCPA 동의 수집을 위한 Google UMP SDK 통합 필요
- **한국 사용자 한정 1차 출시**: PIPA(개인정보보호법) 동의만으로 충분, UMP 불필요

### 4.3 voice_logs 보관 기간
- **현재**: 무제한 보관
- **권장**: 사용자 설정에 "음성 로그 자동 삭제" 옵션 추가 (30일/90일/영구)
- **사유**: PIPA 제15조(개인정보의 파기) — 이용목적 달성 시 지체 없이 파기. 무제한 보관은 목적 달성 후에도 보관하는 것으로 해석될 여지 있음
- **실행 우선순위**: 중간. 2차 출시 또는 첫 심사 통과 후 개선

### 4.4 개인정보처리방침 URL
- **Play Console 요구사항**: 모든 앱에 개인정보처리방침 URL 필수
- **현재**: `docs/account-deletion.html`은 있으나 정식 개인정보처리방침 페이지 별도 필요
- **권장**: 공식 웹사이트 또는 GitHub Pages에 한국어/영어 이중 개인정보처리방침 게시

### 4.5 데이터 처리 주체 표시
- **OpenAI**: 데이터 처리 위탁자 (GPT 파싱 목적). 개인정보처리방침에 "OpenAI에 음성 텍스트 전송" 명시
- **Supabase**: 인프라 제공자 (데이터 저장)
- **Google Maps**: 이동 시간 계산 (위치 데이터 전송)
- **Naver Maps**: 지도 표시 (위치 데이터 미전송, 타일 요청만)

---

## 5. 실행 체크리스트

- [ ] release AAB 빌드 후 권한 목록 실측 (`aapt dump permissions`)
- [ ] AdMob SDK 포함 여부 확인 (Data Safety 선언 영향)
- [ ] Play Console Data Safety 섹션 위 표 기준 수정
- [ ] 개인정보처리방침 페이지 작성 및 URL 등록
- [ ] 회원 탈퇴 기능 production 배포 후 실제 삭제 흐름 E2E 검증
- [ ] voice_logs 보관 기간 정책 결정 (CEO 승인 필요)

---

## 6. 한계 (정직 고백)

- 본 보고서는 코드 기반 정적 분석 + AGENTS.md 컨텍스트 기반 작성. 실제 release AAB를 빌드해서 권한을 dump하지 않았으므로 권한 목록은 예측값임 (실행 체크리스트 1번 항목으로 보완 필요)
- AdMob SDK가 AAB에 실제 포함되는지는 pubspec.yaml 의존성 트리 확인 필요 (이 보고서 작성 시점에 미검증)
- OpenAI의 데이터 보관 정책(28일 등)은 별도 확인 필요. 본 보고서는 클라이언트→서버 전송만 다룸
- Crashlytics의 실제 수집 데이터 항목은 Firebase 콘솔에서 재확인 권장
