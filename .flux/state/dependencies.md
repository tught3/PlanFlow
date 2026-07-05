# PlanFlow — 의존성 매핑 요약

> **생성일**: 2026-07-05
> **소스**: `pubspec.yaml` + `pubspec.lock` (name: `planflow`, version: `1.1.1+75`)
> **Dart SDK**: `>=3.3.0 <4.0.0`

---

## 1. 핵심 아키텍처 의존성 (Core Architecture)

앱의 뼈대를 구성하는 핵심 패키지와 resolved 버전:

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **flutter_riverpod** | ^2.4.9 | **2.6.1** | 상태관리 (전역 Provider) |
| └ riverpod (transitive) | — | 2.6.1 | riverpod 코어 엔진 |
| **go_router** | ^13.2.0 | **13.2.5** | 선언적 라우팅 / 딥링크 |
| **supabase_flutter** | ^2.0.0 | **2.12.4** | 백엔드 (Auth / DB / Storage) |
| └ supabase (transitive) | — | 2.10.6 | supabase 클라이언트 코어 |
| **intl** | ^0.20.2 | **0.20.2** | 국제화 / 날짜·숫자 포맷 |

> **상태관리 파이프라인**: `UI Widget` → `riverpod Provider` → `supabase_flutter` (PostgREST/Realtime) → `Supabase Cloud`
> **라우팅 파이프라인**: `go_router` → `app_links`(딥링크) + `receive_sharing_intent`(공유 수신)

---

## 2. Firebase 스택

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **firebase_core** | ^3.6.0 | **3.15.2** | Firebase 초기화 (필수 기반) |
| **firebase_crashlytics** | ^4.1.3 | **4.3.10** | 크래시 리포팅 |
| **firebase_remote_config** | ^5.1.0 | **5.5.0** | 원격 설정 / 기능 플래그 |
| _flutterfire_internals (transitive) | — | 1.3.59 | Firebase 내부 공통 |

> firebase_core → 모든 Firebase 패키지의 기반. 버전 불일치 시 컴파일 에러 발생.

---

## 3. 인증 (Authentication)

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **google_sign_in** | ^6.2.1 | **6.3.0** | Google OAuth 로그인 |
| **googleapis** | ^12.0.0 | **12.0.0** | Google API 클라이언트 (Calendar 등) |
| **googleapis_auth** | ^1.4.1 | **1.6.0** | Google 인증 토큰 관리 |
| **flutter_secure_storage** | ^9.2.4 | **9.2.4** | 토큰/자격증명 암호화 저장 |
| **crypto** | ^3.0.6 | **3.0.7** | 해싱 / 암호화 유틸 |

> 인증 플로우: `google_sign_in` → `flutter_secure_storage`(토큰 저장) → `supabase_flutter`(세션 연동) / `googleapis_auth`(Calendar API)

---

## 4. 로컬 데이터 / 알림 / 백그라운드

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **shared_preferences** | ^2.3.3 | **2.5.5** | 키-값 로컬 저장 |
| **flutter_local_notifications** | ^21.0.0 | **21.0.0** | 로컬 푸시 알림 |
| **android_alarm_manager_plus** | ^5.0.0 | **5.0.0** | Android 정확한 알람 스케줄 |
| **timezone** | ^0.11.0 | **0.11.0** | 타임존 처리 (알림용) |
| **home_widget** | ^0.9.1 | **0.9.1** | 홈화면 위젯 (Android/iOS) |

> 알림 파이프라인: `android_alarm_manager_plus` (스케줄) → `timezone` (시간 계산) → `flutter_local_notifications` (표시)

---

## 5. 맵 / 미디어 / UI 유틸

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **flutter_naver_map** | ^1.4.4 | **1.4.4** | 네이버 지도 (한국) |
| **google_maps_flutter** | ^2.10.1 | **2.17.0** | Google 지도 |
| **flutter_tts** | ^3.8.5 | **3.8.5** | 텍스트 음성 변환 (TTS) |
| **speech_to_text** | ^7.3.0 | **7.3.0** | 음성 인식 (STT) |
| **qr_flutter** | ^4.1.0 | **4.1.0** | QR 코드 생성 |
| **file_picker** | ^11.0.2 | **11.0.2** | 파일 선택 |
| **url_launcher** | ^6.3.1 | **6.3.2** | 외부 URL / 앱 실행 |

---

