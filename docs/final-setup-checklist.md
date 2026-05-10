# PlanFlow 1차/2차 개발 상태 체크리스트

이 문서는 v3 프롬프트 기준으로 1차 개발, 2차 개발, 지금 당장 확인할 일을 분리한 최종 점검표입니다.

## 결론

- 현재 개발 방향은 1차 배포까지가 맞습니다.
- 1차 범위는 v3 구현 체크리스트 1-24입니다.
- 2차 범위는 v3 구현 체크리스트 25-31입니다.
- 2차 기능은 지금 구현하지 않고, 1차 실기기 검증 후 별도 단계로 진행합니다.

## 1차 개발 범위

1차 목표는 수익구조 없이 전체 기능을 무료로 열고, 앱 안에는 `PRO 얼리버드 신청`만 노출하는 MVP입니다.

### 1차 코드 구현 상태

- [x] 1. Supabase 프로젝트 생성 및 SQL 스키마 준비
- [x] 2. `.env` 런타임 제거 및 `--dart-define` / `env/local.json` 기반 클라이언트 설정 입력
- [x] 3. Flutter 프로젝트 생성 및 패키지 설치
- [x] 4. 폴더 구조 생성
- [x] 5. `main.dart` Supabase 초기화
- [x] 6. `core/router.dart` 라우팅
- [x] 7. `core/theme.dart` 테마
- [x] 8. `SttService` 구현 및 테스트
- [x] 9. `GptService` 구현 및 파싱 테스트
- [x] 10. `EventRepository` Supabase CRUD
- [x] 11. `VoiceInputScreen` 구현
- [x] 12. `ConfirmScreen` 구현
- [x] 13. `HomeScreen` 실제 오늘 일정 조회 및 얼리버드 카드
- [x] 14. `CalendarScreen` 구현
- [x] 15. `EventDetailScreen` / `EventEditScreen`
- [x] 16. `NotificationService` 구현
- [x] 17. 선행행동 역산 알림 로직
- [x] 18. 이브닝/모닝 브리핑 예약, 테스트 재생, tap-to-play 알림, 다음 브리핑 재예약
- [x] 19. Google Calendar 연동, 재인증 상태 표시, 자동 동기화 상태 분리
- [x] 20. Naver Calendar 1차 기능: Naver CalDAV 연결/import/export, 휴대폰 내부 캘린더 import/export, 진단/상태 표시
- [x] 21. Google Maps/TMAP/Naver 기반 이동시간 버퍼와 보수적 fallback
- [x] 22. Android Home Widget 네이티브 구성 및 Flutter service
- [x] 23. `SettingsScreen`
- [x] 24. `early_bird_emails` 기반 PRO 얼리버드 이메일 수집

### 1차 코드 보강 완료

- [x] Android `INTERNET` 권한 선언
- [x] Android `RECORD_AUDIO` 권한 선언
- [x] Android `POST_NOTIFICATIONS` 권한 선언
- [x] Android `SCHEDULE_EXACT_ALARM` 권한 선언
- [x] Android `USE_FULL_SCREEN_INTENT` 권한 선언
- [x] Android `VIBRATE` 권한 선언
- [x] Android `RECEIVE_BOOT_COMPLETED` 권한 선언
- [x] Android `WAKE_LOCK` 권한 선언
- [x] Android AlarmManager service/receiver 선언
- [x] MainActivity lock-screen wake 속성 선언
- [x] `flutter_local_notifications` 예약 알림/부팅 복구 receiver 선언
- [x] Critical alarm 예약 전 full-screen intent 권한 요청
- [x] Gradle wrapper 파일 세트 커밋 준비
- [x] ConfirmScreen 저장 순서 보강: events, pre_actions, reminders, location_history, voice_logs, 알림 스케줄
- [x] GPT 파싱 스키마에 ISO `start_at`/`end_at` 및 `pre_actions` 반영
- [x] HomeScreen 샘플 일정 제거 및 Supabase 오늘 일정 조회
- [x] Android Home Widget `AppWidgetProvider`/layout/xml/manifest receiver 추가
- [x] Home Widget 마이크 버튼 클릭 시 음성 입력 라우팅 처리
- [x] 일정 저장 후 Home Widget 다음 일정 데이터 갱신
- [x] Home Widget 데이터 갱신 시 오늘 남은 일정 중 가장 가까운 일정 계산
- [x] 위젯 `planflow://voice` Android intent-filter 추가
- [x] 후속 저장 실패 시 일정 저장 성공과 후속 동기화 경고 분리
- [x] 홈 위치 좌표 fallback 제거 및 시/군/구 중심 지역명 표시
- [x] 음성 일정 관리의 추가/수정/삭제/조회 버튼 동작 연결
- [x] 일정 삭제 다이얼로그 버튼 균등 배치
- [x] 스마트 준비 알람 목적 판단 개선: 병원/법원/학교를 장소명만으로 단정하지 않음
- [x] 달력 중요 일정 빨간 점 표시
- [x] 출발 알림 예약/모니터링 상태 기록 및 설정 화면 표시
- [x] 지도 선택 화면 API 키/인증 실패 안내와 외부 지도 fallback 표시
- [x] Google/Naver/휴대폰 내부 캘린더 자동 동기화 provider별 상태 표시
- [x] 개인정보처리방침 GitHub Pages URL 공개 확인: `https://tught3.github.io/PlanFlow/privacy-policy.html`

### 1차에서 아직 실제 검증이 필요한 것

- [x] Supabase SQL Editor에서 `supabase/calendar_sync_patch.sql` 실행
- [ ] Supabase SQL Editor에서 최신 `supabase/schema.sql` 전체 실행 또는 현재 DB가 동일 스키마인지 확인
- [ ] Supabase에서 `users`, `events`, `pre_actions`, `reminders`, `voice_logs`, `location_history`, `user_settings`, `calendar_connections`, `early_bird_emails`, `user_backups` 테이블 확인
- [ ] Supabase에서 `submit_early_bird_email` RPC 함수 확인
- [ ] `early_bird_emails`에 공개 insert/select policy가 없는지 확인
- [ ] Play Console 개발자 계정 인증 완료
- [ ] Play Console 앱 생성 후 개인정보처리방침 URL 입력
- [ ] Google Cloud에서 Calendar API, Maps SDK for Android, Directions/Distance Matrix/Geocoding API 활성화 확인
- [ ] Google OAuth Android client에 `com.planflow.app` + release SHA-1 등록
- [ ] Google Maps API key 제한에 `com.planflow.app` + release SHA-1 등록
- [ ] Naver Developers/Naver Cloud에 `com.planflow.app` 및 콜백/지도 제한 등록
- [ ] Kakao Developers에 `com.planflow.app` 및 release key hash 등록
- [ ] OpenAI 월 사용량 제한 설정
- [x] Android release APK 실기기 설치/실행 확인
- [ ] 앱 알림 권한 허용 확인
- [ ] 정확한 알람 권한 허용 확인
- [ ] 중요 일정 full-screen/critical 알림 동작 확인
- [ ] 한국어 음성 입력 확인
- [ ] GPT 일정 파싱 확인
- [ ] 일정 저장 플로우 확인
- [ ] Google Calendar 연결/저장/재시작 후 연결 유지 확인
- [ ] Naver CalDAV 연결/import/export 확인
- [ ] 휴대폰 내부 캘린더 import/export 확인
- [ ] 출발 알림 실제 수신 확인
- [ ] PRO 얼리버드 이메일 저장 확인
- [ ] TTS 브리핑 음성 출력 확인
- [ ] Android Home Widget 실제 표시 및 마이크 버튼 앱 실행 확인
- [ ] 백업 생성/복원 확인
- [ ] Play 내부 테스트용 AAB 업로드

## 1차에서 주의할 점

- Google Calendar는 앱 코드가 준비되어 있지만 Google Cloud OAuth/Calendar API/Maps API 제한이 release 패키지명과 SHA-1 기준으로 맞아야 실제 성공합니다.
- Naver Calendar는 1차에서 CalDAV/direct sync 및 휴대폰 내부 캘린더 경로를 지원합니다. 단, Naver Calendar 앱의 내부 비공개 저장소에만 있는 일정은 Android에서 직접 읽을 수 없으므로 CalDAV 또는 Android Calendar Provider에 노출되는 일정만 가져올 수 있습니다.
- Google Maps/TMAP/Naver 이동시간은 API 실패 시 보수적 fallback을 사용하되, 앱은 이를 정확한 실시간 경로처럼 과장하지 않아야 합니다.
- Home Widget은 Android 네이티브 구성까지 추가됐습니다. 실제 런처 배치/마이크 버튼은 실기기에서 확인해야 합니다.
- 앱 런타임은 `.env`를 읽지 않습니다. 로컬/릴리즈 설정은 `--dart-define` 또는 `--dart-define-from-file=env/local.json`으로 전달합니다.
- `SUPABASE_URL`과 `SUPABASE_ANON_KEY`는 클라이언트 공개 설정값이며, 보호는 Supabase RLS 정책으로 강제합니다.
- `service_role`, OpenAI API key, OAuth client secret 같은 서버 전용 비밀값은 APK asset이나 앱 define에 포함하지 않습니다. GPT 일정 파싱은 Supabase Edge Function 같은 서버 경유 방식으로 운영해야 합니다.
- iOS는 1차 Android 우선 전략상 추후 진행입니다.

## 2차 개발 범위

2차는 1차 배포 후 구현합니다. 현재는 계획만 유지하고 코드 구현하지 않습니다.

- [ ] 25. 온보딩 권한 동의 화면
- [ ] 26. 카톡/문자 감지 서비스
- [ ] 27. 통화 텍스트 파일 감지 서비스
- [ ] 28. GPT 통화 텍스트 품질 개선 로직
- [ ] 29. 감지 모달 UI
- [ ] 30. `detection_logs` 테이블 추가 및 RLS 적용
- [ ] 31. 설정 화면에 감지 기능 ON/OFF 토글 추가

## 지금 당장 해야 할 일

1. Play Console 개발자 계정 인증이 끝나면 앱을 생성하고 개인정보처리방침 URL을 입력
2. Google/Naver/Kakao/OpenAI 콘솔 값을 `docs/release-console-checklist.md` 기준으로 반영
3. Supabase Table Editor/Functions에서 최신 schema/RLS/RPC 상태 확인
4. Release APK로 이메일 로그인, 일정 저장, 알림, Google/Naver/휴대폰 캘린더, 백업을 실기기 E2E 검증
5. 내부 테스트용 `app-release.aab` 업로드

## 현재 검증 기준

- [x] `flutter analyze` 통과
- [x] `flutter test` 통과
- [x] Android debug APK build 통과
- [x] Android release APK build 통과
- [x] Android release APK 실기기 설치/실행 확인
- [x] 개인정보처리방침 URL HTTP 200 확인
- [x] Play Console 제출 문구/Data safety/내부 테스트 릴리즈 노트 초안 준비
- [x] 최신 1차 보강분 GitHub `main` push