## 6. 앱 인프라 / 스토어

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **package_info_plus** | ^8.0.0 | **8.3.1** | 앱 버전 정보 |
| **in_app_review** | ^2.0.9 | **2.0.11** | 인앱 리뷰 요청 |
| **in_app_update** | ^4.2.3 | **4.2.5** | Android 인앱 업데이트 |
| **app_links** | ^7.0.0 | **7.0.0** | 딥링크 수신 |
| **receive_sharing_intent** | ^1.8.1 | **1.8.1** | 공유 수신 |
| **android_intent_plus** | ^6.0.0 | **6.0.0** | Android Intent 실행 |

---

## 7. 네트워크 / 데이터 파싱

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| **http** | ^1.2.0 | **1.6.0** | HTTP 클라이언트 |
| **xml** | ^6.5.0 | **6.6.1** | XML 파싱 |
| **ical_parser** | ^1.2.0 | **1.2.0** | iCalendar(.ics) 파싱 |

---

## 8. Dev Dependencies

| 패키지 | pubspec 제약 | resolved 버전 | 역할 |
|---|---|---|---|
| flutter_lints | ^5.0.0 | 5.0.0 | 린트 규칙 |
| flutter_test | sdk | 0.0.0 | 테스트 프레임워크 |
| flutter_local_notifications_platform_interface | ^11.0.0 | 11.0.0 | 알림 플랫폼 인터페이스 (테스트용) |
| shared_preferences_platform_interface | ^2.4.2 | 2.4.2 | SharedPreferences 인터페이스 (테스트용) |

---

## 9. 핵심 의존성 그래프 요약

```
planflow (app)
│
├── 상태관리 & 라우팅
│   ├── flutter_riverpod 2.6.1 ── riverpod 2.6.1
│   └── go_router 13.2.5
│
├── 백엔드 (Supabase)
│   └── supabase_flutter 2.12.4 ── supabase 2.10.6
│
├── Firebase
│   ├── firebase_core 3.15.2 ← [기반: 모든 Firebase 패키지]
│   ├── firebase_crashlytics 4.3.10
│   └── firebase_remote_config 5.5.0
│
├── 인증
│   ├── google_sign_in 6.3.0
│   ├── googleapis 12.0.0 + googleapis_auth 1.6.0
│   └── flutter_secure_storage 9.2.4 (토큰 저장)
│
├── 로컬 데이터 & 알림
│   ├── shared_preferences 2.5.5
│   ├── flutter_local_notifications 21.0.0
│   ├── android_alarm_manager_plus 5.0.0 + timezone 0.11.0
│   └── home_widget 0.9.1
│
├── 맵 & 미디어
│   ├── flutter_naver_map 1.4.4 / google_maps_flutter 2.17.0
│   ├── flutter_tts 3.8.5 / speech_to_text 7.3.0
│   └── qr_flutter 4.1.0 / file_picker 11.0.2
│
└── 유틸
    ├── http 1.6.0 / xml 6.6.1 / ical_parser 1.2.0
    ├── intl 0.20.2 / crypto 3.0.7
    ├── package_info_plus 8.3.1 / in_app_review 2.0.11 / in_app_update 4.2.5
    └── app_links 7.0.0 / receive_sharing_intent 1.8.1 / url_launcher 6.3.2
```

---

## 10. 버전 관리 메모

- **직접 메인 의존성**: 35개 패키지
- **주요 마이그레이션 위험 지점**:
  - `flutter_riverpod` / `riverpod`: Riverpod 3.0 마이그레이션 시 전체 Provider 구조 영향
  - `supabase_flutter`: 3.x 마이그레이션 시 Auth/Realtime API 변경 가능
  - `go_router`: 14.x 마이그레이션 시 `ShellRoute` / 타입드 라우트 API 변경
  - `firebase_*`: firebase_core 버전과 반드시 정합 (FlutterFire 호환 매트릭스 확인 필요)
- **제약 vs resolved 차이가 큰 패키지** (자동 업그레이드된 경우):
  - `supabase_flutter`: ^2.0.0 → **2.12.4** (minor 12단계 업그레이드)
  - `google_maps_flutter`: ^2.10.1 → **2.17.0**
  - `package_info_plus`: ^8.0.0 → **8.3.1**
  - `shared_preferences`: ^2.3.3 → **2.5.5**
  - `firebase_core`: ^3.6.0 → **3.15.2**
